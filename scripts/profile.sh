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
#   auth-antigravity  run `agy` (Antigravity CLI) inside the container —
#                   interactive console sign-in (URL + one-time code)
#   logs            tail container logs
#   status          all containers in this profile's compose project, any state
#                   (running + stopped), by project label — robust to
#                   compose-profile gating. Accepts extra `docker ps` flags.
#   build           force-rebuild the shared image (NO profile arg — the image is
#                   shared by every profile). Flags: --no-cache, --pull,
#                   --refresh-ai (rebuild just the Claude Code + agy tail layer),
#                   --claude-version=X.Y.Z (pin claude; implies --refresh-ai).
#   recreate        force-recreate this profile's containers (no image rebuild — picks up
#                   compose / seccomp / proxy / mount changes). Equivalent to
#                   `setup.sh <p> --recreate` (which is the flag-style alias).
#   rebuild         build + recreate this profile's containers
#   reset-settings  overwrite this profile's claude settings.json from sandbox_templates/claude/claude-settings.json (backs up the old one)
#   reset-skills    converge this profile's claude skills to sandbox_templates/skills/ (mirrors; keeps no backups)
#   db-reset        wipe the postgres data volume and bring postgres back up with a fresh initdb.
#                   Flags: --yes (skip confirmation). Does NOT touch mongo; does NOT recreate
#                   the agent container (force-recreate it yourself if db.env DSNs changed).
#   clean           prune rotating state (old .claude.json backups, paste-cache, shell-snapshots).
#                   Pass --deep to also drop MCP debug logs + settings.json.bak.* backups.
#   wipe            blank-slate this profile: down -v, nuke per-profile state, KEEP auth
#                   (claude creds, claude.json, gh, git identity). Confirms first.
#                   Flags: --dry-run (show only), --yes (skip prompt), --all-volumes (also drop DB volumes)
#   deps            dependency posture for this profile's workspace (HOST-SIDE,
#                   read-only; depaudit.py). Offline by default. Flags:
#                   --osv (OSV malicious-package check), --vulns (uv audit,
#                   known CVEs, non-gating), --json, --strict, --quiet.
#                   `deps --history [N]` reads back the install-window log
#                   written by with-egress.sh.
#   audit           tier-2 structured audit: stage the package, run ~85 probes
#                   inside the agent, save JSON to the profile's claude-home.
#                   Flags: --stage-only, --clean, --compact.
#   verify          tier-1 hardening tripwire: host-side allowlist-enforcement
#                   checks, then verify-sandbox.sh streamed into the agent.
#                   Read-only. Exits nonzero if anything failed.
#   list            list all existing profiles (by drive dir)
#   health          cross-profile consistency check (no profile arg): flags any
#                   profile whose agent / proxy / declared DB siblings aren't all
#                   up together. Read-only; exits 1 if any profile is DEGRADED.
#   exec <cmd...>   run an arbitrary command inside the agent container
#
# Optional flags (accepted by up / recreate / rebuild):
#   --expose-dev    layer docker-compose.<profile>.yml on top of the base
#                   compose file. Used to opt into LAN port publishing for an
#                   iPad / browser to reach a dev server inside the container.
#                   The override file must already exist at the repo root.
#                   UNSAFE: drops the `internal: true` network isolation for
#                   the duration. Re-run `up` without this flag to undo.
#
# Optional flags (accepted by build / rebuild only — rejected elsewhere):
#   --no-cache      pass --no-cache to `docker compose build`. Forces every
#                   Dockerfile layer to re-run; pulls latest claude-code / npm
#                   packages / apt indexes instead of reusing cached layers.
#   --pull          pass --pull to `docker compose build`. Re-checks the base
#                   image registry for a newer digest (no-op for the pinned
#                   ubuntu:24.04 digest but future-proof).
# =============================================================================
set -euo pipefail

# SANDBOX_DRIVE is a TEST SEAM, not a configuration knob. The real value is the
# Colima mount root and is not meaningfully changeable — point it elsewhere and
# the VM cannot see the bind mounts, which fails loudly at container start.
# profile-skills.test.sh needs it so it can exercise the real dispatch path
# against a throwaway profile root instead of the live one; the alternative is a
# test that either writes into real profiles or re-implements the script it is
# meant to be testing.
DRIVE="${SANDBOX_DRIVE:-/Volumes/DataDrive}"
PROFILES_ROOT="$DRIVE/.claude-colima/profiles"
REPO_ROOT="$DRIVE/repo"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Scopes the post-build image prune to images WE built (LABEL in Dockerfile).
# An unfiltered `docker image prune` is daemon-wide, and this Colima daemon is
# shared with the user's own projects (e.g. macolima-therapod-pipeline-api) as
# well as the digest-pinned postgres/mongo/squid pulls. Anything of theirs that
# is untagged at the moment a build finishes would be reaped as collateral, and
# a re-pull of the pinned DB/proxy images costs ~1 GB. Nothing on this daemon is
# dangling right now, so this is a guard, not a fire.
IMAGE_PRUNE_FILTER=(--filter label=sandbox.image=macolima)

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

# `list`, `health` and `build` are the commands that don't need a profile arg
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

