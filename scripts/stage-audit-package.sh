#!/usr/bin/env bash
# =============================================================================
# stage-audit-package.sh — copy sandbox config into a profile's workspace
# =============================================================================
# Usage: scripts/stage-audit-package.sh <profile> [--clean]
#
# Copies the files referenced by claude_internal_audit.md into
#   /Volumes/DataDrive/repo/<profile>/temp_audit_package/
# which appears inside the agent container as /workspace/temp_audit_package/.
#
#   --clean   remove temp_audit_package/ instead of staging
# =============================================================================
set -euo pipefail

REPO_ROOT="/Volumes/DataDrive/repo"
MACOLIMA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[[ $# -ge 1 ]] || { echo "usage: $0 <profile> [--clean]" >&2; exit 1; }
profile="$1"
action="${2:-stage}"

target_workspace="$REPO_ROOT/$profile"
[[ -d "$target_workspace" ]] || { echo "no such profile workspace: $target_workspace" >&2; exit 1; }

dest="$target_workspace/temp_audit_package"

if [[ "$action" == "--clean" ]]; then
  rm -rf "$dest"
  echo "removed $dest"
  exit 0
fi

rm -rf "$dest"
mkdir -p "$dest/proxy" "$dest/scripts" "$dest/scripts/config"

cp "$MACOLIMA_DIR/CLAUDE.md"                       "$dest/CLAUDE.md"
cp "$MACOLIMA_DIR/Dockerfile"                      "$dest/Dockerfile"
cp "$MACOLIMA_DIR/docker-compose.yml"              "$dest/docker-compose.yml"
cp "$MACOLIMA_DIR/seccomp.json"                    "$dest/seccomp.json"
cp "$MACOLIMA_DIR/proxy/allowed_domains.txt"       "$dest/proxy/allowed_domains.txt"
cp "$MACOLIMA_DIR/proxy/squid.conf"                "$dest/proxy/squid.conf"
cp "$MACOLIMA_DIR/scripts/verify-sandbox.sh"       "$dest/scripts/verify-sandbox.sh"
cp "$MACOLIMA_DIR/scripts/setup.sh"                "$dest/scripts/setup.sh"
cp "$MACOLIMA_DIR/scripts/profile.sh"              "$dest/scripts/profile.sh"
cp "$MACOLIMA_DIR/scripts/config/claude-settings.json" "$dest/scripts/config/claude-settings.json"
cp "$MACOLIMA_DIR/claude_internal_audit.md"        "$dest/claude_internal_audit.md"

chmod -R a-w "$dest"
chmod u+w "$dest" "$dest/proxy" "$dest/scripts"

echo "staged audit package at:"
echo "  host:      $dest"
echo "  container: /workspace/temp_audit_package/"
echo
echo "next: attach to claude-agent-$profile and run"
echo "  bash /workspace/temp_audit_package/scripts/verify-sandbox.sh"
