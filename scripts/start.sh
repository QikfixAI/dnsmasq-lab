#!/usr/bin/env bash
# Build and start the dnsmasq lab container with Podman.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

NAME="${CONTAINER_NAME:-dnsmasq-lab}"
IMAGE="${IMAGE_NAME:-localhost/dnsmasq-lab:latest}"
DNS_PORT="${DNS_PORT:-53}"
UPDATE_PORT="${UPDATE_PORT:-5353}"

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

# If firewalld is running, ensure DNS and nsupdate host ports are allowed permanently.
ensure_firewalld_ports() {
  local ports=("$@")
  local port proto changed=0

  if ! command -v firewall-cmd >/dev/null 2>&1; then
    echo "firewalld: firewall-cmd not found; skipping"
    return 0
  fi

  if ! firewall-cmd --state >/dev/null 2>&1; then
    echo "firewalld: not running; skipping"
    return 0
  fi

  echo "firewalld: active — checking ports ${ports[*]} (tcp/udp)..."
  for port in "${ports[@]}"; do
    for proto in tcp udp; do
      if firewall-cmd --quiet --query-port="${port}/${proto}" 2>/dev/null; then
        echo "firewalld: ${port}/${proto} already open"
        continue
      fi
      echo "firewalld: opening ${port}/${proto} permanently"
      if ! firewall-cmd --permanent --add-port="${port}/${proto}"; then
        echo "error: failed to add firewalld rule for ${port}/${proto}" >&2
        echo "       re-run as root, or: firewall-cmd --permanent --add-port=${port}/${proto} && firewall-cmd --reload" >&2
        exit 1
      fi
      changed=1
    done
  done

  if [[ "${changed}" -eq 1 ]]; then
    echo "firewalld: reloading to apply permanent rules"
    firewall-cmd --reload >/dev/null
  else
    echo "firewalld: no changes needed"
  fi
}

need_cmd podman "Install the podman package (e.g. dnf install -y podman)."
ensure_firewalld_ports "${DNS_PORT}" "${UPDATE_PORT}"

if [[ ! -f keys/update.key ]]; then
  if ! command -v openssl >/dev/null 2>&1 \
    && ! command -v python3 >/dev/null 2>&1 \
    && ! command -v base64 >/dev/null 2>&1; then
    echo "error: cannot generate TSIG key; need openssl, python3, or base64." >&2
    exit 1
  fi
  echo "Generating TSIG key..."
  ./scripts/generate-tsig-key.sh
fi

mkdir -p data
[[ -f data/zone.json ]] || echo '{}' > data/zone.json
[[ -f data/dynamic.conf ]] || echo '# dynamic TXT/CNAME records appear here' > data/dynamic.conf
[[ -f data/dynamic.hosts ]] || echo '# dynamic A/AAAA records appear here' > data/dynamic.hosts

echo "Building ${IMAGE}..."
podman build -t "${IMAGE}" -f Containerfile .

# Stop existing container if present.
if podman container exists "${NAME}" 2>/dev/null; then
  echo "Removing existing container ${NAME}..."
  podman rm -f "${NAME}" >/dev/null
fi

echo "Starting ${NAME} (DNS :${DNS_PORT}, nsupdate :${UPDATE_PORT})..."
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
  -e DDNS_ZONE=example.com \
  -e DDNS_REV_ZONE=0.168.192.in-addr.arpa \
  -e DDNS_KEY_NAME=update-key \
  "${IMAGE}"

echo
echo "Container is up."
echo "  Query:   dig @127.0.0.1 -p ${DNS_PORT} static.example.com"
echo "  Update:  ./scripts/example-nsupdate.sh"
echo "  Logs:    podman logs -f ${NAME}"
