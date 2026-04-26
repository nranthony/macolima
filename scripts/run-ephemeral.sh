#!/usr/bin/env bash
# =============================================================================
# run-ephemeral.sh — one-off hardened run for an existing profile, --rm on exit
# =============================================================================
# Usage:
#   scripts/run-ephemeral.sh <profile> [command...]
# Example:
#   scripts/run-ephemeral.sh nranthony
#   scripts/run-ephemeral.sh nranthony claude
#
# Attaches a disposable container to the per-profile sandbox-internal network
# so it can reach egress-proxy. Requires the compose stack for <profile> to
# already be up (`scripts/profile.sh <profile> up`) — this script does NOT
# start Squid; it borrows the one compose already started.
#
# Why this exists alongside `scripts/profile.sh exec`:
#   - profile.sh exec runs inside the *persistent* claude-agent-<profile>
#     container. Anything it writes to /tmp, .npm-global, .local persists
#     across invocations.
#   - run-ephemeral.sh spawns a fresh --rm container with the same hardening;
#     everything outside the bind mounts is discarded on exit. Useful for
#     one-shot "try this command in a clean shell" checks.
# =============================================================================
set -euo pipefail

DRIVE="/Volumes/DataDrive"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROFILE="${1:-}"
[[ -n "$PROFILE" ]] || { echo "Usage: $0 <profile> [command...]" >&2; exit 1; }
[[ "$PROFILE" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "profile name must match [a-zA-Z0-9_-]+" >&2; exit 1; }
shift

REPO_PATH="$DRIVE/repo/$PROFILE"
STATE="$DRIVE/.claude-colima/profiles/$PROFILE"
NETWORK="macolima-${PROFILE}_sandbox-internal"

[[ -d "$REPO_PATH" ]] || { echo "No such profile workspace: $REPO_PATH" >&2; exit 1; }
[[ -d "$STATE"     ]] || { echo "No profile state dir: $STATE
  Run: scripts/profile.sh $PROFILE up" >&2; exit 1; }
[[ -s "$STATE/claude.json" ]] || { echo "Missing $STATE/claude.json
  Run: scripts/profile.sh $PROFILE up" >&2; exit 1; }
docker network inspect "$NETWORK" >/dev/null 2>&1 \
  || { echo "Network $NETWORK missing — bring the stack up first:
  scripts/profile.sh $PROFILE up" >&2; exit 1; }

docker run --rm -it \
  --name "claude-ephemeral-${PROFILE}-$$" \
  --user agent \
  --tmpfs /tmp:size=1g,noexec,nosuid,nodev \
  --tmpfs /run:size=64m,noexec,nosuid,nodev \
  --tmpfs "/home/agent/.npm-global:size=512m,noexec,nosuid,nodev,uid=1000,gid=1000,mode=0755" \
  --tmpfs "/home/agent/.local:size=256m,noexec,nosuid,nodev,uid=1000,gid=1000,mode=0755" \
  --security-opt no-new-privileges:true \
  --security-opt "seccomp=$REPO/seccomp.json" \
  --cap-drop ALL \
  --pids-limit 512 \
  --memory 8g --memory-swap 8g \
  --cpus 4 \
  --network "$NETWORK" \
  -e HTTP_PROXY=http://egress-proxy:3128 \
  -e HTTPS_PROXY=http://egress-proxy:3128 \
  -e http_proxy=http://egress-proxy:3128 \
  -e https_proxy=http://egress-proxy:3128 \
  -e NO_PROXY=localhost,127.0.0.1,egress-proxy \
  -e GIT_CONFIG_GLOBAL=/home/agent/.config/git/config \
  -e MACOLIMA_PROFILE="$PROFILE" \
  -v "$REPO_PATH":/workspace:rw \
  -v "$STATE/claude-home":/home/agent/.claude:rw \
  -v "$STATE/claude.json":/home/agent/.claude.json:rw \
  -v "$STATE/cache":/home/agent/.cache:rw \
  -v "$STATE/config":/home/agent/.config:rw \
  -w /workspace \
  macolima:latest \
  "${@:-zsh}"
