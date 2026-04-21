#!/usr/bin/env bash
# =============================================================================
# run-ephemeral.sh — one-off hardened run, container destroyed on exit
# =============================================================================
# Usage:
#   scripts/run-ephemeral.sh <repo-subpath> [command...]
# Example:
#   scripts/run-ephemeral.sh nranthony/myproject
#   scripts/run-ephemeral.sh nranthony/myproject claude
#
# Applies the same hardening as docker-compose.yml but uses `docker run --rm`
# so nothing persists in the container after exit.
# =============================================================================
set -euo pipefail

DRIVE="/Volumes/DataDrive"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REPO_SUBPATH="${1:-}"
[[ -n "$REPO_SUBPATH" ]] || { echo "Usage: $0 <repo-subpath> [command...]"; exit 1; }
shift || true

REPO_PATH="$DRIVE/repo/$REPO_SUBPATH"
[[ -d "$REPO_PATH" ]] || { echo "No such repo: $REPO_PATH"; exit 1; }

docker run --rm -it \
  --name "claude-ephemeral-$$" \
  --read-only \
  --tmpfs /tmp:size=1g,noexec,nosuid,nodev \
  --tmpfs /run:size=64m,noexec,nosuid,nodev \
  --tmpfs /home/agent/.npm-global:size=512m,nosuid,nodev \
  --tmpfs /home/agent/.local:size=256m,nosuid,nodev \
  --security-opt no-new-privileges:true \
  --security-opt "seccomp=$SCRIPT_DIR/seccomp.json" \
  --cap-drop ALL \
  --pids-limit 512 \
  --memory 8g --memory-swap 8g \
  --cpus 4 \
  --network macolima_sandbox-internal \
  -e HTTP_PROXY=http://egress-proxy:3128 \
  -e HTTPS_PROXY=http://egress-proxy:3128 \
  -v "$REPO_PATH":/workspace:rw \
  -v "$DRIVE/.claude-colima/claude-home":/home/agent/.claude:rw \
  -v "$DRIVE/.claude-colima/workspace-cache":/home/agent/.cache:rw \
  -w /workspace \
  macolima:latest \
  "${@:-bash}"
