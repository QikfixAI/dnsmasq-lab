#!/usr/bin/env bash
# End-to-end lab test: deps → cleanup → start → write nsupdate files →
# nsupdate add/delete → verify with dig and nslookup.
# Honors DNS_PORT (default 53). nslookup uses -port= when not 53.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

# shellcheck source=../scripts/load-config.sh
source "${ROOT}/scripts/load-config.sh"

ZONE="${DDNS_ZONE}"
PREFIX="${LAB_PREFIX}"
REV_ZONE="${DDNS_REV_ZONE}"
UPDATE_HOST="${NSUPDATE_HOST}"
KEY="${ROOT}/keys/update.key"
FORWARD_FILE="${ROOT}/data/nsupdate-forward.txt"
FORWARD_DELETE_FILE="${ROOT}/data/nsupdate-forward-delete.txt"
REVERSE_FILE="${ROOT}/data/nsupdate-reverse.txt"
REVERSE_DELETE_FILE="${ROOT}/data/nsupdate-reverse-delete.txt"

PASS=0
FAIL=0

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

# --- dig helpers -------------------------------------------------------------
dig_q() {
  local name="$1"
  local rtype="${2:-A}"
  dig @"${DNS_SERVER}" -p "${DNS_PORT}" "${name}" "${rtype}" +short +time=2 +tries=1 2>&1 || true
}

dig_x() {
  local ip="$1"
  dig @"${DNS_SERVER}" -p "${DNS_PORT}" -x "${ip}" +short +time=2 +tries=1 2>&1 || true
}

# --- nslookup helpers (supports remapped DNS_PORT via -port=) ----------------
nslookup_q() {
  # Usage: nslookup_q <name> [type]
  local name="$1"
  local rtype="${2:-}"
  if [[ -n "${rtype}" ]]; then
    nslookup -port="${DNS_PORT}" -type="${rtype}" "${name}" "${DNS_SERVER}" 2>&1 || true
  else
    nslookup -port="${DNS_PORT}" "${name}" "${DNS_SERVER}" 2>&1 || true
  fi
}

nslookup_x() {
  local ip="$1"
  nslookup -port="${DNS_PORT}" "${ip}" "${DNS_SERVER}" 2>&1 || true
}

# --- dual dig + nslookup expectations ----------------------------------------
expect_a() {
  local name="$1"
  local expect_ip="$2"
  local out

  out="$(dig_q "${name}" A)"
  if echo "${out}" | grep -qE "^${expect_ip}$"; then
    pass "dig ${name} A → ${expect_ip}"
  else
    fail "dig ${name} A expected ${expect_ip}"
    echo "${out}" | sed 's/^/      | /'
  fi

  out="$(nslookup_q "${name}")"
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

  out="$(dig_x "${ip}")"
  if echo "${out}" | grep -qiE "^${expect_name}\\.?\$"; then
    pass "dig -x ${ip} → ${expect_name}"
  else
    fail "dig -x ${ip} expected PTR ${expect_name}"
    echo "${out}" | sed 's/^/      | /'
  fi

  out="$(nslookup_x "${ip}")"
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

  out="$(dig_q "${name}" A)"
  if [[ -z "${out}" ]]; then
    pass "dig ${name} A → empty (deleted)"
  elif echo "${out}" | grep -qiE "NXDOMAIN|SERVFAIL|connection timed out|no servers"; then
    pass "dig ${name} A → no answer (deleted)"
  elif [[ -n "${banned_ip}" ]] && echo "${out}" | grep -qE "^${banned_ip}$"; then
    fail "dig ${name} A still resolves to ${banned_ip} after delete"
    echo "${out}" | sed 's/^/      | /'
  elif ! echo "${out}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    pass "dig ${name} A → no A address (deleted)"
  else
    fail "dig ${name} A still has an A address after delete"
    echo "${out}" | sed 's/^/      | /'
  fi

  out="$(nslookup_q "${name}")"
  if echo "${out}" | grep -qiE "NXDOMAIN|can't find|server can't find"; then
    pass "nslookup ${name} → NXDOMAIN (deleted)"
    return
  fi
  if [[ -n "${banned_ip}" ]] && echo "${out}" | grep -qE "Address:[[:space:]]+${banned_ip}([[:space:]]|$)"; then
    fail "nslookup ${name} still resolves to ${banned_ip} after delete"
    echo "${out}" | sed 's/^/      | /'
    return
  fi
  if ! echo "${out}" | grep -qE "Address:[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"; then
    pass "nslookup ${name} → no A address (deleted)"
    return
  fi
  fail "nslookup ${name} still has an A address after delete"
  echo "${out}" | sed 's/^/      | /'
}

