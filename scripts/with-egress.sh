#!/usr/bin/env bash
# =============================================================================
# with-egress.sh — temporarily widen the egress proxy allowlist for one command
# =============================================================================
# Usage:
#   scripts/with-egress.sh <profile> [--with pypi[,npm,git]] -- <cmd>
#
# Default --with: pypi
# Section tags match `[<tag>]` in proxy/allowed_domains.txt — typical
# planning-mode tags: pypi, npm, git. <cmd> runs inside the profile's agent
# container as `bash -lc <cmd>`.
#
# The allowlist file is backed up before opening and *restored verbatim* on
# exit (success, failure, Ctrl-C). Squid is restarted on both transitions.
# This is the scripted version of the "uncomment / restart squid / install /
# re-comment / restart squid" loop documented in CLAUDE.md.
#
# Examples:
#   scripts/with-egress.sh therapod -- \
#     'cd /workspace/pipeline && uv pip install -e ".[dev]" --python .venv-linux/bin/python'
#
#   scripts/with-egress.sh therapod --with pypi,npm -- \
#     'cd /workspace/foo && npm install && uv pip install -e ".[bar]" --python .venv-linux/bin/python'
#
#   scripts/with-egress.sh therapod --with git -- \
#     'cd /workspace/pipeline && git fetch origin'
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOWLIST="$REPO_ROOT/proxy/allowed_domains.txt"
COMPOSE_FILE="$REPO_ROOT/docker-compose.yml"

profile=""
sections="pypi"
cmd=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with)
      sections="${2:?--with requires a value}"
      shift 2
      ;;
    --)
      shift
      cmd=("$@")
      break
      ;;
    -h|--help)
      sed -n '2,28p' "$0"
      exit 0
      ;;
    -*)
      echo "Unknown flag: $1" >&2
      exit 2
      ;;
    *)
      if [[ -z "$profile" ]]; then
        profile="$1"
        shift
      else
        echo "Unexpected positional arg: $1 (did you forget the -- before the command?)" >&2
        exit 2
      fi
      ;;
  esac
done

[[ -n "$profile" ]] || { echo "Missing <profile>. Usage: scripts/with-egress.sh <profile> [--with list] -- <cmd>" >&2; exit 2; }
[[ ${#cmd[@]} -gt 0 ]] || { echo "Missing -- <cmd>. Usage: scripts/with-egress.sh <profile> [--with list] -- <cmd>" >&2; exit 2; }

IFS=',' read -ra SECTIONS <<< "$sections"

# Validate every requested section exists somewhere in the file (commented or not).
# Header forms vary: `# --- ... [tag] ---` (always-listed sections) or
# `# # --- ... [tag] ---` (planning-mode sections double-commented). Anchor
# on the trailing `[tag] ---` which is unique to section headers.
for s in "${SECTIONS[@]}"; do
  if ! grep -qE -e "--- .* \[$s\] ---" "$ALLOWLIST"; then
    {
      echo "No section [$s] in $ALLOWLIST. Known section tags:"
      grep -oE -e '--- .* \[[a-z-]+\] ---' "$ALLOWLIST" | grep -oE -e '\[[a-z-]+\]' | sort -u
    } >&2
    exit 2
  fi
done

restart_proxy() {
  PROFILE="$profile" COMPOSE_PROJECT_NAME="macolima-$profile" \
    docker compose -f "$COMPOSE_FILE" restart egress-proxy >/dev/null
}

# Section bounds: header line until the next section header or a blank line.
# Header gets normalized from `# # ---` to `# ---` (a no-op for already-`# ---`
# headers); domain lines starting with `# ` get one `# ` stripped.
open_section() {
  local sec="$1"
  awk -v sec="$sec" '
    BEGIN { inside = 0 }
    /--- .* \[[a-z-]+\] ---/ {
      if (match($0, /\[[a-z-]+\]/)) {
        tag = substr($0, RSTART+1, RLENGTH-2)
        if (tag == sec) {
          inside = 1
          sub(/^# # /, "# ")
          print
          next
        } else if (inside) {
          inside = 0
        }
      }
    }
    /^[[:space:]]*$/ { if (inside) inside = 0; print; next }
    inside && /^# / { sub(/^# /, ""); print; next }
    { print }
  ' "$ALLOWLIST" > "$ALLOWLIST.tmp" && mv "$ALLOWLIST.tmp" "$ALLOWLIST"
}

backup="$(mktemp -t with-egress.XXXXXX)"
cp "$ALLOWLIST" "$backup"

cleanup() {
  local rc=$?
  echo "→ restoring allowlist + restarting proxy" >&2
  cp "$backup" "$ALLOWLIST"
  rm -f "$backup"
  restart_proxy || echo "WARN: proxy restart on cleanup failed" >&2
  exit "$rc"
}
trap cleanup EXIT INT TERM

echo "→ opening egress sections: ${SECTIONS[*]}" >&2
for s in "${SECTIONS[@]}"; do open_section "$s"; done
restart_proxy

echo "→ exec claude-agent-$profile: ${cmd[*]}" >&2
docker exec "claude-agent-$profile" bash -lc "${cmd[*]}"
