#!/usr/bin/env bash
# Generate a TSIG key for external nsupdate clients.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=load-config.sh
source "${ROOT}/scripts/load-config.sh"

KEYS_DIR="${ROOT}/keys"
KEY_NAME="${DDNS_KEY_NAME}"
OUT="${KEYS_DIR}/update.key"

mkdir -p "${KEYS_DIR}"

if [[ -f "${OUT}" && "${FORCE:-0}" != "1" ]]; then
  echo "Key already exists: ${OUT}"
  echo "Set FORCE=1 to regenerate."
  exit 0
fi

if command -v openssl >/dev/null 2>&1; then
  SECRET="$(openssl rand -base64 32 | tr -d '\n')"
elif command -v python3 >/dev/null 2>&1; then
  SECRET="$(python3 -c 'import base64,os; print(base64.b64encode(os.urandom(32)).decode())')"
else
  SECRET="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
fi

cat > "${OUT}" <<EOF
key "${KEY_NAME}." {
    algorithm hmac-sha256;
    secret "${SECRET}";
};
EOF

chmod 600 "${OUT}"

# Convenience copy of the secret for inline nsupdate -y (lab only).
cat > "${KEYS_DIR}/update.secret" <<EOF
hmac-sha256:${KEY_NAME}:${SECRET}
EOF
chmod 600 "${KEYS_DIR}/update.secret"

echo "Wrote ${OUT}"
echo "Also wrote ${KEYS_DIR}/update.secret (for nsupdate -y)"
echo
echo "If the container is already running, restart it so ddnsd reloads the key:"
echo "  ./scripts/stop.sh && ./scripts/start.sh"
echo
echo "Example:"
echo "  nsupdate -k ${OUT}"
echo "  > server 127.0.0.1 5353"
echo "  > zone ${DDNS_ZONE}."
echo "  > update add demo.${DDNS_ZONE}. 300 A ${LAB_PREFIX}.50"
echo "  > send"
