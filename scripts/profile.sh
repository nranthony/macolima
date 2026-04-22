#!/usr/bin/env bash
# =============================================================================
# profile.sh — multi-profile entry point for the macolima stack
# =============================================================================
# Usage:
#   scripts/profile.sh <profile> <command> [extra args...]
#
# Commands:
#   up              build (if needed) + start the stack for this profile
#   down            stop + remove containers (keeps persistent state)
#   attach          shell into the agent container (zsh as agent user)
#   auth            run `claude login` inside the container (one-time per profile)
#   auth-github     run `gh auth login` inside the container
#   auth-gitlab     run `glab auth login` inside the container
#   logs            tail container logs
#   status          docker compose ps for this profile
#   build           force-rebuild the image (shared across all profiles)
#   rebuild         build + recreate this profile's containers
#   list            list all existing profiles (by drive dir)
#   exec <cmd...>   run an arbitrary command inside the agent container
# =============================================================================
set -euo pipefail

DRIVE="/Volumes/DataDrive"
PROFILES_ROOT="$DRIVE/.claude-colima/profiles"
REPO_ROOT="$DRIVE/repo"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

info()  { printf '\033[0;36m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[0;32m[ OK ]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
fail()  { printf '\033[0;31m[FAIL]\033[0m  %s\n' "$*"; exit 1; }

usage() {
  sed -n '2,/^# =====/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

# --- arg parsing ------------------------------------------------------------
[[ $# -ge 1 ]] || usage

# `list` is the only command that doesn't need a profile arg
if [[ "$1" == "list" ]]; then
  if [[ ! -d "$PROFILES_ROOT" ]]; then
    echo "(no profiles yet — try: scripts/profile.sh <name> up)"
    exit 0
  fi
  echo "Profiles (under $PROFILES_ROOT):"
  for d in "$PROFILES_ROOT"/*/; do
    [[ -d "$d" ]] || continue
    name="$(basename "$d")"
    status="down"
    if docker ps --format '{{.Names}}' | grep -qx "claude-agent-$name"; then
      status="up"
    fi
    repo_dir="$REPO_ROOT/$name"
    [[ -d "$repo_dir" ]] || repo_dir="$repo_dir (MISSING)"
    printf '  %-20s %-6s %s\n' "$name" "$status" "$repo_dir"
  done
  exit 0
fi

[[ $# -ge 2 ]] || usage

PROFILE="$1"
CMD="$2"
shift 2

# validate profile name (filesystem safe)
if ! [[ "$PROFILE" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  fail "Profile name must match [a-zA-Z0-9_-]+ (got: $PROFILE)"
fi

# --- ensure persistent state dirs -------------------------------------------
ensure_state() {
  local p="$PROFILES_ROOT/$PROFILE"
  mkdir -p "$p/claude-home" "$p/cache" "$p/config"
  # Single-file bind mounts need the target to exist on host before first compose up.
  # Seed with '{}' — Claude rejects a 0-byte file as invalid JSON (Unexpected EOF).
  if [[ ! -s "$p/claude.json" ]]; then
    printf '{}\n' > "$p/claude.json"
    chmod 644 "$p/claude.json"
  fi
  mkdir -p "$p/config/git"
  # Seed a db.env.example so users know which keys to set if they opt into
  # the Postgres/Mongo sibling containers. We never write db.env itself —
  # user copies the example and fills in secrets.
  if [[ ! -f "$p/db.env.example" ]]; then
    cat > "$p/db.env.example" <<'EOF'
# Copy to db.env and fill in. Only needed if you run the postgres/mongo
# sibling containers (COMPOSE_PROFILES=db-postgres or db-mongo).
POSTGRES_USER=agent
POSTGRES_PASSWORD=change-me
POSTGRES_DB=dev
MONGO_INITDB_ROOT_USERNAME=agent
MONGO_INITDB_ROOT_PASSWORD=change-me
EOF
  fi
  # Seed settings.json if absent.
  if [[ ! -f "$p/claude-home/settings.json" ]] && [[ -f "$SCRIPT_DIR/config/claude-settings.json" ]]; then
    cp "$SCRIPT_DIR/config/claude-settings.json" "$p/claude-home/settings.json"
  fi
}

# --- ensure repo subfolder exists -------------------------------------------
ensure_repo_dir() {
  if [[ ! -d "$REPO_ROOT/$PROFILE" ]]; then
    fail "Repo dir does not exist: $REPO_ROOT/$PROFILE
      Create it first:  mkdir -p '$REPO_ROOT/$PROFILE'
      Or clone repos into it before bringing the stack up."
  fi
}

# --- compose wrapper --------------------------------------------------------
export PROFILE
export COMPOSE_PROJECT_NAME="macolima-$PROFILE"
cd "$SCRIPT_DIR"

AGENT="claude-agent-$PROFILE"

# --- dispatch ---------------------------------------------------------------
case "$CMD" in
  up)
    ensure_repo_dir
    ensure_state
    info "Bringing up profile '$PROFILE' (project: $COMPOSE_PROJECT_NAME)"
    docker compose up -d "$@"
    ok "Stack up. Attach with:  scripts/profile.sh $PROFILE attach"
    ;;

  down)
    info "Taking down profile '$PROFILE'"
    docker compose down "$@"
    ok "Stack down. Persistent state preserved under $PROFILES_ROOT/$PROFILE/"
    ;;

  attach)
    info "Attaching to $AGENT (Ctrl-D to exit)"
    exec docker exec -it "$AGENT" zsh
    ;;

  auth)
    info "Running 'claude login' inside $AGENT"
    info "You'll be given a URL; open it on the host to complete OAuth."
    exec docker exec -it "$AGENT" claude login
    ;;

  auth-github)
    info "Running 'gh auth login' inside $AGENT"
    exec docker exec -it "$AGENT" gh auth login
    ;;

  auth-gitlab)
    info "Running 'glab auth login' inside $AGENT"
    exec docker exec -it "$AGENT" glab auth login
    ;;

  logs)
    exec docker compose logs -f "$@"
    ;;

  status|ps)
    exec docker compose ps "$@"
    ;;

  build)
    info "Building macolima:latest (shared image across all profiles)"
    exec docker compose build claude-agent "$@"
    ;;

  rebuild)
    ensure_repo_dir
    ensure_state
    info "Rebuilding image + recreating profile '$PROFILE'"
    docker compose build claude-agent
    docker compose up -d --force-recreate
    ;;

  exec)
    [[ $# -ge 1 ]] || fail "Usage: scripts/profile.sh $PROFILE exec <cmd> [args...]"
    exec docker exec -it "$AGENT" "$@"
    ;;

  *)
    usage
    ;;
esac
