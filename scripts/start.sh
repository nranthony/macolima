#!/usr/bin/env bash
# =============================================================================
# start.sh — start the Colima VM + bring up macolima profile(s)
# =============================================================================
# Usage:
#   scripts/start.sh                  # VM only, no profiles started
#   scripts/start.sh <profile>        # VM + one profile
#   scripts/start.sh <p1> <p2> ...    # VM + multiple profiles
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

: "${COLIMA_HOME:?COLIMA_HOME must be set — run: source ~/.zshrc}"

if colima status &>/dev/null; then
  echo "[INFO] Colima is already running."
else
  echo "[INFO] Starting Colima VM ..."
  colima start
  echo "[ OK ] Colima running."
fi

if [[ $# -eq 0 ]]; then
  echo "[INFO] No profiles specified. VM is up; start a profile with:"
  echo "         scripts/start.sh <profile>"
  echo "         scripts/setup.sh <profile> --restart"
  exit 0
fi

for p in "$@"; do
  echo "[INFO] Bringing up profile '$p' ..."
  "$REPO_ROOT/scripts/profile.sh" "$p" up
done

echo "[ OK ] Done."
