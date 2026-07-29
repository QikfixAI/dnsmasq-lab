#!/usr/bin/env bash
# Remove runtime artifacts created by this lab (container, image, keys, zone data).
# Project source files are left untouched.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

NAME="${CONTAINER_NAME:-dnsmasq-lab}"
IMAGE="${IMAGE_NAME:-localhost/dnsmasq-lab:latest}"
# Base image pulled by Containerfile FROM (override with BASE_IMAGE if needed).
BASE_IMAGE="${BASE_IMAGE:-$(awk '/^FROM[[:space:]]+/ {print $2; exit}' "${ROOT}/Containerfile")}"
ASSUME_YES=0

usage() {
  cat <<'EOF'
Usage: ./mgmt-scripts/cleanup.sh [-y|--yes] [-h|--help]

Stops and removes the lab container, deletes the built image and its Alpine
base image, removes generated TSIG keys, and resets dynamic zone data under data/.

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
echo "  - container: ${NAME}"
echo "  - image:     ${IMAGE}"
echo "  - base:      ${BASE_IMAGE:-<none>}"
echo "  - keys:      ${ROOT}/keys/"
echo "  - data:      zone.json, dynamic.conf, dynamic.hosts"
echo

if [[ "${ASSUME_YES}" -ne 1 ]]; then
  read -r -p "Continue? [y/N] " reply
  case "${reply}" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

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
      # Also try short name (e.g. alpine:3.20) if the full ref is absent.
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
# Keep an empty placeholder so the data dir stays in git checkouts.
touch data/.gitkeep
echo "Reset data/zone.json, data/dynamic.conf, data/dynamic.hosts"

echo
echo "Cleanup complete. Source tree is unchanged."
echo "To start again: ./scripts/generate-tsig-key.sh && ./scripts/start.sh"