expect_txt() {
  local name="$1"
  local expect_txt="$2"
  local out

  out="$(dig_q "${name}" TXT)"
  if echo "${out}" | grep -qF "${expect_txt}"; then
    pass "dig ${name} TXT → ${expect_txt}"
  else
    fail "dig ${name} TXT expected '${expect_txt}'"
    echo "${out}" | sed 's/^/      | /'
  fi

  out="$(nslookup_q "${name}" TXT)"
  if echo "${out}" | grep -qF "${expect_txt}"; then
    pass "nslookup ${name} TXT → ${expect_txt}"
  else
    fail "nslookup ${name} TXT expected '${expect_txt}'"
    echo "${out}" | sed 's/^/      | /'
  fi
}

expect_no_txt() {
  local name="$1"
  local banned_txt="$2"
  local out

  out="$(dig_q "${name}" TXT)"
  if [[ -z "${out}" ]] || ! echo "${out}" | grep -qF "${banned_txt}"; then
    pass "dig ${name} TXT → absent (deleted)"
  else
    fail "dig ${name} TXT still has '${banned_txt}' after delete"
    echo "${out}" | sed 's/^/      | /'
  fi

  out="$(nslookup_q "${name}" TXT)"
  if ! echo "${out}" | grep -qF "${banned_txt}"; then
    pass "nslookup ${name} TXT → absent (deleted)"
  else
    fail "nslookup ${name} TXT still has '${banned_txt}' after delete"
    echo "${out}" | sed 's/^/      | /'
  fi
}

expect_cname() {
  local name="$1"
  local expect_target="$2"
  local out

  out="$(dig_q "${name}" CNAME)"
  if echo "${out}" | grep -qiE "^${expect_target}\\.?\$"; then
    pass "dig ${name} CNAME → ${expect_target}"
  else
    fail "dig ${name} CNAME expected '${expect_target}'"
    echo "${out}" | sed 's/^/      | /'
  fi

  out="$(nslookup_q "${name}" CNAME)"
  if echo "${out}" | grep -qiE "(canonical name[[:space:]]*=[[:space:]]*|${expect_target})"; then
    if echo "${out}" | grep -qiF "${expect_target}"; then
      pass "nslookup ${name} CNAME → ${expect_target}"
    else
      fail "nslookup ${name} CNAME expected '${expect_target}'"
      echo "${out}" | sed 's/^/      | /'
    fi
  else
    fail "nslookup ${name} CNAME expected '${expect_target}'"
    echo "${out}" | sed 's/^/      | /'
  fi
}

expect_no_cname() {
  local name="$1"
  local banned_target="$2"
  local out

  out="$(dig_q "${name}" CNAME)"
  if [[ -z "${out}" ]] || ! echo "${out}" | grep -qiE "^${banned_target}\\.?\$"; then
    pass "dig ${name} CNAME → absent (deleted)"
  else
    fail "dig ${name} CNAME still has '${banned_target}' after delete"
    echo "${out}" | sed 's/^/      | /'
  fi

  out="$(nslookup_q "${name}" CNAME)"
  if ! echo "${out}" | grep -qiF "${banned_target}"; then
    pass "nslookup ${name} CNAME → absent (deleted)"
  else
    fail "nslookup ${name} CNAME still has '${banned_target}' after delete"
    echo "${out}" | sed 's/^/      | /'
  fi
}

expect_aaaa() {
  local name="$1"
  local expect_ip="$2"
  local out

  out="$(dig_q "${name}" AAAA)"
  if echo "${out}" | grep -qi "${expect_ip}"; then
    pass "dig ${name} AAAA → ${expect_ip}"
  else
    fail "dig ${name} AAAA expected '${expect_ip}'"
    echo "${out}" | sed 's/^/      | /'
  fi

  out="$(nslookup_q "${name}" AAAA)"
  if echo "${out}" | grep -qi "${expect_ip}"; then
    pass "nslookup ${name} AAAA → ${expect_ip}"
  else
    fail "nslookup ${name} AAAA expected '${expect_ip}'"
    echo "${out}" | sed 's/^/      | /'
  fi
}

expect_no_aaaa() {
  local name="$1"
  local banned_ip="$2"
  local out

  out="$(dig_q "${name}" AAAA)"
  if [[ -z "${out}" ]] || ! echo "${out}" | grep -qi "${banned_ip}"; then
    pass "dig ${name} AAAA → absent (deleted)"
  else
    fail "dig ${name} AAAA still has '${banned_ip}' after delete"
    echo "${out}" | sed 's/^/      | /'
  fi

  out="$(nslookup_q "${name}" AAAA)"
  if ! echo "${out}" | grep -qi "${banned_ip}"; then
    pass "nslookup ${name} AAAA → absent (deleted)"
  else
    fail "nslookup ${name} AAAA still has '${banned_ip}' after delete"
    echo "${out}" | sed 's/^/      | /'
  fi
}

