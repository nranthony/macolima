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
#   recreate        force-recreate this profile's containers (no image rebuild — picks up
#                   compose / seccomp / proxy / mount changes). Equivalent to
#                   `setup.sh <p> --recreate` (which is the flag-style alias).
#   rebuild         build + recreate this profile's containers
#   reset-settings  overwrite this profile's claude settings.json from config/claude-settings.json (backs up the old one)
#   reset-skills    overwrite this profile's claude skills from config/skills/ (backs up old skill dirs)
#   db-reset        wipe the postgres data volume and bring postgres back up with a fresh initdb.
#                   Flags: --yes (skip confirmation). Does NOT touch mongo; does NOT recreate
#                   the agent container (force-recreate it yourself if db.env DSNs changed).
#   clean           prune rotating state (old .claude.json backups, paste-cache, shell-snapshots).
#                   Pass --deep to also drop MCP debug logs + settings.json.bak.* backups.
#   wipe            blank-slate this profile: down -v, nuke per-profile state, KEEP auth
#                   (claude creds, claude.json, gh, glab, git identity). Confirms first.
#                   Flags: --dry-run (show only), --yes (skip prompt), --all-volumes (also drop DB volumes)
#   list            list all existing profiles (by drive dir)
#   exec <cmd...>   run an arbitrary command inside the agent container
#
# Optional flags (accepted by up / recreate / rebuild):
#   --expose-dev    layer docker-compose.<profile>.yml on top of the base
#                   compose file. Used to opt into LAN port publishing for an
#                   iPad / browser to reach a dev server inside the container.
#                   The override file must already exist at the repo root.
#                   UNSAFE: drops the `internal: true` network isolation for
#                   the duration. Re-run `up` without this flag to undo.
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
  # Mirror setup.sh's awk-based extractor: skip the shebang + title rule
  # (NR<3), print every comment line until the first non-comment line, with
  # the leading "# " stripped. The previous sed range stopped at the FIRST
  # `# =====` after line 2 — which is line 4 (the closing rule of the title
  # block), so users only ever saw the title and never the command list.
  awk 'NR<3{next} /^[^#]/{exit} {sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"
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
  # `gemini-home/` mirrors `claude-home/` for the Gemini CLI's per-profile state
  # (oauth_creds.json on first `gemini` run, settings.json, MCP config).
  mkdir -p "$p/claude-home" "$p/config" "$p/gemini-home"
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
  cp "$SCRIPT_DIR/config/db.env.template" "$p/db.env.example"
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

  # Seed commit identity into config/git/config if absent. The agent's deny
  # list blocks `git config` (the matcher can't distinguish benign user.* from
  # dangerous credential.* subcommands), so without this seeding the agent has
  # to fall back to per-commit GIT_AUTHOR_*/GIT_COMMITTER_* env vars on every
  # commit. Read identity from GIT_USER_NAME / GIT_USER_EMAIL in the calling
  # shell — set those in your shell rc (~/.zshrc.local etc) and they apply to
  # every profile. Silent no-op if either var is unset or a [user] section
  # already exists; never overwrites an existing identity.
  if [[ -n "${GIT_USER_NAME:-}" ]] && [[ -n "${GIT_USER_EMAIL:-}" ]]; then
    if [[ ! -f "$p/config/git/config" ]] || \
       ! grep -qE '^\[user\]' "$p/config/git/config"; then
      {
        printf '[user]\n\tname = %s\n\temail = %s\n' \
          "$GIT_USER_NAME" "$GIT_USER_EMAIL"
        [[ -f "$p/config/git/config" ]] && cat "$p/config/git/config"
      } > "$p/config/git/config.new" \
        && mv "$p/config/git/config.new" "$p/config/git/config"
    fi
  fi

  # db.env contains the DB superuser password (and any project-specific DSNs
  # that embed it). README documents `chmod 600` after the user fills in the
  # template, but neither setup.sh nor the user reliably did it (audit L1
  # found 644 in the wild). Enforce idempotently here: every `up` re-asserts
  # 600. Doesn't touch db.env.example (still seeded as 644 — it's a template,
  # not a secret).
  if [[ -f "$p/db.env" ]]; then
    chmod 600 "$p/db.env" 2>/dev/null || warn "could not chmod 600 $p/db.env"
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

