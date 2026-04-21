#!/usr/bin/env bash
# =============================================================================
# stop.sh — tear down the container stack and stop Colima
# =============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

docker compose down
colima stop

echo "[ OK ] Stopped."
