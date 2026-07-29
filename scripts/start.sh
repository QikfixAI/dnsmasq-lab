#!/usr/bin/env bash
# Build and start the dnsmasq lab container with Podman.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

# shellcheck source=load-config.sh
source "${ROOT}/scripts/load-config.sh"

NAME="${CONTAINER_NAME}"
IMAGE="${IMAGE_NAME}"
FIREWALLD_STATE="${ROOT}/data/.firewalld-opened"

need_cmd() {
  local cmd="$1"
  local hint="${2:-}"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "error: required command '${cmd}' not found." >&2
    if [[ -n "${hint}" ]]; then
      echo "       ${hint}" >&2
    fi
    exit 1
  fi
}

# If firewalld is running, open DNS and nsupdate host ports for this runtime
# session only (not permanent). Always record lab ports in data/.firewalld-opened
# so cleanup.sh can close them even if they were already open.
ensure_firewalld_ports() {
  local ports=("$@")
  local port proto opened=()

  if ! command -v firewall-cmd >/dev/null 2>&1; then
    echo "firewalld: firewall-cmd not found; skipping"
    return 0
  fi

  if ! firewall-cmd --state >/dev/null 2>&1; then
    echo "firewalld: not running; skipping"
    return 0
  fi

  echo "firewalld: active — checking ports ${ports[*]} (tcp/udp)..."
  mkdir -p "$(dirname "${FIREWALLD_STATE}")"
  : > "${FIREWALLD_STATE}"
  for port in "${ports[@]}"; do
    for proto in tcp udp; do
      # Always record lab ports so cleanup can reverse them.
      echo "${port}/${proto}" >> "${FIREWALLD_STATE}"
      if firewall-cmd --quiet --query-port="${port}/${proto}" 2>/dev/null; then
        echo "firewalld: ${port}/${proto} already open (recorded for cleanup)"
        continue
      fi
      echo "firewalld: opening ${port}/${proto} (runtime)"
      if ! firewall-cmd --add-port="${port}/${proto}"; then
        echo "error: failed to add firewalld rule for ${port}/${proto}" >&2
        echo "       re-run as root, or: firewall-cmd --add-port=${port}/${proto}" >&2
        exit 1
      fi
      opened+=("${port}/${proto}")
    done
  done

  if [[ "${#opened[@]}" -gt 0 ]]; then
    echo "firewalld: opened ${opened[*]} (recorded in data/.firewalld-opened)"
  else
    echo "firewalld: no new openings; lab ports recorded in data/.firewalld-opened"
  fi
}

need_cmd podman "Install the podman package (e.g. dnf install -y podman)."
./scripts/prepare.sh
# prepare.sh reloads config
# shellcheck source=load-config.sh
source "${ROOT}/scripts/load-config.sh"

ensure_firewalld_ports "${DNS_PORT}" "${UPDATE_PORT}"

echo "Building ${IMAGE}..."
podman build -t "${IMAGE}" -f Containerfile .

# Stop existing container if present.
if podman container exists "${NAME}" 2>/dev/null; then
  echo "Removing existing container ${NAME}..."
  podman rm -f "${NAME}" >/dev/null
fi

echo "Starting ${NAME} (zone ${DDNS_ZONE}, ${LAB_CIDR}, DNS :${DNS_PORT}, nsupdate :${UPDATE_PORT})..."
# :Z relabels volumes for SELinux (RHEL/Fedora).
podman run -d \
  --name "${NAME}" \
  --replace \
  -p "${DNS_PORT}:53/udp" \
  -p "${DNS_PORT}:53/tcp" \
  -p "${UPDATE_PORT}:5353/udp" \
  -p "${UPDATE_PORT}:5353/tcp" \
  -v "${ROOT}/keys:/keys:ro,Z" \
  -v "${ROOT}/data:/data:Z" \
  -e DDNS_ZONE="${DDNS_ZONE}" \
  -e DDNS_REV_ZONE="${DDNS_REV_ZONE}" \
  -e DDNS_KEY_NAME="${DDNS_KEY_NAME}" \
  -e DDNS_PORT="${DDNS_PORT}" \
  -e DDNS_GW_IP="${DDNS_GW_IP}" \
  -e DDNS_STATIC_IP="${DDNS_STATIC_IP}" \
  -e DDNS_NS1_IP="${DDNS_NS1_IP}" \
  -e DDNS_GW_PTR="${DDNS_GW_PTR}" \
  -e DDNS_STATIC_PTR="${DDNS_STATIC_PTR}" \
  -e DDNS_NS1_PTR="${DDNS_NS1_PTR}" \
  -e UPSTREAM_DNS_1="${UPSTREAM_DNS_1}" \
  -e UPSTREAM_DNS_2="${UPSTREAM_DNS_2}" \
  --health-cmd="dig @127.0.0.1 ns1.${DDNS_ZONE} +time=1 +tries=1 >/dev/null" \
  --health-interval=15s \
  --health-timeout=3s \
  --health-start-period=10s \
  --health-retries=3 \
  "${IMAGE}"

echo
echo "Container is up (zone ${DDNS_ZONE})."
echo "  Query:   dig @127.0.0.1 -p ${DNS_PORT} static.${DDNS_ZONE}"
echo "  Update:  ./scripts/example-nsupdate.sh"
echo "  Config:  config/lab.env"
echo "  Logs:    podman logs -f ${NAME}"
echo "  Health:  podman healthcheck run ${NAME}"