# --- optional flag parser ---------------------------------------------------
# Strip --expose-dev from "$@" and populate COMPOSE_FILE_ARGS accordingly.
# COMPOSE_FILE_ARGS always starts with `-f docker-compose.yml` so callers can
# pass it unconditionally without empty-array headaches under `set -u`.
#
# Layering rules:
#   docker-compose.yml                          — base, always
#   docker-compose.<PROFILE>.yml                — always-on profile overlay
#                                                 (siblings that belong with
#                                                 this profile; auto-layered
#                                                 if present, no flag needed)
#   docker-compose.<PROFILE>.expose-dev.yml     — opt-in via --expose-dev
#                                                 (LAN exposure / unsafe
#                                                 port publishing)
COMPOSE_FILE_ARGS=(-f docker-compose.yml)
# Auto-layer the always-on profile overlay if it exists. Silent — no warning,
# this is the expected shape for any profile that ships sibling services.
if [[ -f "$SCRIPT_DIR/docker-compose.$PROFILE.yml" ]]; then
  COMPOSE_FILE_ARGS+=(-f "docker-compose.$PROFILE.yml")
fi
parse_flags() {
  local expose=0 remaining=()
  for a in "$@"; do
    case "$a" in
      --expose-dev) expose=1 ;;
      *) remaining+=("$a") ;;
    esac
  done
  ARGS=("${remaining[@]+"${remaining[@]}"}")
  if [[ "$expose" == "1" ]]; then
    local override="$SCRIPT_DIR/docker-compose.$PROFILE.expose-dev.yml"
    [[ -f "$override" ]] || fail "--expose-dev: override not found: $override
       Create the override at the macolima repo root (a YAML file adding a
       'ports:' block under claude-agent), then rerun. See
       docker-compose.therapod.expose-dev.yml for the canonical shape."
    COMPOSE_FILE_ARGS+=(-f "docker-compose.$PROFILE.expose-dev.yml")
    warn "UNSAFE: --expose-dev — layering $override (publishes ports to LAN)"
  fi
}

