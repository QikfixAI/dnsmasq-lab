#!/usr/bin/env bash
# End-to-end lab test: deps → cleanup → start → nsupdate add/delete → nslookup.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

DNS_SERVER="${DNS_SERVER:-127.0.0.1}"
DNS_PORT="${DNS_PORT:-53}"
UPDATE_HOST="${NSUPDATE_HOST:-127.0.0.1}"
UPDATE_PORT="${UPDATE_PORT:-5353}"
KEY="${ROOT}/keys/update.key"
FORWARD_FILE="${ROOT}/data/nsupdate-forward.txt"
FORWARD_DELETE_FILE="${ROOT}/data/nsupdate-forward-delete.txt"
REVERSE_FILE="${ROOT}/data/nsupdate-reverse.txt"
REVERSE_DELETE_FILE="${ROOT}/data/nsupdate-reverse-delete.txt"
CONTAINER_NAME="${CONTAINER_NAME:-dnsmasq-lab}"

PASS=0
FAIL=0

# nslookup does not take -p; for non-53 use dig. Default lab uses 53.
if [[ "${DNS_PORT}" != "53" ]]; then
  echo "error: this test uses nslookup, which requires DNS on host port 53." >&2
  echo "       unset DNS_PORT or set DNS_PORT=53." >&2
  exit 1
fi

need_cmd() {
  local cmd="$1"
  local hint="${2:-}"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "FAIL  missing dependency: ${cmd}" >&2
    if [[ -n "${hint}" ]]; then
      echo "      ${hint}" >&2
    fi
    exit 1
  fi
  echo "OK    found ${cmd} ($(command -v "${cmd}"))"
}

log() { echo; echo "==> $*"; }

pass() { echo "PASS  $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL  $*"; FAIL=$((FAIL + 1)); }

expect_a() {
  local name="$1"
  local expect_ip="$2"
  local out
  out="$(nslookup "${name}" "${DNS_SERVER}" 2>&1)" || true
  if echo "${out}" | grep -qE "Address:[[:space:]]+${expect_ip}([[:space:]]|$)"; then
    pass "nslookup ${name} → ${expect_ip}"
  else
    fail "nslookup ${name} expected Address ${expect_ip}"
    echo "${out}" | sed 's/^/      | /'
  fi
}

expect_ptr() {
  local ip="$1"
  local expect_name="$2"
  local out
  out="$(nslookup "${ip}" "${DNS_SERVER}" 2>&1)" || true
  # nslookup reverse lines look like: "name = reverse-test.example.com."
  if echo "${out}" | grep -qiE "(name[[:space:]]*=[[:space:]]*|Name:[[:space:]]*)${expect_name}\\.?"; then
    pass "nslookup ${ip} → ${expect_name}"
  else
    fail "nslookup ${ip} expected PTR ${expect_name}"
    echo "${out}" | sed 's/^/      | /'
  fi
}

expect_no_a() {
  local name="$1"
  local banned_ip="${2:-}"
  local out
  out="$(nslookup "${name}" "${DNS_SERVER}" 2>&1)" || true
  if echo "${out}" | grep -qiE "NXDOMAIN|can't find|server can't find"; then
    pass "nslookup ${name} → NXDOMAIN (deleted)"
    return
  fi
  if [[ -n "${banned_ip}" ]] && echo "${out}" | grep -qE "Address:[[:space:]]+${banned_ip}([[:space:]]|$)"; then
    fail "nslookup ${name} still resolves to ${banned_ip} after delete"
    echo "${out}" | sed 's/^/      | /'
    return
  fi
  # NOERROR with no matching A is also acceptable for some names.
  if ! echo "${out}" | grep -qE "Address:[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"; then
    pass "nslookup ${name} → no A address (deleted)"
    return
  fi
  fail "nslookup ${name} still has an A address after delete"
  echo "${out}" | sed 's/^/      | /'
}

