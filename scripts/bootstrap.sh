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
info "Creating directory layout on $DRIVE ..."
mkdir -p "$DRIVE/.colima"
mkdir -p "$DRIVE/.claude-colima/claude-home"
mkdir -p "$DRIVE/.claude-colima/workspace-cache"
mkdir -p "$DRIVE/.claude-colima/vscode-server"
mkdir -p "$DRIVE/repo"
ok "Directories ready."

# --- homebrew ---------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  fail "Homebrew is not installed. Install from https://brew.sh/ and re-run."
  exit 1
fi

info "Installing tooling via Homebrew..."
brew install colima docker docker-compose docker-buildx

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

# --- zshrc snippet ----------------------------------------------------------
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

# --- seed claude settings ---------------------------------------------------
CLAUDE_SETTINGS="$DRIVE/.claude-colima/claude-home/settings.json"
if [[ ! -f "$CLAUDE_SETTINGS" ]]; then
  info "Seeding Claude settings.json ..."
  cp "$SCRIPT_DIR/config/claude-settings.json" "$CLAUDE_SETTINGS"
  ok "Installed: $CLAUDE_SETTINGS"
else
  ok "Claude settings.json already present."
fi

echo ""
ok "Bootstrap complete."
echo ""
echo "Next:"
echo "  1. source ~/.zshrc"
echo "  2. scripts/colima-up.sh        # first-time Colima start (with flags)"
echo "  3. scripts/auth.sh             # claude login (once)"
echo "  4. scripts/start.sh            # daily startup"
