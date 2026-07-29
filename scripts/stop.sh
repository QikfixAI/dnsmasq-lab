#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=load-config.sh
source "${ROOT}/scripts/load-config.sh"

NAME="${CONTAINER_NAME}"

if podman container exists "${NAME}" 2>/dev/null; then
  podman rm -f "${NAME}"
  echo "Stopped and removed ${NAME}"
else
  echo "Container ${NAME} is not running"
fi
