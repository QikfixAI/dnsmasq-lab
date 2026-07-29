#!/bin/sh
set -eu

ZONE_JSON="${DDNS_STATE_FILE:-/data/zone.json}"
DYNAMIC_CONF="${DDNS_CONF_FILE:-/data/dynamic.conf}"
DYNAMIC_HOSTS="${DDNS_HOSTS_FILE:-/data/dynamic.hosts}"
PID_FILE="${DNSMASQ_PID_FILE:-/run/dnsmasq.pid}"
DDNS_PORT="${DDNS_PORT:-5353}"

mkdir -p /data /keys /run
[ -f "$ZONE_JSON" ] || echo '{}' > "$ZONE_JSON"
[ -f "$DYNAMIC_CONF" ] || echo '# waiting for ddnsd' > "$DYNAMIC_CONF"
[ -f "$DYNAMIC_HOSTS" ] || echo '# waiting for ddnsd' > "$DYNAMIC_HOSTS"

if [ ! -f /keys/update.key ]; then
  echo "[entrypoint] ERROR: /keys/update.key missing." >&2
  echo "[entrypoint] Generate it with: ./scripts/generate-tsig-key.sh" >&2
  exit 1
fi

python3 /usr/local/bin/ddnsd.py &
DDNSD_PID=$!
echo "[entrypoint] ddnsd started (pid $DDNSD_PID)"

# Wait until ddnsd has rendered zone files and is accepting UPDATEs.
# dnsmasq must not start earlier: conf-file (address=/… wildcards) is only
# read at process start, not on SIGHUP.
ready=0
i=0
while [ "$i" -lt 50 ]; do
  if python3 -c "
import socket
s = socket.socket()
s.settimeout(0.2)
try:
    s.connect(('127.0.0.1', int('${DDNS_PORT}')))
except Exception:
    raise SystemExit(1)
finally:
    s.close()
" 2>/dev/null; then
    ready=1
    break
  fi
  i=$((i + 1))
  sleep 0.1
done
if [ "$ready" -ne 1 ]; then
  echo "[entrypoint] ddnsd failed to become ready on :${DDNS_PORT}" >&2
  kill "$DDNSD_PID" 2>/dev/null || true
  exit 1
fi
echo "[entrypoint] ddnsd is ready"

DNSMASQ_PID=""

start_dnsmasq() {
  # Drop a stale pid file so we do not mistake a dead pid for success.
  rm -f "$PID_FILE"
  attempt=1
  while [ "$attempt" -le 15 ]; do
    dnsmasq &
    child=$!
    # Wait for pid file or a live child; port 53 may still be releasing.
    j=0
    while [ "$j" -lt 20 ]; do
      if [ -f "$PID_FILE" ]; then
        DNSMASQ_PID="$(tr -d ' \n' < "$PID_FILE")"
        if [ -n "$DNSMASQ_PID" ] && kill -0 "$DNSMASQ_PID" 2>/dev/null; then
          echo "[entrypoint] dnsmasq started (pid $DNSMASQ_PID)"
          return 0
        fi
      elif kill -0 "$child" 2>/dev/null; then
        :
      else
        break
      fi
      j=$((j + 1))
      sleep 0.1
    done
    echo "[entrypoint] dnsmasq start attempt ${attempt} failed; retrying"
    kill "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    rm -f "$PID_FILE"
    attempt=$((attempt + 1))
    sleep 0.2
  done
  echo "[entrypoint] dnsmasq failed to start" >&2
  return 1
}

cleanup() {
  echo "[entrypoint] shutting down"
  kill "$DDNSD_PID" 2>/dev/null || true
  if [ -n "$DNSMASQ_PID" ]; then
    kill "$DNSMASQ_PID" 2>/dev/null || true
  fi
  wait 2>/dev/null || true
}
trap cleanup INT TERM

start_dnsmasq || { kill "$DDNSD_PID" 2>/dev/null || true; exit 1; }

# Supervise dnsmasq so ddnsd can restart it (SIGTERM) after conf-file updates.
while kill -0 "$DDNSD_PID" 2>/dev/null; do
  if ! kill -0 "$DNSMASQ_PID" 2>/dev/null; then
    echo "[entrypoint] dnsmasq exited; restarting"
    # Brief pause so the previous process can release :53.
    sleep 0.3
    if ! start_dnsmasq; then
      echo "[entrypoint] dnsmasq restart failed; will retry" >&2
      sleep 1
      continue
    fi
  fi
  sleep 0.5
done

echo "[entrypoint] ddnsd exited; stopping" >&2
cleanup
exit 1
