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
#   reset-settings  overwrite this profile's claude settings.json from config/claude-settings.json (backs up the old one)
#   reset-skills    overwrite this profile's claude skills from config/skills/ (backs up old skill dirs)
#   clean           prune rotating state (old .claude.json backups, paste-cache, shell-snapshots).
#                   Pass --deep to also drop MCP debug logs + settings.json.bak.* backups.
#   wipe            blank-slate this profile: down -v, nuke per-profile state, KEEP auth
#                   (claude creds, claude.json, gh, glab, git identity). Confirms first.
#                   Flags: --dry-run (show only), --yes (skip prompt), --all-volumes (also drop DB volumes)
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
  # `cache/` is intentionally not pre-created on host — `/home/agent/.cache` is
  # backed by a named Docker volume (`macolima-<p>_cache`), not a bind mount,
  # to avoid virtiofs chmod issues during wheel extraction (lxml etc.).
  mkdir -p "$p/claude-home" "$p/config"
  # Single-file bind mounts need the target to exist on host before first compose up.
  # Seed with '{}' — Claude rejects a 0-byte file as invalid JSON (Unexpected EOF).
  if [[ ! -s "$p/claude.json" ]]; then
    printf '{}\n' > "$p/claude.json"
    chmod 644 "$p/claude.json"
  fi
  mkdir -p "$p/config/git"
  # Seed a db.env.example so users know which keys to set if they opt into
  # the Postgres/Mongo sibling containers. We never write db.env itself —
  # user copies the example and fills in secrets. The example is a *template*
  # (not user data), so always overwrite — that way doc improvements to the
  # template propagate to existing profiles on the next `up`.
  cat > "$p/db.env.example" <<'EOF'
# Copy this file to `db.env` (same directory) and replace every __SET_ME__.
# Only needed if you opt into the postgres / mongo sibling containers via
# COMPOSE_PROFILES=db-postgres or db-mongo when running `scripts/profile.sh up`.
#
# IMPORTANT — first-init lock-in:
#   POSTGRES_USER / POSTGRES_PASSWORD / POSTGRES_DB are only read on the *first*
#   boot of the postgres container, when initdb runs against an empty data
#   volume. Editing them later does NOT change the role inside the DB.
#   To change credentials afterwards either:
#     (a) connect as the existing role and `ALTER USER agent WITH PASSWORD '...';`
#     (b) wipe the volume and re-init:
#           docker stop postgres-<profile>
#           docker volume rm macolima-<profile>_postgres-data
#           COMPOSE_PROFILES=db-postgres scripts/profile.sh <profile> up

# --- Postgres ----------------------------------------------------------------
POSTGRES_USER=agent
POSTGRES_PASSWORD=__SET_ME__
POSTGRES_DB=dev

# Optional: project-specific DSN read inside the agent container by code that
# expects this env var (e.g. `WEARDATA_PG_DSN` for wearable_data_testing,
# `DATABASE_URL` for many frameworks). Pick the name your project uses.
#
# The DSN's password component must match POSTGRES_PASSWORD above. If your
# password contains URL-reserved chars, percent-encode them in the DSN:
#     /  ->  %2F     @  ->  %40     :  ->  %3A     #  ->  %23     ?  ->  %3F
# Safer: generate a password with no special chars:
#     openssl rand -hex 24        # 48 hex chars, all URL-safe
#
# Hostname inside the sandbox is `postgres` (the compose service name on
# sandbox-internal), NOT localhost.
#
# DATABASE_URL=postgresql://agent:__SET_ME__@postgres:5432/dev