# --- `health` — cross-profile consistency check (no profile arg) -------------
# Read-only; never starts or stops anything. For EVERY known profile (state dir
# OR live container) it checks the containers that MUST run together:
#   agent  claude-agent-<p>          proxy  egress-proxy-<p>
#   + whichever DB siblings the profile declares:
#          <p>-postgres-sandbox      mongo-<p>
# Those four names are asymmetric (two suffixed, one prefixed, one infixed)
# because they are `container_name:` literals in docker-compose.yml, not a
# pattern — read them from there, never guess.
#
# A profile with NOTHING running is intentionally down (OK). A profile with SOME
# containers up but an expected sibling missing or exited is DEGRADED and gets a
# fix hint: that is the proxy-exited shape (every egress call fails with
# ECONNREFUSED …:3128 and looks like a network/auth bug) and the stale-DB shape.
# Orphan DBs — a DB up while its agent is down — are flagged too.
# Exits 1 if any profile is DEGRADED, so it doubles as a pre-flight tripwire.
if [[ "${1:-}" == "health" ]]; then
  shopt -s nullglob
  C_G=$'\033[0;32m'; C_R=$'\033[0;31m'; C_Y=$'\033[1;33m'; C_D=$'\033[0;90m'; C_0=$'\033[0m'

  # One snapshot of every container's name + coarse state (running/exited/...).
  snapshot="$(docker ps -a --format '{{.Names}}'$'\t''{{.State}}' 2>/dev/null || true)"
  docker_up=1
  if ! docker info >/dev/null 2>&1; then docker_up=0; fi

  cstate() { awk -F '\t' -v n="$1" '$1==n{print $2; f=1} END{if(!f) print "absent"}' <<<"$snapshot"; }
  slab()   { case "$1" in running) printf 'up';; absent) printf -- '-';; *) printf '%s' "$1";; esac; }

  # Profiles = state dirs UNION profiles implied by any existing container, so an
  # orphan container under a wiped or never-created profile still surfaces. The
  # postgres arm is an exact SUFFIX match: a host-side `<p>-postgres-host` next
  # to the sandbox's `<p>-postgres-sandbox` must not be claimed as ours.
  profiles="$(
    { for d in "$PROFILES_ROOT"/*/; do
        if [[ -d "$d" ]]; then basename "$d"; fi
      done
      printf '%s\n' "$snapshot" | awk -F '\t' '{print $1}' \
        | sed -n -E -e 's/^(claude-agent|egress-proxy|mongo)-(.+)$/\2/p' \
                    -e 's/^(.+)-postgres-sandbox$/\1/p'
    } | sort -u
  )"
  if [[ -z "$profiles" ]]; then
    if (( ! docker_up )); then
      echo "(no profiles on disk, and the Docker daemon is unreachable — is the VM up? 'just colima-up')"
    else
      echo "(no profiles and no sandbox containers found)"
    fi
    exit 0
  fi
  if (( ! docker_up )); then
    warn "Docker daemon unreachable — every container reads as absent below."
    warn "Start the VM first ('just colima-up'), or this is a report about nothing."
  fi

  printf "${C_D}Host state: %s   |   up=running, exited/created/…=present-not-running, -=absent${C_0}\n\n" "$PROFILES_ROOT"
  printf '\033[1m%-18s %-8s %-8s %-22s %s\033[0m\n' PROFILE AGENT PROXY DB VERDICT
  flags=()
  degraded=0
  while IFS= read -r p; do
    if [[ -z "$p" ]]; then continue; fi
    a_s=$(cstate "claude-agent-$p");     x_s=$(cstate "egress-proxy-$p")
    g_s=$(cstate "$p-postgres-sandbox"); m_s=$(cstate "mongo-$p")

    # Which DBs SHOULD be up is derived from the same source `up` uses: the
    # per-profile overlay's depends_on references, which drive the
    # COMPOSE_PROFILES auto-activation further down this file. Mirrored
    # verbatim — including its habit of matching `depends_on: [postgres]`
    # inside a comment — because health must agree with what `up` will
    # actually start, not with what a stricter parser thinks it should.
    # (M has no persisted compose-profiles file; the overlay IS the record.)
    overlay="$SCRIPT_DIR/docker-compose.$p.yml"
    exp_pg=0; exp_mongo=0
    if [[ -f "$overlay" ]]; then
      if grep -qE 'depends_on:.*postgres|depends_on:\s*\[.*postgres' "$overlay" 2>/dev/null; then exp_pg=1; fi
      if grep -qE 'depends_on:.*mongo|depends_on:\s*\[.*mongo' "$overlay" 2>/dev/null; then exp_mongo=1; fi
    fi

    a_run=0; if [[ "$a_s" == running ]]; then a_run=1; fi
    x_run=0; if [[ "$x_s" == running ]]; then x_run=1; fi
    g_run=0; if [[ "$g_s" == running ]]; then g_run=1; fi
    m_run=0; if [[ "$m_s" == running ]]; then m_run=1; fi
    active=$(( a_run || x_run || g_run || m_run ))

    # DB cell: show each expected DB's state; mark unexpected-but-running with '!'.
    parts=()
    if (( exp_pg ));               then parts+=("pg:$(slab "$g_s")"); fi
    if (( exp_mongo ));            then parts+=("mongo:$(slab "$m_s")"); fi
    if (( ! exp_pg && g_run ));    then parts+=("pg:up!"); fi
    if (( ! exp_mongo && m_run )); then parts+=("mongo:up!"); fi
    if (( ${#parts[@]} == 0 )); then db_cell='-'; else db_cell="${parts[*]}"; fi

    if (( ! active )); then
      verdict="down"; color="$C_D"
      # Fully down is fine, but note any stopped leftovers worth cleaning.
      for pair in "claude-agent-$p=$a_s" "egress-proxy-$p=$x_s" "$p-postgres-sandbox=$g_s" "mongo-$p=$m_s"; do
        nm="${pair%=*}"; st="${pair##*=}"
        case "$st" in
          absent|running) ;;
          *) flags+=("WARN  $p: leftover $nm ($st) — 'scripts/profile.sh $p down' to clean") ;;
        esac
      done
    else
      probs=()
      if (( ! a_run )); then
        probs+=("agent claude-agent-$p is $(slab "$a_s") (expected running) — scripts/profile.sh $p up")
      fi
      if (( ! x_run )); then
        probs+=("egress-proxy-$p is $(slab "$x_s") — egress DOWN (ECONNREFUSED …:3128 on auth/network) — scripts/profile.sh $p up  (quick: docker start egress-proxy-$p)")
      fi
      if (( exp_pg && ! g_run )); then
        probs+=("$p-postgres-sandbox is $(slab "$g_s") but docker-compose.$p.yml declares depends_on: postgres — scripts/profile.sh $p up")
      fi
      if (( exp_mongo && ! m_run )); then
        probs+=("mongo-$p is $(slab "$m_s") but docker-compose.$p.yml declares depends_on: mongo — scripts/profile.sh $p up")
      fi
      # Orphan DBs: running but not declared by the overlay. Harmless while the
      # agent is up (likely a one-shot COMPOSE_PROFILES=…); a stale hazard once
      # the agent is down, because nothing will ever tear it down.
      if (( ! exp_pg && g_run )); then
        if (( a_run )); then
          flags+=("WARN  $p: $p-postgres-sandbox up but docker-compose.$p.yml declares no depends_on: postgres (one-shot COMPOSE_PROFILES? add it to the overlay to persist)")
        else
          probs+=("$p-postgres-sandbox running but agent is down — orphan/stale DB — scripts/profile.sh $p down  (or 'up' to finish coming up)")
        fi
      fi
      if (( ! exp_mongo && m_run )); then
        if (( a_run )); then
          flags+=("WARN  $p: mongo-$p up but docker-compose.$p.yml declares no depends_on: mongo (one-shot COMPOSE_PROFILES? add it to the overlay to persist)")
        else
          probs+=("mongo-$p running but agent is down — orphan/stale DB — scripts/profile.sh $p down  (or 'up' to finish coming up)")
        fi
      fi
      if (( ${#probs[@]} == 0 )); then
        verdict="OK"; color="$C_G"
      else
        verdict="DEGRADED"; color="$C_R"; degraded=1
        for pr in "${probs[@]}"; do flags+=("FAIL  $p: $pr"); done
      fi
    fi

    printf "%-18s %-8s %-8s %-22s ${color}%s${C_0}\n" \
      "$p" "$(slab "$a_s")" "$(slab "$x_s")" "$db_cell" "$verdict"
  done <<< "$profiles"

  if (( ${#flags[@]} )); then
    echo
    printf '\033[1mflags:\033[0m\n'
    for fl in "${flags[@]}"; do
      case "$fl" in
        FAIL*) printf "  ${C_R}%s${C_0}\n" "$fl" ;;
        WARN*) printf "  ${C_Y}%s${C_0}\n" "$fl" ;;
        *)     printf '  %s\n' "$fl" ;;
      esac
    done
  else
    echo; ok "all profiles consistent (each fully up, or fully down)"
  fi
  exit $(( degraded ))
fi

# --- global `build` (no profile needed) --------------------------------------
# The image is SHARED by every profile, so building it was never a per-profile
# operation. CLAUDE.md, README (x4) and three docs have always spelled it
# `scripts/profile.sh build` with no profile arg — only the code disagreed, and
# that exact command exited with the usage screen.
#
# PROFILE=_build satisfies docker-compose.yml's ${PROFILE:?} guard, which exists
# to stop a bare `docker compose` running against an unset project. A build
# creates no network and no container, so the value is inert.
if [[ "${1:-}" == "build" ]]; then
  build_flags=()
  for a in "${@:2}"; do
    case "$a" in
      --no-cache|--pull) build_flags+=("$a") ;;
      # Bust ONLY the AI-CLI refresh layer (Claude Code + agy), so a version bump
      # rebuilds the tail rather than the whole image. A changing token forces
      # the `ARG AI_CLI_REFRESH` RUN to re-execute and pull upstream.
      --refresh-ai)
        build_flags+=(--build-arg "AI_CLI_REFRESH=$(date +%s)") ;;
      # Pin Claude Code to a specific npm version (implies --refresh-ai).
      --claude-version=*)
        build_flags+=(--build-arg "CLAUDE_VERSION=${a#*=}" \
                      --build-arg "AI_CLI_REFRESH=$(date +%s)") ;;
      -*) fail "build: unknown flag '$a' (valid: --no-cache --pull --refresh-ai --claude-version=X.Y.Z)" ;;
      *)  fail "build: unexpected arg '$a' — build takes NO profile (the image is shared).
        For one profile's containers:  scripts/profile.sh $a rebuild
        To roll a profile onto a freshly built image:  scripts/profile.sh $a recreate" ;;
    esac
  done
  info "Building macolima:latest${build_flags[*]:+ (${build_flags[*]})} (shared image across all profiles)"
  cd "$SCRIPT_DIR"
  PROFILE=_build docker compose build "${build_flags[@]+"${build_flags[@]}"}" claude-agent
  info "Pruning dangling images and build cache to reclaim inodes"
  docker image prune -f "${IMAGE_PRUNE_FILTER[@]}"
  # Prune build cache by AGE, not by a size cap. `--keep-storage=4g` (what this
  # was, and what windows-ai-sandbox still uses) reserves LESS than this image's
  # own build cache needs (~8.4 GB), so every build evicted ~4 GB of the
  # least-recently-used entries — which are the apt / Playwright / Node base
  # layers. That silently negated --refresh-ai. Measured on this host: 22s with a
  # warm cache, then 97s on the very next --refresh-ai with ZERO cached layers,
  # the apt layer refetching every index from scratch. An age filter never evicts
  # a layer the current image is still built on. (--keep-storage is also
  # deprecated in Docker 29 in favour of --reserved-space.)
  docker builder prune -f --filter until=168h
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

# ---------------------------------------------------------------------------
# converge_skills — reconcile claude-home/skills/ to the template tree
# ---------------------------------------------------------------------------
# Ported from windows-ai-sandbox (work/0004 V5). ADR-0005:
# `sandbox_templates/skills/` is the SOURCE OF TRUTH and a profile's
# `claude-home/skills/` is a DERIVED CACHE. So this REPLACES divergent copies
# instead of preserving them, and takes NO backups.
#
# Backups are what this function exists to stop making. The old `reset-skills`
# left `<name>.bak.<stamp>` next to the live copy — inside the very directory
# Claude Code scans — which produces two live skills under one `name:` and, for
# a skills-dir plugin (`<dir>/.claude-plugin/plugin.json`), a name race the
# BACKUP wins: measured in-container 2026-08-10 (claude 2.1.223), the fresh copy
# reported `x Not loaded — same plugin name`. `myconv` is exactly that shape, so
# this is live here and not a W-only concern.
#
# Nothing durable is lost: every seeded skill is a copy of a git-tracked
# template, so `git` is the backup. Divergence and pruning are both WARNed —
# loudly, because the alternative is a silent overwrite.
#
# WHAT IS NEVER PRUNED: a directory this function did not put there. Claude
# Code's own `claude plugin init` scaffolds into `~/.claude/skills/<name>/`, so
# "delete anything not in the template" would eat an agent's own work. Pruning
# is scoped to `*.bak.*` plus names recorded in the manifest below.
#
# Membership tests are space-padded case-globs rather than associative arrays:
# W wrote them that way specifically so this function ports to bash 3.2 here
# unchanged, and it does.
SEED_MANIFEST=".sandbox-seeded"

converge_skills() {
  local dst="$PROFILES_ROOT/$PROFILE/claude-home/skills"
  local src="$SCRIPT_DIR/sandbox_templates/skills"
  [[ -d "$src" ]] || return 0
  mkdir -p "$dst"

  # Names previously seeded from the template tree.
  local seeded=" "
  if [[ -f "$dst/$SEED_MANIFEST" ]]; then
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] && seeded="$seeded$line "
    done < "$dst/$SEED_MANIFEST"
  fi

  local skill_src name stage current=" "
  for skill_src in "$src"/*/; do
    [[ -d "$skill_src" ]] || continue
    name="$(basename "$skill_src")"
    current="$current$name "
    if [[ ! -d "$dst/$name" ]]; then
      cp -R "$skill_src" "$dst/$name"
      info "seeded skill '$name'"
    elif ! diff -rq "$skill_src" "$dst/$name" >/dev/null 2>&1; then
      # Staged replace: a mid-copy failure can't leave a half-written skill.
      #
      # DIVERGENCE FROM W, AND THE ONLY ONE — measured, not stylistic. W stages
      # through a bare `mktemp -d`. On macOS $TMPDIR is on the boot volume
      # (device 16777232) while the profiles live on the DataDrive (16777245),
      # so that `mv` degrades to a cross-device copy and the atomicity this
      # block claims is silently gone — after the `rm -rf` has already run.
      # Staging a sibling of the skills dir keeps it on one filesystem, so the
      # `mv` really is a rename. Outside `skills/` on purpose: a leftover stage
      # inside it would be a dot-directory the prune loop's `*/` glob can never
      # see. Strictly better on both platforms; send back to W.
      stage="$(mktemp -d "$PROFILES_ROOT/$PROFILE/claude-home/.skills-stage.XXXXXX")" || {
        warn "skill '$name': could not create a staging dir — left unchanged"
        continue
      }
      cp -R "$skill_src" "$stage/$name"
      rm -rf "$dst/$name"
      mv "$stage/$name" "$dst/$name"
      rmdir "$stage" 2>/dev/null || rm -rf "$stage"
      warn "skill '$name' differed from the template — OVERWRITTEN from sandbox_templates/skills/$name (no backup kept; recover local edits from git or re-apply upstream)"
    fi
  done

  # Prune: stale backups first, then names we seeded that the template dropped.
  local dst_dir
  for dst_dir in "$dst"/*/; do
    [[ -d "$dst_dir" ]] || continue
    name="$(basename "$dst_dir")"
    case "$current" in *" $name "*) continue ;; esac
    case "$name" in
      *.bak.*)
        rm -rf "$dst/$name"
        warn "pruned stale skill backup '$name' (backups are no longer kept — ADR-0005)"
        continue
        ;;
    esac
    case "$seeded" in
      *" $name "*)
        rm -rf "$dst/$name"
        warn "pruned retired skill '$name' (no longer in sandbox_templates/skills/)"
        ;;
      *)
        info "skill '$name' is not from the template tree — leaving it alone"
        ;;
    esac
  done

  # Rewrite the manifest from what the template tree now owns.
  : > "$dst/$SEED_MANIFEST"
  for name in $current; do
    printf '%s\n' "$name" >> "$dst/$SEED_MANIFEST"
  done
}

# --- ensure persistent state dirs -------------------------------------------
ensure_state() {
  local p="$PROFILES_ROOT/$PROFILE"
  # `cache/` is intentionally not pre-created on host — `/home/agent/.cache` is
  # backed by a named Docker volume (`macolima-<p>_cache`), not a bind mount,
  # to avoid virtiofs chmod issues during wheel extraction (lxml etc.).
  # `gemini-home/` mirrors `claude-home/` for the Antigravity CLI's per-profile
  # state (agy reuses the ~/.gemini home; config under ~/.gemini/antigravity-cli/.
  # Dir name kept from the former Gemini CLI mount to avoid churn).
  mkdir -p "$p/claude-home" "$p/config" "$p/gemini-home"
  # Single-file bind mounts need the target to exist on host before first compose up.
  # Seed with '{}' — Claude rejects a 0-byte file as invalid JSON (Unexpected EOF).
  if [[ ! -s "$p/claude.json" ]]; then
    printf '{}\n' > "$p/claude.json"
    chmod 644 "$p/claude.json"
  fi
  mkdir -p "$p/config/git"
  # pnpm: always run the image's pnpm; ignore repo `packageManager` pins.
  # pnpm 10's version manager re-execs a downloaded pnpm from ~/.local/share/
  # pnpm/.tools/ — a noexec tmpfs — so any pin that drifts from the image
  # kills every pnpm command with EACCES. Global pnpm rc only; npm never
  # reads it (no warnings). Mirrors windows-ai-sandbox ensure_state.
  mkdir -p "$p/config/pnpm"
  if ! grep -qs '^manage-package-manager-versions=' "$p/config/pnpm/rc"; then
    printf 'manage-package-manager-versions=false\n' >> "$p/config/pnpm/rc"
  fi
  # Gate 2, pnpm half (work/0001 A5). The Dockerfile's /usr/etc/npmrc covers
  # npm only: pnpm reads npmrc files but its quarantine key is a DIFFERENT one
  # in DIFFERENT units — npm's `min-release-age` is DAYS, pnpm's
  # `minimum-release-age` is MINUTES (pnpm computes value*60*1e3). 7 and 10080
  # are the same 7-day window; do not "harmonise" them to one number.
  #
  # It is seeded here rather than baked into the image because ~/.config is a
  # per-profile bind mount, and this is macolima's equivalent of the
  # init-profile-state.sh seeding windows-ai-sandbox's verify-sandbox.sh cites.
  # A non-integer is worse than absent: pnpm would produce Invalid Date and
  # reject EVERY version, so no install could resolve at all.
  if ! grep -qs '^minimum-release-age=' "$p/config/pnpm/rc"; then
    printf 'minimum-release-age=10080\n' >> "$p/config/pnpm/rc"
  fi
  # Seed a db.env.example so users know which keys to set if they opt into
  # the Postgres/Mongo sibling containers. We never write db.env itself —
  # user copies the example and fills in secrets. The example is a *template*
  # (not user data), so always overwrite — that way doc improvements to the
  # template propagate to existing profiles on the next `up`.
  cp "$SCRIPT_DIR/sandbox_templates/common/db.env.template" "$p/db.env.example"
  # Same deal for API keys the agent's tooling reads (CLICKUP_TOKEN etc.).
  # Overwritten every `up` for the same reason: it is a template, not user data,
  # and the notes in it are the documentation.
  cp "$SCRIPT_DIR/sandbox_templates/common/secrets.env.template" "$p/secrets.env.example"
  # Seed settings.json if absent.
  if [[ ! -f "$p/claude-home/settings.json" ]] && [[ -f "$SCRIPT_DIR/sandbox_templates/claude/claude-settings.json" ]]; then
    cp "$SCRIPT_DIR/sandbox_templates/claude/claude-settings.json" "$p/claude-home/settings.json"
  fi
  # Skills CONVERGE to the template tree on every `up` (ADR-0005) — they are no
  # longer seeded create-only. Create-only is what let profiles drift behind the
  # templates: an edit reached a profile only if someone remembered to run
  # `reset-skills`, and nobody does. Measured 2026-09-02, both live profiles sat
  # 29 lines behind sandbox_templates/skills/myclickup/ after a routine vendor.
  converge_skills
  # Defensive scrub: VS Code Dev Containers can inject a host-routed git
  # credential helper into .config/git/config (via VSCODE_GIT_IPC_HANDLE +
  # a node shim in .vscode-server), and macOS's copyGitConfig can leak
  # osxkeychain / git-credential-manager helpers. Both forward git auth to
  # the host, bypassing the sandbox's network identity. Strip those on every
  # `up` — but leave benign in-container helpers alone (gh's own credential
  # shim, which uses in-container tokens from ~/.config/gh/).
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
  if [[ ! -f "$p/config/git/config" ]] || ! grep -qE '^\[user\]' "$p/config/git/config"; then
    if [[ -n "${GIT_USER_NAME:-}" ]] && [[ -n "${GIT_USER_EMAIL:-}" ]]; then
      {
        printf '[user]\n\tname = %s\n\temail = %s\n' \
          "$GIT_USER_NAME" "$GIT_USER_EMAIL"
        # `if`, NOT `[[ -f ... ]] && cat`. A trailing && whose test fails makes
        # the whole { } group exit 1, and the `&& mv` that used to follow this
        # group then never ran — so on a BRAND-NEW profile, the one case this
        # seeding exists for, the identity was written to config.new and never
        # moved into place. Silently: the caller only checked the mv. Same
        # bash-3.2 hazard this file already documents for `X && continue` in
        # the subnet allocator; it bit twice, in two different shapes.
        if [[ -f "$p/config/git/config" ]]; then cat "$p/config/git/config"; fi
      } > "$p/config/git/config.new"
      if mv "$p/config/git/config.new" "$p/config/git/config"; then
        ok "seeded git identity: $GIT_USER_NAME <$GIT_USER_EMAIL>"
      else
        rm -f "$p/config/git/config.new"
        warn "could not write $p/config/git/config — git identity NOT seeded"
      fi
    else
      # SAY SO. This used to be a silent no-op, and silence is what made it a
      # support incident on 2026-09-02: two profiles created that morning got
      # no identity, and the agent inside one of them reported the gitconfig
      # had "vanished" — it had never existed for that profile, while the
      # older profile's copy sat intact and made the loss look like a
      # regression. An unconfigured state that stands down quietly is
      # indistinguishable from a working one until something is blocked.
      warn "profile '$PROFILE' has NO git commit identity — commits from the agent will fail."
      warn "  fix now:    scripts/setup.sh $PROFILE --name 'Your Name' --email 'you@example.com'"
      warn "  fix always: export GIT_USER_NAME / GIT_USER_EMAIL in your shell rc,"
      warn "              then every future profile self-seeds on first 'up'."
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
  # secrets.env carries third-party API tokens and gets the same treatment for
  # the same reason. Its .example stays 644 — a template is not a secret.
  if [[ -f "$p/secrets.env" ]]; then
    chmod 600 "$p/secrets.env" 2>/dev/null || warn "could not chmod 600 $p/secrets.env"
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

# Path to the allowlist INSIDE the egress-proxy container. One spelling, in one
# place per call site, and scripts/with-egress.test.sh asserts that all four
# agree (squid.conf's acl, this, with-egress.sh, dashboard docker_client.py).
# That lock is not theoretical: the dashboard carried a stale copy of the
# pre-A2 path for the whole of work/0001 A2 and only the test found it (a
# repo-wide grep missed it). Consumed by A8's check_allowlist_sync; declared
# here now because the suite that locks it ports with A4.
PROXY_ALLOWLIST="/etc/squid/host/allowed_domains.txt"

# --- allowlist parsing -------------------------------------------------------
# Which domains does the repo MEAN to deny? Every commented-out domain line
# that is not already covered by an active wildcard parent.
#
# Ported from windows-ai-sandbox with work/0001 A4. It is deliberately here and
# not in with-egress.sh: it is the third of the three parsers that read
# proxy/allowed_domains.txt, and scripts/with-egress.test.sh extracts and locks
# all three from the real sources so they cannot drift apart. Both failure
# directions matter — over-matching reports a healthy proxy as permitting
# revoked hosts, under-matching verifies nothing while printing a reassuring
# count.
#
# Consumed by check_allowlist_sync's enforcement probe (below), which is the
# `verify` verb's host-side half. It landed ahead of that caller because the
# test suite that locks all three parsers ported with its own subject (the
# Phase A0 binding).
list_denied_domains() {
  local allowlist="$1" commented active wild d
  commented=$(sed -n 's/^#[[:space:]]\{1,\}\(\.\{0,1\}[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z][A-Za-z]\{1,\}\)[[:space:]]*$/\1/p' \
    "$allowlist" | sed 's/^\.//' | sort -u)
  active=$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$allowlist" \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sort -u)
  # Active wildcard parents, dot retained: `.foo.com` -> suffix test `*.foo.com`.
  wild=$(printf '%s\n' "$active" | grep '^\.' || true)

  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    local covered=0 w
    while IFS= read -r w; do
      [[ -n "$w" ]] || continue
      [[ "$d" == *"$w" ]] && { covered=1; break; }
    done <<< "$wild"
    [[ "$covered" -eq 0 ]] && printf '%s\n' "$d"
  done < <(comm -23 <(printf '%s\n' "$commented") \
                    <(printf '%s\n' "$active" | sed 's/^\.//' | sort -u))
}

# --- tier-1 hardening verification, host side --------------------------------
# `verify` streams scripts/verify-sandbox.sh into the AGENT container. Two
# checks CANNOT live in that script: it runs inside the agent, which can see
# neither this repo (the sandbox repo is not bind-mounted into /workspace) nor
# the proxy container. Anything comparing host state against the proxy has to
# run here.

# macOS has no timeout(1). Byte-identical to the helper in with-egress.sh —
# duplicated rather than sourced because both scripts are self-contained by
# design; keep them in step if either changes.
_timeout() {  # <seconds> <cmd> [args...]
  local secs="$1"; shift
  perl -e '
    my $secs = shift @ARGV;
    my $pid  = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) { exec @ARGV or exit 127; }
    $SIG{ALRM} = sub { kill "TERM", $pid; };
    alarm $secs;
    waitpid($pid, 0);
    my $st = $?;
    alarm 0;
    exit($st & 127 ? 128 + ($st & 127) : $st >> 8);
  ' "$secs" "$@"
}

# Allow-direction canary for the enforcement probe. Must be a domain the repo
# keeps permanently uncommented — it is the one host the probe expects squid NOT
# to deny, which catches "the proxy is enforcing some other list entirely", a
# case the deny sweep cannot see. Unlike the deny sweep, this costs one real
# upstream connect per verify.
ALLOWLIST_CANARY="api.anthropic.com"

# check_allowlist_sync — is the proxy ENFORCING the repo's allowlist?
#
# Two independent staleness modes, and a naive file comparison catches only one:
#
#   Mode B — inode swap. An atomic-replace edit (vim, sed -i, git checkout, the
#     Edit tool) gives the host file a NEW inode; a single-FILE bind mount stays
#     on the OLD one and can never see another update. `squid -k reconfigure`
#     does NOT fix this and does not report failure — it exits 0 having applied
#     nothing. Caught by the inode comparison below.
#
#   Mode A — edited in place but never reloaded. The container's file is
#     byte-identical to the repo's, so any diff is clean, but squid parsed the
#     allowlist into memory at startup and is still enforcing the OLD set. This
#     is INVISIBLE to file comparison and no timestamp settles it. Squid is
#     asked directly instead.
#
# The deny sweep makes no outbound request: squid answers 403 from its parsed
# config before touching DNS or an upstream, so this still works with egress
# down. Only the single allowed canary opens a real connection. An extra domain
# in the container is the dangerous direction — a host the repo revoked but the
# proxy still permits — so that is a hard FAIL, not a warning.
check_allowlist_sync() {
  local proxy="egress-proxy-$PROFILE"
  local allowlist="$SCRIPT_DIR/proxy/allowed_domains.txt"
  local rc=0

  if [[ ! -f "$allowlist" ]]; then warn "allowlist missing: $allowlist"; return 0; fi
  # Running, not merely present: `docker inspect` succeeds for a STOPPED
  # container, so the bare existence check (what windows-ai-sandbox uses) falls
  # through to the exec below and reports "could not read the allowlist inside
  # the proxy — this profile may predate the directory mount", which points at
  # entirely the wrong thing when the real answer is "the proxy is stopped".
  if [[ "$(docker inspect -f '{{.State.Running}}' "$proxy" 2>/dev/null || echo false)" != "true" ]]; then
    info "allowlist sync: $proxy is not running — allowlist enforcement NOT verified"
    return 0
  fi

  local host_doms ctr_doms delta
  host_doms=$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$allowlist" | sort)
  if ! ctr_doms=$(docker exec "$proxy" sh -c \
      "grep -vE '^[[:space:]]*#|^[[:space:]]*\$' $PROXY_ALLOWLIST | sort" 2>/dev/null); then
    warn "allowlist sync: could not read $PROXY_ALLOWLIST inside $proxy — if this profile predates the directory mount, recreate it with 'scripts/profile.sh $PROFILE up'"
    HOST_WARNS=$(( ${HOST_WARNS:-0} + 1 )); return 0
  fi

  if [[ "$host_doms" == "$ctr_doms" ]]; then
    ok "allowlist in sync with $proxy ($(printf '%s\n' "$host_doms" | grep -c . || true) domains)"
  else
    delta=$(diff <(printf '%s\n' "$host_doms") <(printf '%s\n' "$ctr_doms") | grep '^[<>]' | head -10 || true)
    printf '\033[0;31m[FAIL]\033[0m  allowlist DRIFT — %s is not serving this repo'"'"'s allowlist\n' "$proxy" >&2
    printf '%s\n' "$delta" | sed 's/^>/        proxy permits (repo does NOT):/; s/^</        repo has (proxy lacks):     /' >&2
    printf '        fix: docker restart %s   (or `squid -k reconfigure`, which is\n' "$proxy" >&2
    printf '        trustworthy again under the directory mount — it can no longer\n' >&2
    printf '        silently re-read a stale copy)\n' >&2
    rc=1
    HOST_FAILS=$(( ${HOST_FAILS:-0} + 1 ))
  fi

  # REGRESSION LOCK — asserts the MOUNT SHAPE, not inode identity.
  #
  # windows-ai-sandbox compares the host file's inode against the container's.
  # That works where a bind mount passes straight through one Linux filesystem.
  # It CANNOT work here: the file crosses macOS -> virtiofs -> the Colima VM ->
  # the Docker bind, and virtiofs assigns its own inode numbers. Measured on this
  # host: macOS inode 3551456, while the VM and the container both report 7.
  # Ported verbatim the check FAILS 100% of the time against a perfectly healthy
  # proxy, and a permanently-firing tripwire is furniture.
  #
  # What it is FOR is still real. A single-FILE bind mount pins an inode at
  # container start, so a host-side atomic replace (git checkout/merge/pull, an
  # editor save, sed -i, mktemp+mv) leaves the container on the old, deleted
  # inode — blind to every later host write, with `squid -k reconfigure`
  # re-reading the stale copy and exiting 0. The content diff above cannot catch
  # that alone: when only comment lines change, the stripped domain lists still
  # match and it reports "in sync" while the proxy is blind.
  #
  # So assert the invariant directly: /etc/squid/host must be a bind of the
  # proxy DIRECTORY. Platform-independent, cannot false-positive, and it names
  # the exact thing docker-compose.yml must not lose.
  local mnt_src
  mnt_src=$(docker inspect "$proxy" --format \
    '{{range .Mounts}}{{if eq .Destination "/etc/squid/host"}}{{.Source}}{{end}}{{end}}' \
    2>/dev/null || echo "")
  if [[ -z "$mnt_src" ]]; then
    printf '\033[0;31m[FAIL]\033[0m  %s has no directory mount at /etc/squid/host — the allowlist\n' "$proxy" >&2
    printf '        is not being served from a directory. If docker-compose.yml was\n' >&2
    printf '        reverted to a single-FILE bind mount of allowed_domains.txt, the\n' >&2
    printf '        proxy goes silently blind to host edits after any atomic replace.\n' >&2
    printf '        fix: restore the `./proxy:/etc/squid/host:ro` mount, then scripts/profile.sh %s up\n' "$PROFILE" >&2
    rc=1
    HOST_FAILS=$(( ${HOST_FAILS:-0} + 1 ))
  elif [[ "$mnt_src" != "$SCRIPT_DIR/proxy" ]]; then
    warn "/etc/squid/host in $proxy is mounted from $mnt_src, not $SCRIPT_DIR/proxy — this proxy is serving another checkout's allowlist"
    HOST_WARNS=$(( ${HOST_WARNS:-0} + 1 ))
  else
    ok "allowlist served from a DIRECTORY mount ($mnt_src) — path re-resolves on every open, so host edits land immediately"
  fi

  # Mode A, DECISIVE — ask squid what it is actually enforcing.
  #
  # Open a CONNECT to squid's own port from inside the proxy container and read
  # the status line. 403 means the in-memory ACL denies the host — answered from
  # squid's parsed config BEFORE any DNS or upstream connect, so the deny
  # direction costs no egress and works with the internet down.
  #
  # Only the deny direction is swept, because that is the dangerous one and it
  # is free. One allowed canary is probed to catch "squid is enforcing some
  # other list entirely".
  local denied probe_out n_denied
  denied=$(list_denied_domains "$allowlist")
  n_denied=$(printf '%s\n' "$denied" | grep -c . || true)

  if [[ -e "$PROFILES_ROOT/.egress-widened-$PROFILE" ]]; then
    info "enforcement probe skipped — a with-egress window is open for $PROFILE"
  elif [[ "$n_denied" -eq 0 ]]; then
    info "enforcement probe skipped — no commented-out domains to test"
  else
    # One exec for the whole sweep. Per-domain read timeout so a wedged squid
    # cannot stall verify; the outer _timeout caps the worst case regardless.
    probe_out=$(printf '%s\n%s\n' "$denied" "$ALLOWLIST_CANARY" \
      | _timeout 90 docker exec -i "$proxy" bash -c '
          while IFS= read -r d; do
            [ -n "$d" ] || continue
            code=TIMEOUT
            if exec 3<>/dev/tcp/127.0.0.1/3128 2>/dev/null; then
              printf "CONNECT %s:443 HTTP/1.1\r\nHost: %s:443\r\n\r\n" "$d" "$d" >&3
              read -t 3 -r _proto code _rest <&3 || code=TIMEOUT
              exec 3<&- 3>&-
            else
              code=NOCONNECT
            fi
            printf "%s %s\n" "$d" "$code"
          done' 2>/dev/null) || probe_out=""

    if [[ -z "$probe_out" ]]; then
      warn "enforcement probe could not run against $proxy — squid's in-memory allowlist was NOT verified (the file checks above still passed)"
      HOST_WARNS=$(( ${HOST_WARNS:-0} + 1 ))
    else
      local permitted odd unreachable canary_code
      canary_code=$(printf '%s\n' "$probe_out" | awk -v c="$ALLOWLIST_CANARY" '$1==c {print $2}' | tail -1)
      permitted=$(printf '%s\n' "$probe_out" | awk -v c="$ALLOWLIST_CANARY" '$1!=c && $2=="200" {print $1}')
      odd=$(printf '%s\n' "$probe_out" | awk -v c="$ALLOWLIST_CANARY" '$1!=c && $2!="200" && $2!="403" {print $1" ("$2")"}')
      unreachable=$(printf '%s\n' "$odd" | grep -cE '\((TIMEOUT|NOCONNECT)\)$' || true)

      if [[ -n "$permitted" ]]; then
        printf '\033[0;31m[FAIL]\033[0m  %s PERMITS a domain this repo denies — it is enforcing a stale allowlist\n' "$proxy" >&2
        printf '%s\n' "$permitted" | sed 's/^/        proxy tunnels (repo has it commented out): /' >&2
        printf '        fix: docker restart %s   (or `squid -k reconfigure`)\n' "$proxy" >&2
        rc=1
        HOST_FAILS=$(( ${HOST_FAILS:-0} + 1 ))
      fi

      # Anything that is neither 403 nor 200 means the ACL let the request
      # through and something later failed (503 = allowed, upstream
      # unreachable). Kept a WARN until observed in the wild, because a
      # probe-infrastructure failure must never read as an enforcement verdict.
      if [[ -n "$odd" && "$unreachable" -eq 0 ]]; then
        warn "enforcement probe: unexpected status from $proxy — $(printf '%s' "$odd" | tr '\n' ' ')"
        HOST_WARNS=$(( ${HOST_WARNS:-0} + 1 ))
      elif [[ "$unreachable" -gt 0 ]]; then
        warn "enforcement probe: $unreachable of $n_denied domains unprobeable (squid slow or busy) — those were not verified"
        HOST_WARNS=$(( ${HOST_WARNS:-0} + 1 ))
      fi

      if [[ "$canary_code" == "403" ]]; then
        warn "enforcement probe: $proxy denies $ALLOWLIST_CANARY, which this repo allows — it may be enforcing a different or empty allowlist"
        HOST_WARNS=$(( ${HOST_WARNS:-0} + 1 ))
      fi

      if [[ -z "$permitted" && -z "$odd" ]]; then
        ok "allowlist ENFORCED by $proxy ($n_denied denied domains verified 403, $ALLOWLIST_CANARY reachable)"
      fi
    fi
  fi
  return "$rc"
}

# --- per-profile subnet allocation ------------------------------------------
# Ported verbatim from windows-ai-sandbox docs/handoff-to-macolima-subnet-allocator.md
# §4 (work/0001 A1). Deliberately written in the bash-3.2 portable subset —
# /usr/bin/env bash on this host is 3.2.57, so: no associative arrays, no
# `xargs -r` (BSD xargs runs the command once on empty input), `cksum` not
# `md5sum` (macOS has no md5sum), and `if ...; then continue; fi` rather than
# `[[ ... ]] && continue`.
#
# That last one is not style. Under `set -euo pipefail` (line 54) a standalone
# `[[ test ]] && continue` whose test is FALSE returns nonzero and trips set -e,
# aborting the subshell before the function's printf — so the function silently
# returns an empty string with no error. That only bites once the helper is
# called via command substitution, which is exactly how sibling_octets is used.
# `X || continue` is safe; `X && continue` is the hazard.
#
# "Used octet" sets are carried as space-padded strings (" 0 65 187 ") tested
# with a case glob — the 3.2-safe equivalent of an assoc-array membership test.

# Deterministic first-choice octet (0-255) from the profile name. Stable across
# wipes; cksum is POSIX and identical-output on Linux + macOS.
octet_start() { printf '%s' "$1" | cksum | awk '{print $1 % 256}'; }

# Collect octets already claimed by OTHER profiles' subnet-octet files into a
# space-padded string.
sibling_octets() {
  local d name o out=" "
  for d in "$PROFILES_ROOT"/*/; do
    if [[ ! -d "$d" ]]; then continue; fi           # literal glob when no profiles
    name="$(basename "$d")"
    if [[ "$name" == "$PROFILE" ]]; then continue; fi
    if [[ ! -f "$d/subnet-octet" ]]; then continue; fi
    if ! read -r o < "$d/subnet-octet"; then continue; fi
    if [[ "$o" =~ ^[0-9]+$ ]]; then out="$out$o "; fi
  done
  printf '%s' "$out"
}

