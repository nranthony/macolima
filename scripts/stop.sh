#!/usr/bin/env bash
# =============================================================================
# stop.sh — gracefully stop all macolima profiles + the Colima VM
# =============================================================================
# Stops containers first (preserving all persistent state), then the VM.
# Safe to run repeatedly. Reclaims ~10 GB of RAM.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILES_ROOT="/Volumes/DataDrive/.claude-colima/profiles"

if ! colima status &>/dev/null; then
  echo "[INFO] Colima is already stopped."
  exit 0
fi

# Discover running profiles by checking for claude-agent-<name> containers
running=()
for dir in "$PROFILES_ROOT"/*/; do
  name="$(basename "$dir")"
  if docker ps --format '{{.Names}}' | grep -qx "claude-agent-$name" 2>/dev/null; then
    running+=("$name")
  fi
done

if [[ ${#running[@]} -gt 0 ]]; then
  for p in "${running[@]}"; do
    echo "[INFO] Stopping profile '$p' ..."
    PROFILE="$p" COMPOSE_PROJECT_NAME="macolima-$p" \
      docker compose -f "$REPO_ROOT/docker-compose.yml" --profile db-all stop \
      || echo "[WARN] compose stop for '$p' had errors; continuing"
  done
  echo "[ OK ] All profiles stopped."
else
  echo "[INFO] No running profiles found."
fi

echo "[INFO] Stopping Colima VM ..."
colima stop
echo "[ OK ] Colima stopped. Memory reclaimed."