# --- Mongo (optional) --------------------------------------------------------
MONGO_INITDB_ROOT_USERNAME=agent
MONGO_INITDB_ROOT_PASSWORD=__SET_ME__
EOF
  # Seed settings.json if absent.
  if [[ ! -f "$p/claude-home/settings.json" ]] && [[ -f "$SCRIPT_DIR/config/claude-settings.json" ]]; then
    cp "$SCRIPT_DIR/config/claude-settings.json" "$p/claude-home/settings.json"
  fi
  # Seed skills (per-skill granularity so user customisations to one skill
  # don't block updates to another). Templates live at config/skills/<name>/;
  # each is copied into the per-profile claude-home only if absent. To force
  # a refresh from template, run `scripts/profile.sh <p> reset-skills`.
  if [[ -d "$SCRIPT_DIR/config/skills" ]]; then
    mkdir -p "$p/claude-home/skills"
    for skill_src in "$SCRIPT_DIR/config/skills"/*/; do
      [[ -d "$skill_src" ]] || continue
      name="$(basename "$skill_src")"
      if [[ ! -d "$p/claude-home/skills/$name" ]]; then
        cp -R "$skill_src" "$p/claude-home/skills/$name"
      fi
    done
  fi
  # Defensive scrub: VS Code Dev Containers can inject a host-routed git
  # credential helper into .config/git/config (via VSCODE_GIT_IPC_HANDLE +
  # a node shim in .vscode-server), and macOS's copyGitConfig can leak
  # osxkeychain / git-credential-manager helpers. Both forward git auth to
  # the host, bypassing the sandbox's network identity. Strip those on every
  # `up` — but leave benign in-container helpers alone (glab and gh's own
  # credential shims, which use in-container tokens from ~/.config/<tool>/).
  if [[ -f "$p/config/git/config" ]] && \
     grep -qE 'helper\s*=.*(vscode-server|vscode-remote-containers|osxkeychain|git-credential-manager)' \
       "$p/config/git/config"; then
    # Rewrite file dropping only the offending helper lines; keep everything
    # else (sections, user identity, other helpers) intact.
    awk '
      /^[[:space:]]*helper[[:space:]]*=.*(vscode-server|vscode-remote-containers|osxkeychain|git-credential-manager)/ { next }
      { print }
    ' "$p/config/git/config" > "$p/config/git/config.scrubbed" \
      && mv "$p/config/git/config.scrubbed" "$p/config/git/config"
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

  clean)
    # Remove rotating state that Claude/npm/zsh regenerate on demand. Safe by default.
    # Pass --deep to also drop MCP debug logs and our own settings.json.bak.* backups.
    # Never touches: .credentials.json, live settings.json, live claude.json, file-history,
    # projects/, plugins/, gitstatusd binary.
    deep=0
    for a in "$@"; do [[ "$a" == "--deep" ]] && deep=1; done
    p="$PROFILES_ROOT/$PROFILE"
    [[ -d "$p" ]] || fail "no state dir: $p"

    info "cleaning $p (deep=$deep)"

    # Claude Code's own rotating .claude.json backups — keep the single newest.
    bdir="$p/claude-home/backups"
    if [[ -d "$bdir" ]]; then
      # shellcheck disable=SC2012
      ls -t "$bdir"/.claude.json.backup.* 2>/dev/null | tail -n +2 | xargs -r rm -f
      rm -f "$bdir"/.claude.json.corrupted.* 2>/dev/null || true
      ok "pruned $bdir (kept newest .claude.json.backup)"
    fi

    # Paste cache and shell snapshots — regenerated per session.
    rm -rf "$p/claude-home/paste-cache" "$p/claude-home/shell-snapshots" 2>/dev/null || true
    mkdir -p "$p/claude-home/paste-cache" "$p/claude-home/shell-snapshots"
    ok "reset paste-cache + shell-snapshots"

    if [[ "$deep" == "1" ]]; then
      # MCP/CLI debug logs — only useful when actively debugging connection issues.
      # Live in the `cache` named volume (not host-visible). Reach in via the
      # running container if it's up; otherwise this is a no-op.
      if docker ps --format '{{.Names}}' | grep -qx "$AGENT"; then
        docker exec "$AGENT" \
          find /home/agent/.cache/claude-cli-nodejs -type f -name '*.jsonl' -delete 2>/dev/null || true
        ok "dropped MCP debug logs under .cache/claude-cli-nodejs (in container)"
      else
        info "skipping MCP debug log cleanup ('$AGENT' not running; logs live in named volume)"
      fi
      # Our own reset-settings backups.
      find "$p/claude-home" -maxdepth 1 -name 'settings.json.bak.*' -delete 2>/dev/null || true
      ok "dropped settings.json.bak.* backups"
      # Our own reset-skills backups (sibling dirs to live skill dirs).
      find "$p/claude-home/skills" -maxdepth 1 -type d -name '*.bak.*' \
        -exec rm -rf {} + 2>/dev/null || true
      ok "dropped skills/*.bak.* backups"
    else
      info "skip --deep targets (MCP logs, settings.json.bak.*) — pass --deep to include"
    fi

    ok "clean done for '$PROFILE'"
    ;;

  reset-settings)
    # Overwrite the profile's claude settings.json from config/claude-settings.json.
    # ensure_state() only seeds when absent; use this when the template changes and
    # you want to apply it to an existing profile.
    src="$SCRIPT_DIR/config/claude-settings.json"
    dst="$PROFILES_ROOT/$PROFILE/claude-home/settings.json"
    [[ -f "$src" ]] || fail "template missing: $src"
    mkdir -p "$(dirname "$dst")"
    if [[ -f "$dst" ]]; then
      backup="$dst.bak.$(date +%Y%m%d-%H%M%S)"
      cp "$dst" "$backup"
      info "backed up existing settings → $backup"
    fi
    cp "$src" "$dst"
    ok "settings.json reset for '$PROFILE'. Restart claude inside the container to pick up."
    ;;

  wipe)
    # Blank-slate this profile while preserving auth tokens + git identity.
    # Use case: testing the stack from a clean state without re-doing OAuth.
    # Preserves: claude-home/.credentials.json, claude.json, config/gh/,
    #            config/glab-cli/, config/git/.
    # Wipes:     containers, vscode-server + cache named volumes, everything
    #            else under profiles/<p>/ (settings, skills, sessions, projects,
    #            paste-cache, shell-snapshots, audits, ...).
    # Does NOT touch: shared image (use `build` to rebuild), DB volumes
    #            (postgres-data, mongo-data) unless --all-volumes is passed.
    dry=0; assume_yes=0; all_vols=0
    for a in "$@"; do
      case "$a" in
        --dry-run)     dry=1 ;;
        --yes|-y)      assume_yes=1 ;;
        --all-volumes) all_vols=1 ;;
        *) fail "wipe: unknown flag '$a' (valid: --dry-run --yes --all-volumes)" ;;
      esac
    done

    p="$PROFILES_ROOT/$PROFILE"
    [[ -d "$p" ]] || fail "no state dir to wipe: $p"

    # Itemise what will survive vs disappear, so the user sees it before confirming.
    info "wipe plan for profile '$PROFILE' (project: $COMPOSE_PROJECT_NAME)"
    echo "  PRESERVE:"
    echo "    $p/claude.json"
    echo "    $p/claude-home/.credentials.json"
    echo "    $p/config/gh/"
    echo "    $p/config/glab-cli/"
    echo "    $p/config/git/"
    echo "  WIPE:"
    echo "    docker compose down --remove-orphans  ($([[ $all_vols == 1 ]] && echo '+ ALL named volumes' || echo '+ vscode-server + cache volumes; DB volumes preserved'))"
    echo "    rm -rf $p/*  (everything except the PRESERVE list above)"
    echo "  AFTER:"
    echo "    re-seed claude settings.json + skills from config/ (via ensure_state)"
    echo "    next step: scripts/profile.sh $PROFILE up   (or 'rebuild' if image changed)"

    if [[ "$dry" == "1" ]]; then
      ok "dry-run; no changes made"
      exit 0
    fi

    if [[ "$assume_yes" != "1" ]]; then
      printf '\nProceed? type the profile name (%s) to confirm: ' "$PROFILE"
      read -r confirm
      [[ "$confirm" == "$PROFILE" ]] || fail "confirmation mismatch; aborting"
    fi

    # 1. Tear down containers (+ networks). Only nuke named volumes if asked.
    info "tearing down containers"
    if [[ "$all_vols" == "1" ]]; then
      docker compose down -v --remove-orphans || warn "compose down had errors; continuing"
    else
      docker compose down --remove-orphans || warn "compose down had errors; continuing"
      # Drop the throwaway named volumes (vscode-server, cache); leave DB volumes alone.
      for v in vscode-server cache; do
        docker volume rm "${COMPOSE_PROJECT_NAME}_${v}" 2>/dev/null \
          && ok "removed volume ${COMPOSE_PROJECT_NAME}_${v}" \
          || info "no ${v} volume to remove (or already gone)"
      done
    fi

    # 2. Stage auth on the same filesystem so the move is a rename, not a copy.
    stage="$PROFILES_ROOT/.wipe-stage-$PROFILE-$(date +%s)"
    mkdir -p "$stage/claude-home" "$stage/config"
    [[ -f "$p/claude.json" ]]                && mv "$p/claude.json"                "$stage/claude.json"
    [[ -f "$p/claude-home/.credentials.json" ]] && mv "$p/claude-home/.credentials.json" "$stage/claude-home/.credentials.json"
    [[ -d "$p/config/gh" ]]                  && mv "$p/config/gh"                  "$stage/config/gh"
    [[ -d "$p/config/glab-cli" ]]            && mv "$p/config/glab-cli"            "$stage/config/glab-cli"
    [[ -d "$p/config/git" ]]                 && mv "$p/config/git"                 "$stage/config/git"
    ok "staged auth artefacts → $stage"

    # 3. Nuke the profile dir.
    rm -rf "$p"
    ok "removed $p"

    # 4. Restore auth into a fresh profile dir.
    mkdir -p "$p/claude-home" "$p/config"
    [[ -f "$stage/claude.json" ]]                && mv "$stage/claude.json"                "$p/claude.json"
    [[ -f "$stage/claude-home/.credentials.json" ]] && mv "$stage/claude-home/.credentials.json" "$p/claude-home/.credentials.json"
    [[ -d "$stage/config/gh" ]]                  && mv "$stage/config/gh"                  "$p/config/gh"
    [[ -d "$stage/config/glab-cli" ]]            && mv "$stage/config/glab-cli"            "$p/config/glab-cli"
    [[ -d "$stage/config/git" ]]                 && mv "$stage/config/git"                 "$p/config/git"
    rmdir "$stage/claude-home" "$stage/config" "$stage" 2>/dev/null || warn "stage dir not empty: $stage (inspect manually)"

    # 5. Restore the sensitive perms documented in CLAUDE.md.
    #    .credentials.json must be 600 (inside a directory bind-mount, UID remap works).
    #    claude.json must be 644 (single-file bind-mount needs world-readable so agent UID 1000 sees it).
    [[ -f "$p/claude-home/.credentials.json" ]] && chmod 600 "$p/claude-home/.credentials.json"
    [[ -f "$p/claude.json" ]]                   && chmod 644 "$p/claude.json"
    ok "restored auth artefacts into fresh $p"

    # 6. Re-seed templates (settings.json, skills, db.env.example) so a plain `up` works.
    ensure_state
    ok "re-seeded settings + skills from config/"

    ok "wipe done for '$PROFILE'. Next: scripts/profile.sh $PROFILE up"
    ;;

  reset-skills)
    # Force-refresh per-profile skills from config/skills/. Each skill dir is
    # backed up (if present) then replaced. Use this when a SKILL.md template
    # changes and you want to apply it to an existing profile (ensure_state
    # only seeds when absent).
    src_dir="$SCRIPT_DIR/config/skills"
    dst_dir="$PROFILES_ROOT/$PROFILE/claude-home/skills"
    [[ -d "$src_dir" ]] || fail "no skills templates: $src_dir"
    mkdir -p "$dst_dir"
    stamp="$(date +%Y%m%d-%H%M%S)"
    for skill_src in "$src_dir"/*/; do
      [[ -d "$skill_src" ]] || continue
      name="$(basename "$skill_src")"
      if [[ -d "$dst_dir/$name" ]]; then
        backup="$dst_dir/$name.bak.$stamp"
        mv "$dst_dir/$name" "$backup"
        info "backed up existing skill → $backup"
      fi
      cp -R "$skill_src" "$dst_dir/$name"
      ok "skill '$name' reset for '$PROFILE'"
    done
    ok "all skills reset. Restart claude inside the container to pick up."
    ;;

  *)
    usage
    ;;
esac