# First free octet at/after the name-hash start that is NOT in $1 (a space-padded
# "used" string). Echoes the octet, or empty if the /24 space is exhausted.
first_free_octet() {
  local used="$1" start i c
  start="$(octet_start "$PROFILE")"
  for (( i=0; i<256; i++ )); do
    c=$(( (start + i) % 256 ))
    case "$used" in *" $c "*) continue ;; esac
    printf '%s' "$c"; return
  done
}

# Cheap path (no docker calls): reuse persisted octet, or assign one from the
# name hash, skipping octets other profiles' files already claim. Exports
# SANDBOX_OCTET. Called for EVERY command so down/status/logs see the same
# subnet the network was created with.
ensure_subnet_octet() {
  local f="$PROFILES_ROOT/$PROFILE/subnet-octet" want
  if [[ -f "$f" ]] && read -r want < "$f" \
     && [[ "$want" =~ ^[0-9]+$ ]] && (( want <= 255 )); then
    export SANDBOX_OCTET="$want"; return
  fi
  want="$(first_free_octet "$(sibling_octets)")"
  [[ -n "$want" ]] || fail "no free /24 in 172.30.0.0/16 (256-profile max)"
  mkdir -p "$(dirname "$f")"
  printf '%s\n' "$want" > "$f"
  export SANDBOX_OCTET="$want"
}

