#!/usr/bin/env bash
# Load config/lab.env (+ optional config/lab.local.env) and derive lab defaults.
# Usage: source this file after ROOT is set (or it will detect the repo root).
#
# Precedence (highest wins): existing environment → lab.local.env → lab.env → built-in defaults.

if [[ -z "${ROOT:-}" ]]; then
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

declare -A _LAB_CFG=()

_lab_parse_env_file() {
  local file="$1"
  local line key val
  [[ -f "${file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    if [[ "${val}" =~ ^\"(.*)\"$ ]]; then
      val="${BASH_REMATCH[1]}"
    elif [[ "${val}" =~ ^\'(.*)\'$ ]]; then
      val="${BASH_REMATCH[1]}"
    fi
    _LAB_CFG["${key}"]="${val}"
  done < "${file}"
}

_lab_ipv4_last_octet() {
  local ip="$1"
  local a b c d
  IFS=. read -r a b c d <<< "${ip}"
  if [[ -n "${d}" && "${d}" =~ ^[0-9]+$ && -z "${d//[0-9]/}" ]]; then
    printf '%s' "${d}"
    return 0
  fi
  return 1
}

_lab_fail() {
  echo "error: $*" >&2
  unset -f _lab_parse_env_file _lab_ipv4_last_octet _lab_fail _lab_write_env 2>/dev/null || true
  unset _LAB_CFG _lab_key _lab_a _lab_b _lab_c _lab_d _lab_mask _lab_rest
  return 1 2>/dev/null || exit 1
}

_lab_parse_env_file "${ROOT}/config/lab.env"
_lab_parse_env_file "${ROOT}/config/lab.local.env"

for _lab_key in "${!_LAB_CFG[@]}"; do
  if [[ -z "${!_lab_key+x}" ]]; then
    printf -v "${_lab_key}" '%s' "${_LAB_CFG[${_lab_key}]}"
    export "${_lab_key?}"
  fi
done

# --- Domain -----------------------------------------------------------------
DDNS_ZONE="${DDNS_ZONE:-example.com}"
export DDNS_ZONE

# --- Network: CIDR → prefix / reverse zone ---------------------------------
LAB_CIDR="${LAB_CIDR:-192.168.0.0/24}"
export LAB_CIDR

if [[ -z "${LAB_PREFIX:-}" ]]; then
  if [[ "${LAB_CIDR}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)/([0-9]+)$ ]]; then
    _lab_a="${BASH_REMATCH[1]}"
    _lab_b="${BASH_REMATCH[2]}"
    _lab_c="${BASH_REMATCH[3]}"
    _lab_d="${BASH_REMATCH[4]}"
    _lab_mask="${BASH_REMATCH[5]}"
    if [[ "${_lab_mask}" != "24" ]]; then
      _lab_fail "LAB_CIDR must be a /24 network (got /${_lab_mask}): ${LAB_CIDR}"
    fi
    if [[ "${_lab_d}" != "0" ]]; then
      _lab_fail "LAB_CIDR host bits must be .0 for /24 (got ${LAB_CIDR})"
    fi
    LAB_PREFIX="${_lab_a}.${_lab_b}.${_lab_c}"
  else
    _lab_fail "LAB_CIDR must look like 192.168.0.0/24 (got: ${LAB_CIDR})"
  fi
fi
export LAB_PREFIX

DDNS_GW_IP="${DDNS_GW_IP:-${LAB_PREFIX}.1}"
DDNS_STATIC_IP="${DDNS_STATIC_IP:-${LAB_PREFIX}.10}"
DDNS_NS1_IP="${DDNS_NS1_IP:-${LAB_PREFIX}.53}"
export DDNS_GW_IP DDNS_STATIC_IP DDNS_NS1_IP

if [[ -z "${DDNS_GW_PTR:-}" ]]; then
  DDNS_GW_PTR="$(_lab_ipv4_last_octet "${DDNS_GW_IP}")" || _lab_fail "invalid DDNS_GW_IP: ${DDNS_GW_IP}"
fi
if [[ -z "${DDNS_STATIC_PTR:-}" ]]; then
  DDNS_STATIC_PTR="$(_lab_ipv4_last_octet "${DDNS_STATIC_IP}")" || _lab_fail "invalid DDNS_STATIC_IP: ${DDNS_STATIC_IP}"
fi
if [[ -z "${DDNS_NS1_PTR:-}" ]]; then
  DDNS_NS1_PTR="$(_lab_ipv4_last_octet "${DDNS_NS1_IP}")" || _lab_fail "invalid DDNS_NS1_IP: ${DDNS_NS1_IP}"
fi
export DDNS_GW_PTR DDNS_STATIC_PTR DDNS_NS1_PTR

if [[ -z "${DDNS_REV_ZONE:-}" ]]; then
  IFS=. read -r _lab_a _lab_b _lab_c _lab_rest <<< "${LAB_PREFIX}"
  if [[ -n "${_lab_a}" && -n "${_lab_b}" && -n "${_lab_c}" && -z "${_lab_rest}" ]]; then
    DDNS_REV_ZONE="${_lab_c}.${_lab_b}.${_lab_a}.in-addr.arpa"
  else
    _lab_fail "LAB_PREFIX must be three octets (e.g. 192.168.0), got: ${LAB_PREFIX}"
  fi
fi
export DDNS_REV_ZONE

UPSTREAM_DNS_1="${UPSTREAM_DNS_1:-1.1.1.1}"
UPSTREAM_DNS_2="${UPSTREAM_DNS_2:-8.8.8.8}"
export UPSTREAM_DNS_1 UPSTREAM_DNS_2

# --- Ports & auth -----------------------------------------------------------
DNS_PORT="${DNS_PORT:-53}"
UPDATE_PORT="${UPDATE_PORT:-5353}"
export DNS_PORT UPDATE_PORT

DDNS_KEY_NAME="${DDNS_KEY_NAME:-update-key}"
export DDNS_KEY_NAME

DDNS_PORT="${DDNS_PORT:-5353}"
export DDNS_PORT

# --- Container --------------------------------------------------------------
CONTAINER_NAME="${CONTAINER_NAME:-dnsmasq-lab}"
IMAGE_NAME="${IMAGE_NAME:-localhost/dnsmasq-lab:latest}"
export CONTAINER_NAME IMAGE_NAME

NSUPDATE_HOST="${NSUPDATE_HOST:-127.0.0.1}"
DNS_SERVER="${DNS_SERVER:-127.0.0.1}"
export NSUPDATE_HOST DNS_SERVER

unset -f _lab_parse_env_file _lab_ipv4_last_octet _lab_fail
unset _LAB_CFG _lab_key _lab_a _lab_b _lab_c _lab_d _lab_mask _lab_rest