# --- dispatch ---------------------------------------------------------------
case "$CMD" in
  up)
    parse_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
    ensure_repo_dir
    ensure_state
    info "Bringing up profile '$PROFILE' (project: $COMPOSE_PROJECT_NAME)"
    docker compose "${COMPOSE_FILE_ARGS[@]}" up -d "$@"
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
    docker compose build claude-agent "$@"
    info "Pruning dangling images and build cache to reclaim inodes"
    docker image prune -f
    docker builder prune -f --keep-storage=4g
    ;;

  recreate)
    # Recreate containers without rebuilding the image — picks up compose,
    # seccomp, proxy, mount, env, and dns/extra_hosts changes. For Dockerfile
    # changes use `rebuild` instead. Equivalent to setup.sh's --recreate flag.
    parse_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
    ensure_repo_dir
    ensure_state
    info "Force-recreating profile '$PROFILE' (no image rebuild)"
    docker compose "${COMPOSE_FILE_ARGS[@]}" up -d --force-recreate "$@"
    ok "Recreated. Attach with:  scripts/profile.sh $PROFILE attach"
    ;;

  rebuild)
    parse_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
    ensure_repo_dir
    ensure_state
    info "Rebuilding image + recreating profile '$PROFILE'"
    docker compose "${COMPOSE_FILE_ARGS[@]}" build claude-agent
    info "Pruning dangling images and build cache to reclaim inodes"
    docker image prune -f
    docker builder prune -f --keep-storage=4g
    docker compose "${COMPOSE_FILE_ARGS[@]}" up -d --force-recreate
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

  db-reset)
    # Wipe the postgres data volume and bring postgres back with a fresh initdb.
    # The default `postgres` database is created automatically; project databases
    # must be created explicitly afterwards (CREATE DATABASE ... OWNER agent).
    PG_CONTAINER="postgres-$PROFILE"
    PG_VOLUME="${COMPOSE_PROJECT_NAME}_postgres-data"

    assume_yes=0
    for a in "$@"; do
      case "$a" in
        --yes|-y) assume_yes=1 ;;
        *) fail "db-reset: unknown flag '$a' (valid: --yes)" ;;
      esac
    done

    warn "This will DESTROY all Postgres data for profile '$PROFILE':"
    warn "  volume: $PG_VOLUME"
    warn "  container: $PG_CONTAINER (will be stopped + removed + recreated)"
    warn "After reset, only the default 'postgres' database will exist."
    warn "You'll need to CREATE DATABASE for each project and re-seed/re-run pipelines."

    if [[ "$assume_yes" != "1" ]]; then
      printf '\nProceed? type the profile name (%s) to confirm: ' "$PROFILE"
      read -r confirm
      [[ "$confirm" == "$PROFILE" ]] || fail "confirmation mismatch; aborting"
    fi

    # 1. Stop and remove the postgres container.
    if docker ps -a --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
      info "stopping $PG_CONTAINER"
      docker stop "$PG_CONTAINER" 2>/dev/null || true
      docker rm "$PG_CONTAINER" 2>/dev/null || true
      ok "removed $PG_CONTAINER"
    else
      info "$PG_CONTAINER not found (already removed or never started)"
    fi

    # 2. Remove the data volume.
    if docker volume ls -q | grep -qx "$PG_VOLUME"; then
      docker volume rm "$PG_VOLUME"
      ok "removed volume $PG_VOLUME"
    else
      info "volume $PG_VOLUME not found (already removed)"
    fi

    # 3. Bring postgres back up (fresh initdb reads POSTGRES_USER/PASSWORD from db.env).
    info "bringing postgres back up (COMPOSE_PROFILES=db-postgres)"
    COMPOSE_PROFILES=db-postgres docker compose "${COMPOSE_FILE_ARGS[@]}" up -d postgres
    ok "postgres is up with a fresh data volume"

    # 4. Wait briefly for initdb to finish, then verify.
    info "waiting for postgres to accept connections..."
    for i in $(seq 1 15); do
      if docker exec "$PG_CONTAINER" pg_isready -U agent -d postgres >/dev/null 2>&1; then
        ok "postgres is ready"
        break
      fi
      [[ "$i" -eq 15 ]] && warn "postgres not ready after 15s — check: docker logs $PG_CONTAINER"
      sleep 1
    done

    echo ""
    info "Next steps — create your project databases:"
    echo "  docker exec $PG_CONTAINER psql -U agent -d postgres \\"
    echo "    -c 'CREATE DATABASE <name> OWNER agent;'"
    echo ""
    info "Then seed/migrate from inside the agent container and force-recreate"
    info "the agent if you changed DSNs in db.env:"
    echo "  COMPOSE_PROFILES=db-postgres scripts/profile.sh $PROFILE recreate"
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
    #            config/glab-cli/, config/git/, gemini-home/oauth_creds.json,
    #            db.env (DB superuser credentials — preserved even with
    #            --all-volumes; rm it yourself if you want fresh creds).
    # Wipes:     containers (agent AND db siblings, even if not in the caller's
    #            COMPOSE_PROFILES — see `--profile db-all` on the `down` below),
    #            vscode-server + cache named volumes, everything else under
    #            profiles/<p>/ (settings, skills, sessions, projects, paste-cache,
    #            shell-snapshots, audits, ...).
    # Does NOT touch: shared image (use `build` to rebuild), DB *data* volumes
    #            (postgres-data, mongo-data) unless --all-volumes is passed.
    #            NOTE: DB *containers* are always stopped+removed; they're
    #            recreated from the surviving data volumes on next `up`.
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

    # Reaper: bail out if a previous wipe was interrupted between the stage and
    # restore steps — auth artefacts may be stranded in .wipe-stage-<p>-<ts>/.
    # Don't auto-recover; the operator should look before we touch anything.
    shopt -s nullglob
    orphans=( "$PROFILES_ROOT"/.wipe-stage-"$PROFILE"-* )
    shopt -u nullglob
    if (( ${#orphans[@]} > 0 )); then
      warn "found orphaned wipe stage dir(s) from a previous interrupted run:"
      printf '  %s\n' "${orphans[@]}"
      fail "inspect/restore manually (creds may be inside), then rerun"
    fi

    # Itemise what will survive vs disappear, so the user sees it before confirming.
    info "wipe plan for profile '$PROFILE' (project: $COMPOSE_PROJECT_NAME)"
    echo "  PRESERVE:"
    echo "    $p/claude.json"
    echo "    $p/claude-home/.credentials.json"
    echo "    $p/config/gh/"
    echo "    $p/config/glab-cli/"
    echo "    $p/config/git/"
    echo "    $p/gemini-home/oauth_creds.json"
    echo "    $p/db.env  (if present)"
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
    #    --profile db-all forces postgres/mongo into scope regardless of the
    #    caller's COMPOSE_PROFILES; otherwise they'd be left running and the
    #    sandbox-internal network would refuse to delete ("Resource is still
    #    in use"), leaving a half-state where wipe re-seeds the profile dir
    #    but old DB containers are stranded on a dead network.
    info "tearing down containers (including db siblings via --profile db-all)"
    if [[ "$all_vols" == "1" ]]; then
      docker compose --profile db-all down -v --remove-orphans \
        || warn "compose down had errors; continuing"
    else
      docker compose --profile db-all down --remove-orphans \
        || warn "compose down had errors; continuing"
      # Drop the throwaway named volumes (vscode-server, cache); leave DB volumes alone.
      for v in vscode-server cache; do
        docker volume rm "${COMPOSE_PROJECT_NAME}_${v}" 2>/dev/null \
          && ok "removed volume ${COMPOSE_PROJECT_NAME}_${v}" \
          || info "no ${v} volume to remove (or already gone)"
      done
    fi

    # 1b. Verify nothing in the project is still up. If something is, the
    #     network won't be removed, and a subsequent `up` will create a new
    #     network leaving the stragglers stranded. Fail loud rather than
    #     paper over it with the rest of the wipe.
    leftover=$(docker ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME")
    if [[ -n "$leftover" ]]; then
      warn "containers still present after down:"
      docker ps -a --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" \
        --format '  {{.Names}}  ({{.Status}})'
      fail "refusing to continue; tear them down manually (docker rm -f <name>) and rerun"
    fi

    # 2. Stage auth on the same filesystem so the move is a rename, not a copy.
    stage="$PROFILES_ROOT/.wipe-stage-$PROFILE-$(date +%s)"
    mkdir -p "$stage/claude-home" "$stage/config" "$stage/gemini-home"
    [[ -f "$p/claude.json" ]]                && mv "$p/claude.json"                "$stage/claude.json"
    [[ -f "$p/claude-home/.credentials.json" ]] && mv "$p/claude-home/.credentials.json" "$stage/claude-home/.credentials.json"
    [[ -d "$p/config/gh" ]]                  && mv "$p/config/gh"                  "$stage/config/gh"
    [[ -d "$p/config/glab-cli" ]]            && mv "$p/config/glab-cli"            "$stage/config/glab-cli"
    [[ -d "$p/config/git" ]]                 && mv "$p/config/git"                 "$stage/config/git"
    [[ -f "$p/gemini-home/oauth_creds.json" ]] && mv "$p/gemini-home/oauth_creds.json" "$stage/gemini-home/oauth_creds.json"
    [[ -f "$p/db.env" ]]                       && mv "$p/db.env"                       "$stage/db.env"
    ok "staged auth artefacts → $stage"

    # 3. Nuke the profile dir.
    rm -rf "$p"
    ok "removed $p"

    # 4. Restore auth into a fresh profile dir.
    mkdir -p "$p/claude-home" "$p/config" "$p/gemini-home"
    [[ -f "$stage/claude.json" ]]                && mv "$stage/claude.json"                "$p/claude.json"
    [[ -f "$stage/claude-home/.credentials.json" ]] && mv "$stage/claude-home/.credentials.json" "$p/claude-home/.credentials.json"
    [[ -d "$stage/config/gh" ]]                  && mv "$stage/config/gh"                  "$p/config/gh"
    [[ -d "$stage/config/glab-cli" ]]            && mv "$stage/config/glab-cli"            "$p/config/glab-cli"
    [[ -d "$stage/config/git" ]]                 && mv "$stage/config/git"                 "$p/config/git"
    [[ -f "$stage/gemini-home/oauth_creds.json" ]] && mv "$stage/gemini-home/oauth_creds.json" "$p/gemini-home/oauth_creds.json"
    [[ -f "$stage/db.env" ]]                       && mv "$stage/db.env"                       "$p/db.env"
    # All preserved items have been moved back into $p; anything left in $stage
    # is unexpected. Sanity-check, then nuke the stage dir wholesale (rmdir
    # was fragile — failed silently if any future preserve target added a
    # sub-sub-dir, leaving stage debris around).
    residue=$(find "$stage" -mindepth 1 -not -type d 2>/dev/null)
    if [[ -n "$residue" ]]; then
      warn "unexpected files left in stage dir; not removing automatically:"
      printf '  %s\n' $residue
      warn "inspect: $stage"
    else
      rm -rf "$stage"
    fi

    # 5. Restore the sensitive perms documented in CLAUDE.md.
    #    .credentials.json must be 600 (inside a directory bind-mount, UID remap works).
    #    claude.json must be 644 (single-file bind-mount needs world-readable so agent UID 1000 sees it).
    [[ -f "$p/claude-home/.credentials.json" ]] && chmod 600 "$p/claude-home/.credentials.json"
    [[ -f "$p/claude.json" ]]                   && chmod 644 "$p/claude.json"
    [[ -f "$p/db.env" ]]                        && chmod 600 "$p/db.env"
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
    # Tell the user what went wrong before dumping the help. Includes a hint
    # for the most common slip: setup.sh uses --flag style, profile.sh uses
    # subcommand style; mixing them up produced the silent `usage`-then-exit
    # that this branch used to cause.
    printf '\033[0;31m[FAIL]\033[0m  Unknown profile.sh command: %q\n' "$CMD" >&2
    if [[ "$CMD" == --* ]]; then
      printf '       Hint: profile.sh uses subcommands (no leading "--").\n' >&2
      printf '       Did you mean:  scripts/setup.sh %s %s\n' "$PROFILE" "$CMD" >&2
      printf '       Or the profile.sh equivalent:  scripts/profile.sh %s %s\n' \
             "$PROFILE" "${CMD#--}" >&2
    fi
    echo >&2
    usage
    ;;
esac