# Pool check. Call right before a network-creating `compose up`: if our /24 is
# already held by ANOTHER docker network (a non-profile project, or a stale
# net), bump to the next free octet and rewrite the file. Skips our own
# sandbox-internal so recreate doesn't flag itself.
ensure_octet_free() {
  local own="${COMPOSE_PROJECT_NAME}_sandbox-internal" net sub want taken
  taken="$(sibling_octets)"
  while read -r net sub; do
    if [[ "$net" == "$own" ]]; then continue; fi
    if [[ "$sub" =~ ^172\.30\.([0-9]+)\.0/ ]]; then taken="$taken${BASH_REMATCH[1]} "; fi
  done < <(docker network ls -q 2>/dev/null \
            | while read -r id; do
                docker network inspect "$id" \
                  --format '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null || true
              done \
            | awk '{for (i=2;i<=NF;i++) print $1, $i}')
  case "$taken" in
    *" ${SANDBOX_OCTET} "*) ;;          # our /24 is occupied — fall through
    *)                      return ;;   # free — keep current assignment
  esac
  want="$(first_free_octet "$taken")"
  if [[ -z "$want" ]]; then fail "no free /24 in 172.30.0.0/16 (pool check)"; fi
  mkdir -p "$PROFILES_ROOT/$PROFILE"
  printf '%s\n' "$want" > "$PROFILES_ROOT/$PROFILE/subnet-octet"
  warn "172.30.${SANDBOX_OCTET}.0/24 already in use; reassigned '$PROFILE' to 172.30.${want}.0/24"
  export SANDBOX_OCTET="$want"
}

