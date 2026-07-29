#!/usr/bin/env bash
# Install (or uninstall) a systemd unit that manages this lab via start.sh/stop.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNIT_NAME="dnsmasq-lab.service"
UNIT_SRC="${ROOT}/systemd/dnsmasq-lab.service.in"
UNIT_DST="/etc/systemd/system/${UNIT_NAME}"

usage() {
  cat <<'EOF'
Usage: ./scripts/install-systemd.sh [--uninstall] [-h|--help]

Installs a systemd oneshot unit that runs scripts/start.sh on boot and
scripts/stop.sh on stop. Requires root (port 53 / firewalld).

  --uninstall   Disable and remove the unit
  -h, --help    Show this help

After install:
  systemctl enable --now dnsmasq-lab.service
  systemctl status dnsmasq-lab.service
  journalctl -u dnsmasq-lab.service -f
EOF
}

UNINSTALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: run as root (e.g. sudo $0)" >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "error: systemctl not found" >&2
  exit 1
fi

if [[ "${UNINSTALL}" -eq 1 ]]; then
  systemctl disable --now "${UNIT_NAME}" 2>/dev/null || true
  rm -f "${UNIT_DST}"
  systemctl daemon-reload
  echo "Removed ${UNIT_DST}"
  exit 0
fi

if [[ ! -f "${UNIT_SRC}" ]]; then
  echo "error: missing unit template: ${UNIT_SRC}" >&2
  exit 1
fi

# Ensure key/data exist before first boot start.
"${ROOT}/scripts/prepare.sh"

sed "s|@LAB_ROOT@|${ROOT}|g" "${UNIT_SRC}" > "${UNIT_DST}"
chmod 644 "${UNIT_DST}"
systemctl daemon-reload

echo "Installed ${UNIT_DST}"
echo "  WorkingDirectory=${ROOT}"
echo
echo "Enable and start:"
echo "  systemctl enable --now ${UNIT_NAME}"
echo "Status / logs:"
echo "  systemctl status ${UNIT_NAME}"
echo "  journalctl -u ${UNIT_NAME} -f"
echo "Stop (keeps enable for next boot):"
echo "  systemctl stop ${UNIT_NAME}"
echo "Uninstall:"
echo "  ${ROOT}/scripts/install-systemd.sh --uninstall"
