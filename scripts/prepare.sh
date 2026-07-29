#!/usr/bin/env bash
# Ensure TSIG key and empty dynamic zone files exist (idempotent).
# Used by start.sh so the lab has a key and writable data/ before the container runs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

# Resolve domain / subnet / ports from config/lab.env
# shellcheck source=load-config.sh
source "${ROOT}/scripts/load-config.sh"

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
# Reclaim ownership so host scripts can write after the container has run.
chmod -R u+rwX data 2>/dev/null || true
chown -R "$(id -u):$(id -g)" data 2>/dev/null || true
[[ -f data/zone.json ]] || echo '{}' > data/zone.json
[[ -f data/dynamic.conf ]] || echo '# dynamic TXT/CNAME/PTR records appear here' > data/dynamic.conf
[[ -f data/dynamic.hosts ]] || echo '# dynamic A/AAAA records appear here' > data/dynamic.hosts
touch data/.gitkeep

echo "Lab config: zone=${DDNS_ZONE} cidr=${LAB_CIDR} gw=${DDNS_GW_IP} DNS :${DNS_PORT} nsupdate :${UPDATE_PORT}"
