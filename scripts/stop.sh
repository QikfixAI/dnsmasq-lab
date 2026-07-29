#!/usr/bin/env bash
set -euo pipefail

NAME="${CONTAINER_NAME:-dnsmasq-lab}"

if podman container exists "${NAME}" 2>/dev/null; then
  podman rm -f "${NAME}"
  echo "Stopped and removed ${NAME}"
else
  echo "Container ${NAME} is not running"
fi