# --- compose wrapper --------------------------------------------------------
export PROFILE
export COMPOSE_PROJECT_NAME="macolima-$PROFILE"
# Must run for every command, not just the network-creating ones: `down`,
# `status` and `logs` all need the same SANDBOX_OCTET the network was created
# with. Cheap — a single file read once the octet is assigned.
ensure_subnet_octet
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
BUILD_FLAGS=()  # --no-cache / --pull, populated by parse_flags; consumed by build/rebuild
# Auto-layer the always-on profile overlay if it exists. Silent — no warning,
# this is the expected shape for any profile that ships sibling services.
if [[ -f "$SCRIPT_DIR/docker-compose.$PROFILE.yml" ]]; then
  COMPOSE_FILE_ARGS+=(-f "docker-compose.$PROFILE.yml")
  # Auto-activate COMPOSE_PROFILES for profile-gated DB siblings when the
  # overlay declares depends_on references to them.  Without this the user
  # would have to remember `COMPOSE_PROFILES=db-postgres` every time.
  if grep -qE 'depends_on:.*postgres|depends_on:\s*\[.*postgres' \
       "$SCRIPT_DIR/docker-compose.$PROFILE.yml" 2>/dev/null; then
    export COMPOSE_PROFILES="${COMPOSE_PROFILES:+${COMPOSE_PROFILES},}db-postgres"
  fi
  if grep -qE 'depends_on:.*mongo|depends_on:\s*\[.*mongo' \
       "$SCRIPT_DIR/docker-compose.$PROFILE.yml" 2>/dev/null; then
    export COMPOSE_PROFILES="${COMPOSE_PROFILES:+${COMPOSE_PROFILES},}db-mongo"
  fi