expect_no_ptr() {
  local ip="$1"
  local banned_name="$2"
  local out

  out="$(dig_x "${ip}")"
  if echo "${out}" | grep -qiE "^${banned_name}\\.?\$"; then
    fail "dig -x ${ip} still has PTR ${banned_name} after delete"
    echo "${out}" | sed 's/^/      | /'
  else
    pass "dig -x ${ip} → PTR ${banned_name} absent"
  fi

  out="$(nslookup_x "${ip}")"
  if echo "${out}" | grep -qiE "(name[[:space:]]*=[[:space:]]*|Name:[[:space:]]*)${banned_name}\\.?"; then
    fail "nslookup ${ip} still has PTR ${banned_name} after delete"
    echo "${out}" | sed 's/^/      | /'
    return
  fi
  pass "nslookup ${ip} → PTR ${banned_name} absent"
}

wait_dns() {
  local i
  local reason="${1:-DNS ready}"
  local out
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
    out="$(dig_q static.${ZONE} A)"
    if echo "${out}" | grep -qE "^${DDNS_STATIC_IP}$"; then
      return 0
    fi
    sleep 0.25
  done
  echo "error: ${reason} — DNS not ready on ${DNS_SERVER}:${DNS_PORT} (static.${ZONE})" >&2
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

# After conf-file updates, dnsmasq is restarted (brief gap). Poll until ready.
wait_after_conf_update() {
  local reason="${1:-after conf-file nsupdate}"
  sleep 0.5
  wait_dns "${reason}"
}

write_nsupdate_files() {
  # Reclaim data/ so host can rewrite artifacts after container ownership changes.
  mkdir -p data
  chmod -R u+rwX data 2>/dev/null || true
  chown -R "$(id -u):$(id -g)" data 2>/dev/null || true

  log "Writing forward nsupdate file → ${FORWARD_FILE}"
  cat > "${FORWARD_FILE}" <<EOF
server ${UPDATE_HOST} ${UPDATE_PORT}
zone ${ZONE}.
update add srv02.${ZONE}. 300 A ${PREFIX}.101
update add ocpsrv.ocpcluster.${ZONE}. 86400 A ${PREFIX}.101
update add api.ocpcluster.${ZONE}. 86400 A ${PREFIX}.101
update add api-int.ocpcluster.${ZONE}. 86400 A ${PREFIX}.101
update add *.apps.ocpcluster.${ZONE}. 86400 A ${PREFIX}.101
update add info.${ZONE}. 300 TXT "lab-test-record"
update add alias.${ZONE}. 300 CNAME static.${ZONE}.
update add ipv6.${ZONE}. 300 AAAA fd00::101
send
EOF
  echo "OK    wrote ${FORWARD_FILE}"
  sed 's/^/      | /' "${FORWARD_FILE}"

  log "Writing forward delete nsupdate file → ${FORWARD_DELETE_FILE}"
  cat > "${FORWARD_DELETE_FILE}" <<EOF
server ${UPDATE_HOST} ${UPDATE_PORT}
zone ${ZONE}.
update delete srv02.${ZONE}. A
update delete ocpsrv.ocpcluster.${ZONE}. A
update delete api.ocpcluster.${ZONE}. A
update delete api-int.ocpcluster.${ZONE}. A
update delete *.apps.ocpcluster.${ZONE}. A
update delete info.${ZONE}. TXT
update delete alias.${ZONE}. CNAME
update delete ipv6.${ZONE}. AAAA
send
EOF
  echo "OK    wrote ${FORWARD_DELETE_FILE}"
  sed 's/^/      | /' "${FORWARD_DELETE_FILE}"

  log "Writing reverse nsupdate file → ${REVERSE_FILE}"
  cat > "${REVERSE_FILE}" <<EOF
server ${UPDATE_HOST} ${UPDATE_PORT}
zone ${REV_ZONE}.
update add 200.${REV_ZONE}. 300 PTR reverse-test.${ZONE}.
send
EOF
  echo "OK    wrote ${REVERSE_FILE}"
  sed 's/^/      | /' "${REVERSE_FILE}"

  log "Writing reverse delete nsupdate file → ${REVERSE_DELETE_FILE}"
  cat > "${REVERSE_DELETE_FILE}" <<EOF
server ${UPDATE_HOST} ${UPDATE_PORT}
zone ${REV_ZONE}.
update delete 200.${REV_ZONE}. PTR
send
EOF
  echo "OK    wrote ${REVERSE_DELETE_FILE}"
  sed 's/^/      | /' "${REVERSE_DELETE_FILE}"
}

# --- dependency checks -------------------------------------------------------
log "Checking dependencies"
need_cmd podman "Install podman (e.g. dnf install -y podman)."
need_cmd nsupdate "Install bind-utils (RHEL/Fedora) or dnsutils (Debian/Ubuntu)."
need_cmd dig "Install bind-utils (RHEL/Fedora) or dnsutils (Debian/Ubuntu)."
need_cmd nslookup "Install bind-utils (RHEL/Fedora) or dnsutils (Debian/Ubuntu)."
if ! command -v openssl >/dev/null 2>&1 \
  && ! command -v python3 >/dev/null 2>&1 \
  && ! command -v base64 >/dev/null 2>&1; then
  echo "FAIL  need openssl, python3, or base64 to generate the TSIG key" >&2
  exit 1
fi
echo "OK    TSIG secret generator available"
echo "OK    using DNS ${DNS_SERVER}:${DNS_PORT}, nsupdate ${UPDATE_HOST}:${UPDATE_PORT}"
echo "OK    zone=${ZONE} prefix=${PREFIX} rev=${REV_ZONE}"

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

# --- write all nsupdate artifacts (add + delete) -----------------------------
write_nsupdate_files

# --- apply forward adds ------------------------------------------------------
log "Applying forward updates with nsupdate"
nsupdate -k "${KEY}" -v "${FORWARD_FILE}"
wait_after_conf_update "after forward nsupdate"
pass "nsupdate forward file applied"

log "Checking forward records with dig and nslookup"
expect_a "srv02.${ZONE}" "${PREFIX}.101"
expect_a "ocpsrv.ocpcluster.${ZONE}" "${PREFIX}.101"
expect_a "api.ocpcluster.${ZONE}" "${PREFIX}.101"
expect_a "api-int.ocpcluster.${ZONE}" "${PREFIX}.101"
# Wildcard owner is not a query name; probe child labels under *.apps...
expect_a "console.apps.ocpcluster.${ZONE}" "${PREFIX}.101"
expect_a "foo.apps.ocpcluster.${ZONE}" "${PREFIX}.101"

log "Checking TXT/CNAME/AAAA with dig and nslookup"
expect_txt "info.${ZONE}" "lab-test-record"
expect_cname "alias.${ZONE}" "static.${ZONE}"
expect_aaaa "ipv6.${ZONE}" "fd00::101"

# --- apply reverse add -------------------------------------------------------
log "Applying reverse update with nsupdate"
nsupdate -k "${KEY}" -v "${REVERSE_FILE}"
wait_after_conf_update "after reverse nsupdate"
pass "nsupdate reverse file applied"

log "Checking reverse record with dig and nslookup"
expect_ptr "${PREFIX}.200" "reverse-test.${ZONE}"

# --- reverse delete ----------------------------------------------------------
log "Applying reverse deletes with nsupdate"
nsupdate -k "${KEY}" -v "${REVERSE_DELETE_FILE}"
wait_after_conf_update "after reverse delete nsupdate"
pass "nsupdate reverse delete file applied"

log "Checking reverse record removed with dig and nslookup"
expect_no_ptr "${PREFIX}.200" "reverse-test.${ZONE}"

# --- forward delete ----------------------------------------------------------
log "Applying forward deletes with nsupdate"
nsupdate -k "${KEY}" -v "${FORWARD_DELETE_FILE}"
wait_after_conf_update "after forward delete nsupdate"
pass "nsupdate forward delete file applied"

log "Checking forward records removed with dig and nslookup"
expect_no_a "srv02.${ZONE}" "${PREFIX}.101"
expect_no_a "ocpsrv.ocpcluster.${ZONE}" "${PREFIX}.101"
expect_no_a "api.ocpcluster.${ZONE}" "${PREFIX}.101"
expect_no_a "api-int.ocpcluster.${ZONE}" "${PREFIX}.101"
expect_no_a "console.apps.ocpcluster.${ZONE}" "${PREFIX}.101"
expect_no_a "foo.apps.ocpcluster.${ZONE}" "${PREFIX}.101"
expect_no_txt "info.${ZONE}" "lab-test-record"
expect_no_cname "alias.${ZONE}" "static.${ZONE}"
expect_no_aaaa "ipv6.${ZONE}" "fd00::101"
# Bootstrap static record must still work after deletes.
expect_a "static.${ZONE}" "${DDNS_STATIC_IP}"

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
echo "Artifacts (populated by this test):"
echo "  ${FORWARD_FILE}"
echo "  ${FORWARD_DELETE_FILE}"
echo "  ${REVERSE_FILE}"
echo "  ${REVERSE_DELETE_FILE}"
exit 0