expect_no_ptr() {
  local ip="$1"
  local banned_name="$2"
  local out
  out="$(nslookup "${ip}" "${DNS_SERVER}" 2>&1)" || true
  if echo "${out}" | grep -qiE "(name[[:space:]]*=[[:space:]]*|Name:[[:space:]]*)${banned_name}\\.?"; then
    fail "nslookup ${ip} still has PTR ${banned_name} after delete"
    echo "${out}" | sed 's/^/      | /'
    return
  fi
  if echo "${out}" | grep -qiE "NXDOMAIN|can't find|server can't find|No PTR"; then
    pass "nslookup ${ip} → no PTR (deleted)"
    return
  fi
  # Some resolvers print only the server banner when PTR is missing.
  pass "nslookup ${ip} → PTR ${banned_name} absent"
}

wait_dns() {
  local i
  local reason="${1:-DNS ready}"
  for i in $(seq 1 80); do
    if ! podman container exists "${CONTAINER_NAME}" 2>/dev/null; then
      echo "error: container ${CONTAINER_NAME} is gone" >&2
      exit 1
    fi
    if ! podman inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null | grep -q true; then
      echo "error: container ${CONTAINER_NAME} is not running" >&2
      podman logs "${CONTAINER_NAME}" 2>&1 | tail -40 >&2 || true
      exit 1
    fi
    if nslookup static.example.com "${DNS_SERVER}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  echo "error: ${reason} — DNS not ready on ${DNS_SERVER}:53 (static.example.com)" >&2
  podman logs "${CONTAINER_NAME}" 2>&1 | tail -40 >&2 || true
  exit 1
}

wait_update() {
  local i
  for i in $(seq 1 40); do
    if (echo >/dev/tcp/"${UPDATE_HOST}"/"${UPDATE_PORT}") >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  echo "error: nsupdate port ${UPDATE_HOST}:${UPDATE_PORT} not open" >&2
  exit 1
}

# --- dependency checks -------------------------------------------------------
log "Checking dependencies"
need_cmd podman "Install podman (e.g. dnf install -y podman)."
need_cmd nsupdate "Install bind-utils (RHEL/Fedora) or dnsutils (Debian/Ubuntu)."
need_cmd nslookup "Install bind-utils (RHEL/Fedora) or dnsutils (Debian/Ubuntu)."
if ! command -v openssl >/dev/null 2>&1 \
  && ! command -v python3 >/dev/null 2>&1 \
  && ! command -v base64 >/dev/null 2>&1; then
  echo "FAIL  need openssl, python3, or base64 to generate the TSIG key" >&2
  exit 1
fi
echo "OK    TSIG secret generator available"

# --- cleanup -----------------------------------------------------------------
log "Cleaning previous lab state"
./mgmt-scripts/cleanup.sh -y

# --- start -------------------------------------------------------------------
log "Starting lab"
./scripts/start.sh
wait_update
wait_dns
pass "lab is up (DNS :${DNS_PORT}, nsupdate :${UPDATE_PORT})"

if [[ ! -f "${KEY}" ]]; then
  echo "error: TSIG key missing after start: ${KEY}" >&2
  exit 1
fi

# --- forward nsupdate file ---------------------------------------------------
log "Writing forward nsupdate file → ${FORWARD_FILE}"
mkdir -p data
cat > "${FORWARD_FILE}" <<EOF
server ${UPDATE_HOST} ${UPDATE_PORT}
zone example.com.
update add srv02.example.com. 300 A 192.168.0.101
update add ocpsrv.ocpcluster.example.com. 86400 A 192.168.0.101
update add api.ocpcluster.example.com. 86400 A 192.168.0.101
update add api-int.ocpcluster.example.com. 86400 A 192.168.0.101
update add *.apps.ocpcluster.example.com. 86400 A 192.168.0.101
send
EOF
echo "OK    wrote ${FORWARD_FILE}"
sed 's/^/      | /' "${FORWARD_FILE}"

cat > "${FORWARD_DELETE_FILE}" <<EOF
server ${UPDATE_HOST} ${UPDATE_PORT}
zone example.com.
update delete srv02.example.com. A
update delete ocpsrv.ocpcluster.example.com. A
update delete api.ocpcluster.example.com. A
update delete api-int.ocpcluster.example.com. A
update delete *.apps.ocpcluster.example.com. A
send
EOF
echo "OK    wrote ${FORWARD_DELETE_FILE}"