fi
parse_flags() {
  local expose=0 remaining=()
  for a in "$@"; do
    case "$a" in
      --expose-dev) expose=1 ;;
      --no-cache|--pull) BUILD_FLAGS+=("$a") ;;
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
    (( ${#BUILD_FLAGS[@]} == 0 )) || \
      fail "up: ${BUILD_FLAGS[*]} only applies to build/rebuild (up does not rebuild the image)"
    ensure_repo_dir
    ensure_state
    ensure_octet_free
    info "Bringing up profile '$PROFILE' (project: $COMPOSE_PROJECT_NAME, subnet: 172.30.${SANDBOX_OCTET}.0/24)"
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

  auth-antigravity)
    info "Running 'agy' inside $AGENT (interactive Antigravity sign-in)"
    exec docker exec -it "$AGENT" agy
    ;;

  logs)
    # Pass COMPOSE_FILE_ARGS so overlay services (docker-compose.<PROFILE>.yml)
    # are tailed too, matching up/recreate/rebuild. (Profile-gated services
    # still need their COMPOSE_PROFILE enabled to appear — for therapod that's
    # auto-set from the overlay's depends_on trigger.)
    exec docker compose "${COMPOSE_FILE_ARGS[@]}" logs -f "$@"
    ;;

  status|ps)
    # Every container in this profile's compose project, in any state. Filter by
    # the compose project label — the same mechanism `list` and `wipe` use —
    # rather than `docker compose ps`. Bare `ps` only lists services in the
    # *loaded* compose files (no COMPOSE_FILE_ARGS) that are also in an *enabled*
    # COMPOSE_PROFILE, so invoked standalone it silently hides a running
    # profile-gated or overlay-only sibling (postgres/mongo/etc). The label
    # filter can't: it shows the true project state, including stopped
    # containers — exactly what you want when a stack is partly down. "$@"
    # passes through extra `docker ps` flags (e.g. -q, --format).
    info "Containers for project '$COMPOSE_PROJECT_NAME' (any state):"
    exec docker ps -a --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" "$@"
    ;;

  build)
    # Reachable only as `profile.sh <p> build`. The image is shared, so a
    # profile-scoped build was always a fiction: it built the same image and
    # ignored the profile. Redirect rather than silently accept, so the two
    # spellings can't drift back apart.
    fail "build takes NO profile — the image is shared by every profile.
        Build it:                       scripts/profile.sh build $*
        Then roll '$PROFILE' onto it:   scripts/profile.sh $PROFILE recreate
        Or do both for one profile:     scripts/profile.sh $PROFILE rebuild $*"
    ;;

  recreate)
    # Recreate containers without rebuilding the image — picks up compose,
    # seccomp, proxy, mount, env, and dns/extra_hosts changes. For Dockerfile
    # changes use `rebuild` instead. Equivalent to setup.sh's --recreate flag.
    parse_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
    (( ${#BUILD_FLAGS[@]} == 0 )) || \
      fail "recreate: ${BUILD_FLAGS[*]} only applies to build/rebuild (recreate does not rebuild the image)"
    ensure_repo_dir
    ensure_state
    ensure_octet_free
    info "Force-recreating profile '$PROFILE' (no image rebuild)"
    docker compose "${COMPOSE_FILE_ARGS[@]}" up -d --force-recreate "$@"
    ok "Recreated. Attach with:  scripts/profile.sh $PROFILE attach"
    ;;

  rebuild)
    parse_flags "$@"; set -- "${ARGS[@]+"${ARGS[@]}"}"
    ensure_repo_dir
    ensure_state
    ensure_octet_free
    info "Rebuilding image + recreating profile '$PROFILE'${BUILD_FLAGS[*]:+ (${BUILD_FLAGS[*]})}"
    docker compose "${COMPOSE_FILE_ARGS[@]}" build "${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"}" claude-agent
    info "Pruning dangling images and build cache to reclaim inodes"
    docker image prune -f "${IMAGE_PRUNE_FILTER[@]}"
    # Prune build cache by AGE, not by a size cap. `--keep-storage=4g` (what this
    # was, and what windows-ai-sandbox still uses) reserves LESS than this image's
    # own build cache needs (~8.4 GB), so every build evicted ~4 GB of the
    # least-recently-used entries — which are the apt / Playwright / Node base
    # layers. That silently negated --refresh-ai. Measured on this host: 22s with a
    # warm cache, then 97s on the very next --refresh-ai with ZERO cached layers,
    # the apt layer refetching every index from scratch. An age filter never evicts
    # a layer the current image is still built on. (--keep-storage is also
    # deprecated in Docker 29 in favour of --reserved-space.)
    docker builder prune -f --filter until=168h
    docker compose "${COMPOSE_FILE_ARGS[@]}" up -d --force-recreate
    ;;

  audit)
    # Tier-2 structured audit: stage the package, run the probe suite INSIDE the
    # agent, and save the JSON on the host. Tier 1 is `verify` (fast pass/fail);
    # this is the deep one that produces a machine-readable record.
    #
    # Staged rather than streamed, unlike `verify`: the probes read
    # seccomp.json / allowed_domains.txt / squid.conf / claude-settings.json
    # from the staged tree, so the repo's config has to be visible inside the
    # container. That is the whole reason temp_audit_package exists.
    flag=""
    for a in "$@"; do
      case "$a" in
        --stage-only|--clean|--compact) flag="$a" ;;
        *) fail "audit: unknown flag '$a' (valid: --stage-only --clean --compact)" ;;
      esac
    done

    if [[ "$flag" == "--clean" ]]; then
      exec bash "$SCRIPT_DIR/scripts/stage-audit-package.sh" "$PROFILE" --clean
    fi

    info "Staging audit package for '$PROFILE'"
    bash "$SCRIPT_DIR/scripts/stage-audit-package.sh" "$PROFILE"

    if [[ "$flag" == "--stage-only" ]]; then
      ok "Stage complete. Run the audit with:  scripts/profile.sh $PROFILE audit"
      exit 0
    fi

    stamp=$(date -u +%Y-%m-%dT%H-%M-%SZ)
    audits_host="$PROFILES_ROOT/$PROFILE/claude-home/audits"
    mkdir -p "$audits_host"
    json_host="$audits_host/$stamp-$PROFILE-audit.json"

    info "Running audit inside $AGENT → $json_host"
    pretty_flag=""
    if [[ "$flag" == "--compact" ]]; then pretty_flag="--compact"; fi
    if docker exec "$AGENT" bash /workspace/temp_audit_package/scripts/audit/audit.sh $pretty_flag > "$json_host"; then
      ok "Audit JSON saved: $json_host"
      # Container path, not /root/... — this agent is UID 1000 with
      # HOME=/home/agent, and claude-home/ is bind-mounted there.
      ok "Container path:   /home/agent/.claude/audits/$stamp-$PROFILE-audit.json"
      if command -v jq >/dev/null 2>&1; then
        info "Summary: $(jq -c .summary "$json_host")"
      else
        info "Summary: $(python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1]))["summary"]))' "$json_host" 2>/dev/null || echo '(install jq for a one-line summary)')"
      fi
    else
      fail "Audit run failed; partial JSON at $json_host"
    fi
    ;;

  verify)
    src="$SCRIPT_DIR/scripts/verify-sandbox.sh"
    [[ -f "$src" ]] || fail "verify-sandbox.sh missing: $src"

    # Host-side half first — see check_allowlist_sync's header for why these
    # cannot live inside the streamed script.
    verify_rc=0
    HOST_WARNS=0; HOST_FAILS=0
    check_allowlist_sync || verify_rc=1

    info "Running verify-sandbox.sh inside $AGENT (streamed via stdin)"
    # Streamed, NOT staged: no file has to be copied into /workspace first, so
    # verify leaves no trace in the profile's workspace and cannot run a stale
    # staged copy. (verify-sandbox.sh's own header documents the older
    # stage-audit-package.sh path; that remains how the tier-2 audit works.)
    #
    # NOT `exec` — the host-side result above still has to affect the exit code.
    docker exec -i "$AGENT" bash -s -- "$@" < "$src" || verify_rc=1

    # The tally printed by the streamed script is the CONTAINER's, and it cannot
    # count the host-side checks, which ran here before the stream. Without this
    # line a run prints a loud host-side FAIL and then "0 failed", and the
    # summary is what gets read.
    if (( HOST_WARNS > 0 || HOST_FAILS > 0 )); then
      printf '\033[1;33m== host-side (not in the tally above): %d failed | %d warning(s) ==\033[0m\n' \
        "$HOST_FAILS" "$HOST_WARNS" >&2
    fi
    exit "$verify_rc"
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
    PG_CONTAINER="$PROFILE-postgres-sandbox"
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
    # Overwrite the profile's claude settings.json from sandbox_templates/claude/claude-settings.json.
    # ensure_state() only seeds when absent; use this when the template changes and
    # you want to apply it to an existing profile.
    src="$SCRIPT_DIR/sandbox_templates/claude/claude-settings.json"
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

  deps)
    # Dependency posture for the profile's workspace. Runs HOST-SIDE: depaudit is
    # read-only and spawns nothing, and the OSV cross-check needs api.osv.dev,
    # which is deliberately NOT in the egress allowlist — keeping it on the host
    # means the check costs no egress surface inside any profile (plan D1/D6).
    # Routed through profile.sh anyway, per golden rule 1: discovery of what a
    # profile can do lives here, not in a script the user has to know about.
    da="$SCRIPT_DIR/scripts/depaudit.py"
    [[ -f "$da" ]] || fail "depaudit.py missing: $da"
    command -v python3 >/dev/null 2>&1 || fail "python3 not found on the host (depaudit needs 3.11+)"
    python3 -c 'import sys,tomllib' 2>/dev/null \
      || fail "python3 is too old for depaudit (needs 3.11+ for tomllib): $(python3 -V 2>&1)"

    # --history reads back the T22 install-window log and returns. It is a
    # different question from posture — "what came in, and what did it reach"
    # rather than "how is this repo configured" — and needs no workspace, so it
    # short-circuits before the workspace check below.
    if [[ "${1:-}" == "--history" ]]; then
      hist="$PROFILES_ROOT/$PROFILE/audit/depgate.jsonl"
      [[ -f "$hist" ]] || { info "No install windows recorded yet for '$PROFILE'."; \
        info "The log is written by scripts/with-egress.sh, which per ADR-0003 is the only route a dependency can take."; exit 0; }
      shift
      hist_n="${1:-20}"
      python3 - "$hist" "$hist_n" <<'PY'
