#!/usr/bin/env bash
# =============================================================================
# start.sh — daily startup: ensure Colima + persistent container are running
# =============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Ensure Dockerfile digest is pinned (not a placeholder)
if grep -q "REPLACE_WITH_CURRENT_DIGEST" Dockerfile; then
  echo "[WARN] Dockerfile still has a placeholder digest."
  echo "       Pin it now by running:"
  echo "         docker pull ubuntu:24.04"
  echo "         DIGEST=\$(docker inspect --format='{{index .RepoDigests 0}}' ubuntu:24.04 | sed 's/.*@//')"
  echo "         sed -i '' \"s/REPLACE_WITH_CURRENT_DIGEST/\$DIGEST/\" Dockerfile"
  exit 1
fi

# Start Colima if not already running
if ! colima status >/dev/null 2>&1; then
  echo "[INFO] Starting Colima ..."
  colima start
fi

# Bring the stack up
echo "[INFO] Bringing up claude-agent + egress-proxy ..."
docker compose up -d --build

echo ""
echo "[ OK ] Stack running. Attach with: scripts/attach.sh"