log "Applying forward updates with nsupdate"
nsupdate -k "${KEY}" -v "${FORWARD_FILE}"
# Wildcard updates rewrite conf-file and restart dnsmasq; wait for it to return.
sleep 1
wait_dns "after forward nsupdate"
pass "nsupdate forward file applied"

# --- forward checks ----------------------------------------------------------
log "Checking forward records with nslookup"
expect_a "srv02.example.com" "192.168.0.101"
expect_a "ocpsrv.ocpcluster.example.com" "192.168.0.101"
expect_a "api.ocpcluster.example.com" "192.168.0.101"
expect_a "api-int.ocpcluster.example.com" "192.168.0.101"
# Wildcard owner is not a query name; probe a child label under *.apps...
expect_a "console.apps.ocpcluster.example.com" "192.168.0.101"
expect_a "foo.apps.ocpcluster.example.com" "192.168.0.101"

# --- reverse nsupdate file ---------------------------------------------------
log "Writing reverse nsupdate file → ${REVERSE_FILE}"
cat > "${REVERSE_FILE}" <<EOF
server ${UPDATE_HOST} ${UPDATE_PORT}
zone 0.168.192.in-addr.arpa.
update add 200.0.168.192.in-addr.arpa. 300 PTR reverse-test.example.com.
send
EOF
echo "OK    wrote ${REVERSE_FILE}"
sed 's/^/      | /' "${REVERSE_FILE}"

cat > "${REVERSE_DELETE_FILE}" <<EOF
server ${UPDATE_HOST} ${UPDATE_PORT}
zone 0.168.192.in-addr.arpa.
update delete 200.0.168.192.in-addr.arpa. PTR
send
EOF
echo "OK    wrote ${REVERSE_DELETE_FILE}"

log "Applying reverse update with nsupdate"
nsupdate -k "${KEY}" -v "${REVERSE_FILE}"
sleep 1
wait_dns "after reverse nsupdate"
pass "nsupdate reverse file applied"

log "Checking reverse record with nslookup"
expect_ptr "192.168.0.200" "reverse-test.example.com"

# --- reverse delete ----------------------------------------------------------
log "Applying reverse deletes with nsupdate"
nsupdate -k "${KEY}" -v "${REVERSE_DELETE_FILE}"
sleep 1
wait_dns "after reverse delete nsupdate"
pass "nsupdate reverse delete file applied"

log "Checking reverse record removed with nslookup"
expect_no_ptr "192.168.0.200" "reverse-test.example.com"

# --- forward delete ----------------------------------------------------------
log "Applying forward deletes with nsupdate"
nsupdate -k "${KEY}" -v "${FORWARD_DELETE_FILE}"
sleep 1
wait_dns "after forward delete nsupdate"
pass "nsupdate forward delete file applied"

log "Checking forward records removed with nslookup"
expect_no_a "srv02.example.com" "192.168.0.101"
expect_no_a "ocpsrv.ocpcluster.example.com" "192.168.0.101"
expect_no_a "api.ocpcluster.example.com" "192.168.0.101"
expect_no_a "api-int.ocpcluster.example.com" "192.168.0.101"
expect_no_a "console.apps.ocpcluster.example.com" "192.168.0.101"
expect_no_a "foo.apps.ocpcluster.example.com" "192.168.0.101"
# Bootstrap static record must still work after deletes.
expect_a "static.example.com" "192.168.0.10"

# --- summary -----------------------------------------------------------------
log "Summary"
echo "      passed: ${PASS}"
echo "      failed: ${FAIL}"
if [[ "${FAIL}" -ne 0 ]]; then
  echo
  echo "Test FAILED."
  exit 1
fi
echo
echo "Test PASSED."
echo "Artifacts:"
echo "  ${FORWARD_FILE}"
echo "  ${FORWARD_DELETE_FILE}"
echo "  ${REVERSE_FILE}"
echo "  ${REVERSE_DELETE_FILE}"
exit 0