import json, sys, datetime

path, want = sys.argv[1], int(sys.argv[2])
rows = []
for line in open(path, encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    try:
        rows.append(json.loads(line))
    except json.JSONDecodeError:
        # A partial line means a run was killed mid-append. Say so; do not
        # silently drop it, or the log looks complete when it is not.
        rows.append(None)

shown = rows[-want:]
bad = sum(1 for r in shown if r is None)
print(f"{len(rows)} window(s) recorded; showing last {len(shown)}\n")
for r in shown:
    if r is None:
        print("  ??  <unparseable line — a run was interrupted mid-write>")
        continue
    when = datetime.datetime.fromtimestamp(r["ts_open"]).strftime("%Y-%m-%d %H:%M")
    eg = r.get("egress", {})
    denied = eg.get("denied", [])
    add = r.get("modules_added", {}).get("count", 0)
    rem = r.get("modules_removed", {}).get("count", 0)
    locks = r.get("lockfiles_changed", [])
    flag = "!" if (denied or r.get("rc")) else " "
    print(f"{flag} {when}  {r['duration_s']:>4}s  rc={r.get('rc',0)}  "
          f"[{','.join(r.get('sections', [])) or '-'}]  modules +{add}/-{rem}  "
          f"lockfiles {len(locks)}")
    print(f"     cmd: {r.get('cmd','')[:100]}")
    if eg.get("allowed"):
        print(f"     reached: {', '.join(eg['allowed'][:8])}"
              + (f" (+{len(eg['allowed'])-8} more)" if len(eg["allowed"]) > 8 else ""))
    if denied:
        print(f"     DENIED : {', '.join(denied)}")
    for p in r.get("preflight", []):
        if p.get("verdict") not in ("NO-KNOWN-MAL", ""):
            print(f"     preflight {p['verdict']}: {p['eco']}/{p['name']} — {p.get('detail','')}")
    if locks:
        print(f"     lockfiles: {', '.join(locks)}")
    print()
if bad:
    print(f"WARNING: {bad} unparseable line(s) in {path}")
PY
      exit 0
    fi

    ws="$REPO_ROOT/$PROFILE"
    [[ -d "$ws" ]] || fail "Workspace does not exist: $ws"

    dep_osv=0; dep_vulns=0; dep_fmt="md"; dep_failon="warn"
    for a in "$@"; do
      case "$a" in
        --osv)     dep_osv=1 ;;
        --vulns)   dep_vulns=1 ;;
        --json)    dep_fmt="json" ;;
        --strict)  dep_failon="fail" ;;
        --quiet)   dep_failon="never" ;;
        *) fail "Unknown flag for deps: $a
      Usage: scripts/profile.sh $PROFILE deps [--osv] [--vulns] [--json] [--strict|--quiet]
             scripts/profile.sh $PROFILE deps --history [N]" ;;
      esac
    done

    # --- uv audit: KNOWN-VULNERABILITY scan. Separate, labelled, NON-GATING --
    #
    # ADR-0002 refused `osv-scanner` ("a Go binary to avoid writing a urllib
    # POST") and a local OSV mirror (~240k records to keep fresh). BOTH refusals
    # were priced on COST, and that cost is now zero: `uv audit` ships in the uv
    # this repo already installs on the host and bakes into the image, reads
    # uv.lock directly, needs no new binary, no vendored corpus and no API key.
    # It caches the OSV data it fetches under ~/.cache/uv/osv-v0/.
    #
    # WHAT DID NOT CHANGE is depaudit's report design: it reports MAL- records
    # only, because GHSA-/PYSEC-/CVE- answer a different question, and mixing
    # them is how a supply-chain gate becomes a CVE treadmill nobody reads. That
    # reasoning is intact, so this section is walled off from it:
    #   * opt-in (--vulns), never part of a bare `deps`, which stays offline;
    #   * printed under its own heading, never merged into depaudit's counts;
    #   * it does NOT touch dep_rc — a CVE in a transitive dependency is not the
    #     same event as a malicious package, and must not fail the same command;
    #   * it never gates tier-1 `verify`, which is offline by contract.
    #
    # HOST-SIDE ONLY, and that is load-bearing: api.osv.dev is deliberately
    # absent from proxy/allowed_domains.txt, and ADR-0002 banked "zero new
    # egress surface" as a consequence of its refusals. Running this inside a
    # profile would spend exactly that. Adding osv.dev to the allowlist is not
    # the answer to anything here.
    #
    # --ignore-until-fixed is what keeps such a section survivable rather than
    # permanently red: it suppresses an ID only while no fix exists, so the
    # finding returns by itself the day one lands — unlike a plain --ignore,
    # which is forever. Every entry below is one ID plus the reason it is
    # ignored; an entry with no reason is not a decision, it is a silence.
    UV_AUDIT_IGNORE=(
      # (empty — nothing is being suppressed today)
    )
    run_uv_audit() {  # <root> <label>
      local uroot="$1" ulabel="$2" uargs=() uid
      [[ -f "$uroot/uv.lock" ]] || { info "uv audit: $ulabel — skipped, no uv.lock (a skip is not a pass)"; return 0; }
      command -v uv >/dev/null 2>&1 || { warn "uv audit: uv not found on the host — skipped (a skip is not a pass)"; return 0; }
      for uid in ${UV_AUDIT_IGNORE[@]+"${UV_AUDIT_IGNORE[@]}"}; do
        uargs+=(--ignore-until-fixed "$uid")
      done
      printf '\n%s\n' "---- uv audit (known vulnerabilities) — $ulabel ----"
      printf '%s\n' "     NON-GATING and separate from depaudit's malicious-package verdict."
      if (( ${#UV_AUDIT_IGNORE[@]} > 0 )); then
        printf '%s\n' "     ignored-until-fixed: ${UV_AUDIT_IGNORE[*]}"
      fi
      # --frozen: audit what the lockfile SAYS, never re-resolve. A scan that
      # silently relocks is reporting on a tree that does not exist yet.
      ( cd "$uroot" && uv audit --frozen ${uargs[@]+"${uargs[@]}"} ) || true
    }

    # A profile's workspace holds MANY repos (docker-compose.yml: "the profile's
    # repo parent folder = /workspace"). depaudit is root-scoped by design, so
    # iterate: the workspace root, plus each repo under it that carries a
    # manifest.
    #
    # Enumeration lives in depaudit's `roots` (work/0018), NOT here. What it
    # replaced asked only "does a manifest sit at this child's root?", which
    # silently omitted any repo whose manifest sits one level down (upstream's
    # case there was a vendored tree holding the largest dependency surface in
    # the workspace, missed for the whole life of the subcommand — see
    # windows-ai-sandbox ccf27a3, ported with this). Two reasons it moved:
    # the vendored-tree exclusion is now
    # depaudit's own skipped(), so it cannot drift from the one the checks use;
    # and the enumeration is testable offline in depaudit.test.sh.
    dep_roots=""
    dep_skipped=""
    # Captured, not piped: an enumeration that CRASHES must not read as "no
    # manifests here" — that is the same under-report in a different disguise.
    dep_rows=$(python3 "$da" roots "$ws") \
      || fail "depaudit roots failed for $ws — enumeration is not optional"
    while IFS=$'\t' read -r dep_verdict dep_path dep_reason; do
      case "$dep_verdict" in
        SCAN) dep_roots="$dep_roots $dep_path" ;;
        SKIP) dep_skipped="${dep_skipped}${dep_path#"$ws"/}|$dep_reason
" ;;
      esac
    done <<< "$dep_rows"
    [[ -n "${dep_roots// /}" ]] || { warn "No manifests found under $ws"; exit 0; }

    dep_rc=0
    dep_summary=""
    for r in $dep_roots; do
      rel="${r#$REPO_ROOT/}"
      [[ "$dep_fmt" == "md" ]] && info "depaudit posture: $rel"
      dep_out=$(python3 "$da" posture "$r" --format "$dep_fmt" --fail-on "$dep_failon") || dep_rc=1
      printf '%s\n' "$dep_out"
      if [[ "$dep_fmt" == "md" ]]; then
        counts=$(printf '%s\n' "$dep_out" | grep -m1 '^| FAIL ' | tr -d '|' | tr -s ' ')
        dep_summary="${dep_summary}${rel}|${counts}
"
      fi
      if [[ "$dep_osv" -eq 1 ]]; then
        [[ "$dep_fmt" == "md" ]] && info "depaudit OSV malicious-package check: $rel"
        osv_out=$(python3 "$da" deps "$r" --format "$dep_fmt") || dep_rc=1
        printf '%s\n' "$osv_out"
        if [[ "$dep_fmt" == "md" ]]; then
          blocked=$(printf '%s\n' "$osv_out" | grep -c '^\- \*\*\[BLOCK\]' || true)
          [[ "${blocked:-0}" -gt 0 ]] && dep_summary="${dep_summary}${rel}|  OSV BLOCK ${blocked}
"
        fi
      fi
      # Deliberately outside the --json path: this is uv's own text output, not
      # depaudit's schema, and splicing a foreign format into --json would make
      # the JSON unparseable for anything consuming it.
      if [[ "$dep_vulns" -eq 1 && "$dep_fmt" == "md" ]]; then
        run_uv_audit "$r" "$rel"
      fi
    done

    # A nine-repo workspace produces nine reports; without a roll-up the reader
    # has to scroll and diff them by eye, which is how a FAIL gets missed.
    if [[ "$dep_fmt" == "md" && -n "$dep_summary" ]]; then
      printf '\n%s\n' "=========================================================="
      printf '%s\n' "SUMMARY — $PROFILE workspace ($REPO_ROOT/$PROFILE)"
      printf '%s\n' "=========================================================="
      printf '%s' "$dep_summary" | while IFS='|' read -r name counts; do
        [[ -z "$name" ]] && continue
        printf '  %-32s %s\n' "$name" "$counts"
      done
      printf '%s\n' "----------------------------------------------------------"
      if [[ -n "$dep_skipped" ]]; then
        printf '%s\n' "  NOT SCANNED — a skip is not a pass:"
        printf '%s' "$dep_skipped" | while IFS='|' read -r name reason; do
          [[ -z "$name" ]] && continue
          printf '  %-32s %s\n' "$name" "$reason"
        done
        printf '%s\n' "----------------------------------------------------------"
      fi
      printf '%s\n' "  scanned $(printf '%s' "$dep_roots" | wc -w) repo root(s), skipped $(printf '%s' "$dep_skipped" | grep -c . || true)."
      printf '%s\n' "  depaudit is READ-ONLY and reports on configuration; it does"
      printf '%s\n' "  not enforce anything. FAIL = a control that is absent, not"
      printf '%s\n' "  a vulnerability. Fixes belong in the repo it names."
      if [[ "$dep_vulns" -eq 1 ]]; then
        printf '%s\n' "  uv audit ran separately above and is NOT counted here: a known"
        printf '%s\n' "  CVE is a different question from a missing control, and from a"
        printf '%s\n' "  malicious package. Its findings gate nothing."
      else
        printf '%s\n' "  Known vulnerabilities were NOT checked. Add --vulns (host-side,"
        printf '%s\n' "  needs network) to run uv audit alongside this."
      fi
    fi
    exit "$dep_rc"
    ;;

  wipe)
    # Blank-slate this profile while preserving auth tokens + git identity.
    # Use case: testing the stack from a clean state without re-doing OAuth.
    # Preserves: claude-home/.credentials.json, claude.json, config/gh/,
    #            config/git/, gemini-home/oauth_creds.json,
    #            db.env (DB superuser credentials — preserved even with
    #            --all-volumes; rm it yourself if you want fresh creds),
    #            secrets.env (third-party API tokens, same rule).
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
    echo "    $p/config/git/"
    echo "    $p/gemini-home/oauth_creds.json"
    echo "    $p/db.env  (if present)"
    echo "    $p/secrets.env  (if present)"
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
    [[ -d "$p/config/git" ]]                 && mv "$p/config/git"                 "$stage/config/git"
    [[ -f "$p/gemini-home/oauth_creds.json" ]] && mv "$p/gemini-home/oauth_creds.json" "$stage/gemini-home/oauth_creds.json"
    [[ -f "$p/db.env" ]]                       && mv "$p/db.env"                       "$stage/db.env"
    [[ -f "$p/secrets.env" ]]                  && mv "$p/secrets.env"                  "$stage/secrets.env"
    ok "staged auth artefacts → $stage"

    # 3. Nuke the profile dir.
    rm -rf "$p"
    ok "removed $p"

    # 4. Restore auth into a fresh profile dir.
    mkdir -p "$p/claude-home" "$p/config" "$p/gemini-home"
    [[ -f "$stage/claude.json" ]]                && mv "$stage/claude.json"                "$p/claude.json"
    [[ -f "$stage/claude-home/.credentials.json" ]] && mv "$stage/claude-home/.credentials.json" "$p/claude-home/.credentials.json"
    [[ -d "$stage/config/gh" ]]                  && mv "$stage/config/gh"                  "$p/config/gh"
    [[ -d "$stage/config/git" ]]                 && mv "$stage/config/git"                 "$p/config/git"
    [[ -f "$stage/gemini-home/oauth_creds.json" ]] && mv "$stage/gemini-home/oauth_creds.json" "$p/gemini-home/oauth_creds.json"
    [[ -f "$stage/db.env" ]]                       && mv "$stage/db.env"                       "$p/db.env"
    [[ -f "$stage/secrets.env" ]]                  && mv "$stage/secrets.env"                  "$p/secrets.env"
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
    [[ -f "$p/secrets.env" ]]                   && chmod 600 "$p/secrets.env"
    ok "restored auth artefacts into fresh $p"

    # 6. Re-seed templates (settings.json, skills, db.env.example) so a plain `up` works.
    ensure_state
    ok "re-seeded settings + skills from config/"

    ok "wipe done for '$PROFILE'. Next: scripts/profile.sh $PROFILE up"
    ;;

  reset-skills)
    # Convergence without touching the container — the same reconciliation `up`
    # performs, on demand. Since ADR-0005 this no longer "resets with a backup":
    # it MIRRORS the template tree and keeps no backup, because a
    # `<name>.bak.<stamp>` inside the scanned skills directory loads INSTEAD of
    # the fresh copy for a plugin-shaped skill.
    #
    # The name survives its old meaning deliberately. W folded this command into
    # a broader `converge` that also reconciles agent policy; this repo has no
    # converge_agent_policies yet (work/0002 Phase D), so renaming now would
    # leave a command named for something it does not do.
    [[ -d "$SCRIPT_DIR/sandbox_templates/skills" ]] \
      || fail "no skills templates: $SCRIPT_DIR/sandbox_templates/skills"
    converge_skills
    ok "skills converged for '$PROFILE' from sandbox_templates/skills/"
    # THE RESTART LINE IS THE CONTRACT, not a courtesy: a running session has
    # already loaded the old copy and will not re-scan on its own.
    info "restart claude inside the container to pick the new copies up."
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
