#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — one-time host setup for macolima on macOS
# =============================================================================
# Safe to re-run. Verifies environment, installs tooling via Homebrew,
# creates directories on /Volumes/DataDrive, and appends env vars to ~/.zshrc.
# =============================================================================
set -euo pipefail

DRIVE="/Volumes/DataDrive"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

info()  { printf '\033[0;36m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[0;32m[ OK ]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
fail()  { printf '\033[0;31m[FAIL]\033[0m  %s\n' "$*"; }

# --- verify drive -----------------------------------------------------------
[[ -d "$DRIVE" ]] || { fail "$DRIVE not mounted"; exit 1; }
ok "Drive mounted: $DRIVE"

# --- directory layout -------------------------------------------------------
# Per-profile state (claude-home, config/, db.env, etc.) is created on demand
# by profile.sh's ensure_state() under .claude-colima/profiles/<name>/. Only
# the parents need to exist up front.
info "Creating directory layout on $DRIVE ..."
mkdir -p "$DRIVE/.colima"
mkdir -p "$DRIVE/.claude-colima/profiles"
mkdir -p "$DRIVE/repo"
ok "Directories ready."

# --- homebrew ---------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  fail "Homebrew is not installed. Install from https://brew.sh/ and re-run."
  exit 1
fi

info "Installing tooling via Homebrew..."
# flock: not in the macOS base system (it's Linux util-linux). scripts/with-egress.sh
# uses it to serialize per-profile egress widening — without it that script aborts
# at lock-acquire with "flock: command not found".
brew install colima docker docker-compose docker-buildx flock

# --- Docker Desktop conflict check -----------------------------------------
if [[ -d "/Applications/Docker.app" ]]; then
  warn "Docker Desktop is installed and will conflict with Colima."
  warn "Consider: brew uninstall --cask docker-desktop"
fi

# --- Rosetta (Apple Silicon) ------------------------------------------------
if [[ "$(uname -m)" == "arm64" ]] && ! /usr/bin/pgrep -q oahd; then
  info "Installing Rosetta (needed for --vz-rosetta)..."
  softwareupdate --install-rosetta --agree-to-license
fi

# --- zshrc: homebrew shellenv ----------------------------------------------
# Without /opt/homebrew/bin on PATH, `docker`, `colima`, `gh`, etc. fail with
# `command not found` in fresh shells — even though brew installed them. The
# brew installer prints a "Next steps" snippet that adds this; some users miss
# it. Idempotent: only append if no existing line references /opt/homebrew/bin.
BREW_MARKER="# >>> homebrew shellenv >>>"
if ! grep -qE 'brew shellenv|/opt/homebrew/bin' "$HOME/.zshrc" 2>/dev/null; then
  info "Appending Homebrew shellenv to ~/.zshrc (puts docker/colima on PATH)..."
  {
    echo ""
    echo "$BREW_MARKER"
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"'
    echo "# <<< homebrew shellenv <<<"
  } >> "$HOME/.zshrc"
  ok "Added Homebrew shellenv. Run: source ~/.zshrc"
else
  ok "Homebrew is already on \$PATH in ~/.zshrc."
fi

# --- zshrc: macolima env ----------------------------------------------------
SNIPPET_MARKER="# >>> macolima env >>>"
if ! grep -q "$SNIPPET_MARKER" "$HOME/.zshrc" 2>/dev/null; then
  info "Appending Colima env vars to ~/.zshrc ..."
  {
    echo ""
    echo "$SNIPPET_MARKER"
    cat "$SCRIPT_DIR/config/zshrc-snippet.sh"
    echo "# <<< macolima env <<<"
  } >> "$HOME/.zshrc"
  ok "Added. Run: source ~/.zshrc"
else
  ok "~/.zshrc already configured."
fi

echo ""
ok "Bootstrap complete."
echo ""
echo "Next:"
echo "  1. source ~/.zshrc"
echo "  2. scripts/colima-up.sh                                       # first-time Colima start (with flags)"
echo "  3. PROFILE=_build docker compose build claude-agent           # build the shared image"
echo "  4. mkdir -p $DRIVE/repo/<profile>                             # workspace must exist before setup"
echo "  5. scripts/setup.sh <profile> --name \"...\" --email \"...\"     # onboard (up + auth + git identity)"
echo "  6. scripts/profile.sh <profile> attach                        # zsh inside the container"
