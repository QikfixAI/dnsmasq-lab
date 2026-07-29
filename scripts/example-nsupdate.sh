#!/usr/bin/env bash
# Apply a sample dynamic update via nsupdate + TSIG key.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY="${ROOT}/keys/update.key"
HOST="${NSUPDATE_HOST:-127.0.0.1}"
PORT="${UPDATE_PORT:-5353}"
NAME="${1:-demo.example.com}"
IP="${2:-192.168.0.50}"
TTL="${3:-300}"

if [[ ! -f "${KEY}" ]]; then
  echo "Missing ${KEY}; run ./scripts/generate-tsig-key.sh" >&2
  exit 1
fi

if ! command -v nsupdate >/dev/null 2>&1; then
  echo "nsupdate not found. Install bind-utils (RHEL) or dnsutils (Debian)." >&2
  exit 1
fi

echo "Adding ${NAME} A ${IP} (ttl ${TTL}) via ${HOST}:${PORT}..."
nsupdate -k "${KEY}" <<EOF
server ${HOST} ${PORT}
zone example.com.
update delete ${NAME} A
update add ${NAME} ${TTL} A ${IP}
send
EOF

echo "Done. Verify with:"
echo "  dig @127.0.0.1 -p \${DNS_PORT:-53} ${NAME} +short"
echo "  # or: podman exec dnsmasq-lab dig @127.0.0.1 ${NAME} +short"
