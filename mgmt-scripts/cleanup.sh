#!/usr/bin/env bash
# Remove runtime artifacts created by this lab (container, image, keys, zone data).
# Project source files are left untouched.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

# shellcheck source=../scripts/load-config.sh
source "${ROOT}/scripts/load-config.sh"

NAME="${CONTAINER_NAME}"
IMAGE="${IMAGE_NAME}"
# Base image pulled by Containerfile FROM (override with BASE_IMAGE if needed).
BASE_IMAGE="${BASE_IMAGE:-$(awk '/^FROM[[:space:]]+/ {print $2; exit}' "${ROOT}/Containerfile")}"
FIREWALLD_STATE="${ROOT}/data/.firewalld-opened"
SYSTEMD_UNIT_NAME="dnsmasq-lab.service"
SYSTEMD_UNIT_DST="/etc/systemd/system/${SYSTEMD_UNIT_NAME}"
ASSUME_YES=0

usage() {
  cat <<'EOF'
Usage: ./mgmt-scripts/cleanup.sh [-y|--yes] [-h|--help]

Stops the systemd unit if installed, removes /etc/systemd/system/dnsmasq-lab.service,
stops/removes the lab container, deletes the built image and its Alpine base
image, removes generated TSIG keys, resets dynamic zone data under data/, and
closes any firewalld ports that start.sh opened for this lab.

  -y, --yes   Do not prompt for confirmation
  -h, --help  Show this help

Environment:
  CONTAINER_NAME   Container name (default: dnsmasq-lab)
  IMAGE_NAME       Image name (default: localhost/dnsmasq-lab:latest)
  BASE_IMAGE       Base image to remove (default: FROM line in Containerfile)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

echo "This will remove:"
echo "  - systemd:   ${SYSTEMD_UNIT_NAME} (stop/disable + remove unit file if present)"
echo "  - container: ${NAME}"
echo "  - image:     ${IMAGE}"
echo "  - base:      ${BASE_IMAGE:-<none>}"
echo "  - keys:      ${ROOT}/keys/"
echo "  - data:      zone.json, dynamic.conf, dynamic.hosts, nsupdate-*.txt"
echo "  - firewalld: runtime + permanent rules for DNS_PORT (${DNS_PORT}) and UPDATE_PORT (${UPDATE_PORT})"
echo

if [[ "${ASSUME_YES}" -ne 1 ]]; then
  read -r -p "Continue? [y/N] " reply
  case "${reply}" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

# Stop/disable and remove the systemd unit before tearing down the container.
cleanup_systemd() {
  local unit_loaded=0 unit_file=0

  if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemd: systemctl not found; skipping"
    return 0
  fi

  if systemctl cat "${SYSTEMD_UNIT_NAME}" >/dev/null 2>&1 \
    || systemctl list-unit-files "${SYSTEMD_UNIT_NAME}" --no-legend 2>/dev/null | grep -q "${SYSTEMD_UNIT_NAME}"; then
    unit_loaded=1
  fi
  [[ -f "${SYSTEMD_UNIT_DST}" ]] && unit_file=1

  if [[ "${unit_loaded}" -eq 0 && "${unit_file}" -eq 0 ]]; then
    echo "systemd: ${SYSTEMD_UNIT_NAME} not installed"
    return 0
  fi

  if [[ "$(id -u)" -ne 0 ]]; then
    echo "systemd: ${SYSTEMD_UNIT_NAME} is present but cleanup is not root;" >&2
    echo "         run as root (or sudo) to stop/disable and remove ${SYSTEMD_UNIT_DST}" >&2
    echo "         e.g. sudo ./mgmt-scripts/cleanup.sh -y" >&2
    return 1
  fi

  echo "systemd: stopping/disabling ${SYSTEMD_UNIT_NAME}..."
  systemctl disable --now "${SYSTEMD_UNIT_NAME}" >/dev/null 2>&1 || true
  # Extra stop in case disable --now did not clear an active oneshot.
  systemctl stop "${SYSTEMD_UNIT_NAME}" >/dev/null 2>&1 || true

  if [[ -f "${SYSTEMD_UNIT_DST}" ]]; then
    rm -f "${SYSTEMD_UNIT_DST}"
    echo "systemd: removed ${SYSTEMD_UNIT_DST}"
  else
    echo "systemd: unit file ${SYSTEMD_UNIT_DST} not present"
  fi

  systemctl daemon-reload
  systemctl reset-failed "${SYSTEMD_UNIT_NAME}" >/dev/null 2>&1 || true
  echo "systemd: daemon-reload done"
}

cleanup_systemd || true

# Close firewalld ports for this lab (runtime + permanent leftovers).
# Prefer the record from start.sh; always also target current DNS_PORT/UPDATE_PORT
# so cleanup works even if data/.firewalld-opened was lost.
close_firewalld_ports() {
  local -A rules=()
  local rule port proto changed_runtime=0 changed_permanent=0

  if ! command -v firewall-cmd >/dev/null 2>&1; then
    echo "firewalld: firewall-cmd not found; skipping"
    return 0
  fi
  if ! firewall-cmd --state >/dev/null 2>&1; then
    echo "firewalld: not running; skipping"
    return 0
  fi

  if [[ -f "${FIREWALLD_STATE}" ]]; then
    while IFS= read -r rule || [[ -n "${rule}" ]]; do
      [[ -z "${rule}" ]] && continue
      rules["${rule}"]=1
    done < "${FIREWALLD_STATE}"
  fi
  # Fallback / always include ports from current lab config.
  for port in "${DNS_PORT}" "${UPDATE_PORT}"; do
    [[ -z "${port}" ]] && continue
    rules["${port}/tcp"]=1
    rules["${port}/udp"]=1
  done

  if [[ "${#rules[@]}" -eq 0 ]]; then
    echo "firewalld: no lab ports to close"
    return 0
  fi

  echo "firewalld: closing lab ports (${!rules[*]})..."
  for rule in "${!rules[@]}"; do
    port="${rule%/*}"
    proto="${rule#*/}"
    [[ -n "${port}" && -n "${proto}" ]] || continue

    if firewall-cmd --quiet --query-port="${rule}" 2>/dev/null; then
      echo "firewalld: removing runtime ${rule}"
      if firewall-cmd --remove-port="${rule}" >/dev/null; then
        changed_runtime=1
      else
        echo "firewalld: warning: failed to remove runtime ${rule}" >&2
      fi
    fi
    # Also drop permanent leftovers (e.g. from older start.sh that used --permanent).
    if firewall-cmd --quiet --permanent --query-port="${rule}" 2>/dev/null; then
      echo "firewalld: removing permanent ${rule}"
      if firewall-cmd --permanent --remove-port="${rule}" >/dev/null; then
        changed_permanent=1
      else
        echo "firewalld: warning: failed to remove permanent ${rule}" >&2
      fi
    fi
  done

  if [[ "${changed_permanent}" -eq 1 ]]; then
    echo "firewalld: reloading after permanent changes"
    firewall-cmd --reload >/dev/null || true
  fi
  if [[ "${changed_runtime}" -eq 0 && "${changed_permanent}" -eq 0 ]]; then
    echo "firewalld: lab ports were not present"
  fi
}

close_firewalld_ports

if command -v podman >/dev/null 2>&1; then
  if podman container exists "${NAME}" 2>/dev/null; then
    podman rm -f "${NAME}" >/dev/null
    echo "Removed container ${NAME}"
  else
    echo "Container ${NAME} not present"
  fi

  if podman image exists "${IMAGE}" 2>/dev/null; then
    podman rmi -f "${IMAGE}" >/dev/null
    echo "Removed image ${IMAGE}"
  else
    echo "Image ${IMAGE} not present"
  fi

  if [[ -n "${BASE_IMAGE}" ]]; then
    if podman image exists "${BASE_IMAGE}" 2>/dev/null; then
      podman rmi -f "${BASE_IMAGE}" >/dev/null
      echo "Removed base image ${BASE_IMAGE}"
    else
      # Also try short name (e.g. alpine:3.24) if the full ref is absent.
      short="${BASE_IMAGE##*/}"
      if [[ "${short}" != "${BASE_IMAGE}" ]] && podman image exists "${short}" 2>/dev/null; then
        podman rmi -f "${short}" >/dev/null
        echo "Removed base image ${short}"
      else
        echo "Base image ${BASE_IMAGE} not present"
      fi
    fi
  fi

  # Drop dangling layers left by rebuilds of this lab (best-effort).
  podman image prune -f >/dev/null 2>&1 || true
else
  echo "podman not found; skipped container/image cleanup"
fi

if [[ -d keys ]]; then
  rm -rf keys
  echo "Removed keys/"
fi

mkdir -p data
echo '{}' > data/zone.json
echo '# dynamic TXT/CNAME/PTR records appear here' > data/dynamic.conf
echo '# dynamic A/AAAA records appear here' > data/dynamic.hosts
rm -f data/nsupdate-*.txt data/test-*.conf data/.firewalld-opened
touch data/.gitkeep
echo "Reset data/ (zone state + removed test artifacts)"

echo
echo "Cleanup complete. Source tree is unchanged."
echo "To start again: ./scripts/prepare.sh && ./scripts/start.sh"
echo "To reinstall systemd: sudo ./scripts/install-systemd.sh && sudo systemctl enable --now dnsmasq-lab.service"
