#!/usr/bin/env bash
# =============================================================================
# dashboard.sh — launch the host-side control dashboard (Streamlit)
# =============================================================================
# Usage:
#   scripts/dashboard.sh [streamlit-args...]
#
# Host-side ops console. Talks to the Colima Docker daemon and this repo's
# config files; it is NOT run inside any sandbox container, and nothing in the
# agent's world can reach it. See dashboard/README.md for what it does.
#
# The dashboard resolves the Colima socket itself (dashboard/src/lib/
# docker_client.py) — docker.from_env() only reads $DOCKER_HOST and would
# otherwise fall back to /var/run/docker.sock, which does not exist on this Mac.
# So there is no DOCKER_HOST plumbing here on purpose.
#
# WHY THIS CDs INTO dashboard/ — it is not cosmetic. Streamlit reads its config
# from $PWD/.streamlit/config.toml, and dashboard/.streamlit/config.toml is what
# pins the bind address to 127.0.0.1. Launched from any other directory that
# file is not found, and Streamlit's default is to bind ALL interfaces — which
# would put an ops console that can edit the proxy allowlist and restart
# containers on the LAN. The config check below fails loudly rather than let
# that happen silently.
#
# The venv is used directly rather than `source .venv/bin/activate` (which is
# what windows-ai-sandbox's inline recipe does): .venv/bin/streamlit's shebang
# already points at the venv interpreter, so activation adds nothing here, and
# skipping it keeps this script's environment unmodified.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASH="$REPO_ROOT/dashboard"

info() { printf '\033[0;36m[INFO]\033[0m  %s\n' "$*"; }
die()  { printf '\033[0;31m[ERR]\033[0m   %s\n' "$*" >&2; exit 1; }

[ -d "$DASH" ] || die "no dashboard/ directory at $DASH"

# Loopback pin lives here and is read relative to the CWD — see the header.
[ -f "$DASH/.streamlit/config.toml" ] || \
  die "missing $DASH/.streamlit/config.toml — that file pins the bind address to
        127.0.0.1. Refusing to start rather than expose the ops console on all
        interfaces. Restore it from git before running the dashboard."

# The venv is committed to nothing — it is built per host by uv. A repo that was
# moved leaves the venv's absolute shebangs pointing at the old path, so check
# the interpreter, not just the wrapper.
if [ ! -x "$DASH/.venv/bin/streamlit" ] || [ ! -x "$DASH/.venv/bin/python" ]; then
  die "dashboard venv is missing or stale ($DASH/.venv).
        Build it (requires uv):
          cd dashboard && uv venv && uv pip install -e ."
fi

cd "$DASH"
info "http://127.0.0.1:8501   (Ctrl-C to stop)"
exec .venv/bin/streamlit run src/app.py "$@"
