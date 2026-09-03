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
#   recreate-all    force-recreate EVERY running profile onto the current image
#                   (no profile arg; down profiles are skipped)
#                   shared by every profile). Flags: --no-cache, --pull,
#                   --refresh-ai (rebuild just the Claude Code + agy tail layer),
#                   --claude-version=X.Y.Z (pin claude; implies --refresh-ai).
#   recreate        force-recreate this profile's containers (no image rebuild — picks up
#                   compose / seccomp / proxy / mount changes). Equivalent to
#                   `setup.sh <p> --recreate` (which is the flag-style alias).
#   rebuild         build + recreate this profile's containers
#   converge        re-run everything `up` seeds: every agent's policy + skills, from
#                   sandbox_templates/. Touches no container. --defaults also resets
#                   preserved preference keys to the template defaults.
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
# shared with the user's own projects (e.g. macolima-myproject-pipeline-api) as
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
# --- `recreate-all` — force-recreate every RUNNING profile (no profile arg) --
# Rolls every live profile onto the current macolima:latest image. Use after
# `build` to adopt a new image without a manual per-profile loop — which is what
# every `just build` in this repo has ended with until now.
#
# DOWN PROFILES ARE SKIPPED, not started. They pick the new image up on their
# next `up`, and starting a profile the operator deliberately stopped would be a
# side effect of a command that says "recreate", not "start".
#
# Container names here are `claude-agent-<profile>`, not the sibling repo's
# `ai-sandbox-<profile>`; the egress-proxy and DB siblings are ignored because a
# profile is identified by its agent.
#
# Extra args (e.g. --expose-dev) are forwarded to each `recreate`.
if [[ "${1:-}" == "recreate-all" ]]; then
  running=()
  while IFS= read -r cname; do
    case "$cname" in claude-agent-*) running+=("${cname#claude-agent-}") ;; esac
  done < <(docker ps --format '{{.Names}}' 2>/dev/null | sort)
  if (( ${#running[@]} == 0 )); then
    warn "No running profiles (no claude-agent-* containers up). Nothing to recreate."
    warn "  A profile that is DOWN picks up the new image on its next 'up'."
    exit 0
  fi
  info "Recreating ${#running[@]} running profile(s): ${running[*]}"
  rc=0
  for p in "${running[@]}"; do
    info "── recreate '$p' ──"
    "$0" "$p" recreate "${@:2}" || { rc=1; warn "recreate failed for '$p' (continuing)"; }
  done
  if (( rc == 0 )); then
    ok "recreate-all done (${#running[@]} profile(s))."
  else
    warn "recreate-all finished with errors — see above."
  fi
  exit "$rc"
fi

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
  # A missing template tree is not fatal — `converge` also converges agent
  # policy, and failing the whole command would skip that. But it must not be
  # SILENT either: a bare `return 0` here would make a broken checkout look like
  # a clean converge, and pruning nothing is indistinguishable from having
  # nothing to prune. Say so and carry on.
  if [[ ! -d "$src" ]]; then
    warn "no skills templates at $src — skills NOT converged (nothing pruned either)"
    return 0
  fi
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

# =============================================================================
# Agent policy convergence — ONE function, ONE descriptor table (work/0011)
# =============================================================================
#
# Every code agent in this image keeps its tool policy in a JSON file inside the
# profile's state dir. Until 2026-08-24 each one reached a profile by a different
# route, and the most security-relevant of them — Claude Code's 96-rule deny
# list — reached it by the route that is a no-op: seeded CREATE-ONLY, so a
# template edit landed in git and nowhere else until someone remembered a
# `reset-*` command. That is precisely the failure ADR-0005 was written about,
# never applied to the file where it matters most. Now every agent converges on
# every `up`/`recreate`/`rebuild`/`wipe`, and adding an agent is a ROW here, not
# a new code path (ADR-0007).
#
# TWO MODES, and which one an agent gets is decided by ONE rule:
#
#   Overwrite where the agent has somewhere else to put its preferences.
#   Merge where it does not.
#
#   claude       -> OVERWRITE. Nearly everything Claude Code writes back
#                   (model, effortLevel, theme, agentPushNotifEnabled,
#                   statusLine) is settable in a repo's own
#                   .claude/settings.local.json, so the live file can simply BE
#                   the template — which is stronger than merge: a future
#                   release putting something security-relevant in a key we do
#                   not own is enforced rather than silently preserved.
#                   The exception rides the preserve list; see below.
#   antigravity  -> MERGE. `agy` has NO in-repo permission or preference
#                   surface at all (work/0011 F3), and what it stores in that
#                   file — colorScheme, model, enableTelemetry,
#                   trustedWorkspaces — is functional state, not a preference.
#                   Overwriting it is data loss with nowhere to restore from.
#   opencode     -> OVERWRITE when it lands (0009): it never writes to
#                   opencode.json; its TUI prefs live in a separate tui.json.
#
# PRESERVE LIST — the mode rule applied per key. Four keys, owner-decided
# 2026-08-24 (work/0011 F6, ADR-0007):
#
#   skipAutoPermissionPrompt   user-or-managed scope: it CANNOT be set in a repo
#                              file, so dropping it leaves the user nowhere to
#                              restore it and the one-time auto-mode notice
#                              returns forever.
#   model, effortLevel,        settable per-repo, but the agent rewrites them
#   agentPushNotifEnabled      every session and re-picking them after every
#                              `up` is friction with no security value.
#
# PRESERVE HAS TWO HALVES and both matter. A live value SURVIVES convergence.
# When the live file LACKS the key — a fresh bootstrap, or a profile whose keys
# an earlier converge dropped — the TEMPLATE DEFAULT seeds it. That is why the
# three preference keys now live in claude-settings.json at all: without a
# template value, "preserve" on a bootstrapped profile means "leave it unset",
# and the operator picks model/effort by hand in every new profile forever.
#
# The seeded defaults are opinionated and deliberately so: "opus" (NOT a
# variant-suffixed id — the suffix pins a context window this repo has no
# opinion about), "medium", and push notifications OFF.
#
# `converge --defaults` inverts the first half for one run: the template value
# overwrites the live one for EVERY key here, skipAutoPermissionPrompt
# included. It is the opt-out for "this profile's preferences drifted somewhere
# I do not want" — and it still captures what it replaced, because a reset the
# operator cannot undo is the same silent loss the capture exists to prevent.
#
# Keep this list to keys the sandbox has no security opinion about — every
# entry is a hole in "the live file IS the template".
#
# NOT a directory mirror, in either mode. converge_skills MIRRORS (ADR-0005),
# and applying that here would be data loss: gemini-home/config/ holds
# config.json, mcp_config.json, .migrated and projects/, all live `agy` state no
# template will ever contain. File-scoped, always — the offline suite locks it.
#
# Row format:  agent|template (repo-relative)|dest (profile-relative)|mode|owned keys|preserve keys
AGENT_POLICY_DESCRIPTORS=(
  # PRESERVE LIST: windows-ai-sandbox's four, plus four measured here. The rule
  # is theirs — preserve where the agent has nowhere ELSE to put a preference —
  # applied to what this repo's agents actually write:
  #   skipWorkflowUsageWarning, tui   2026-09-01 audit, in a live settings.json
  #   theme, modelSettings            first real converge, 2026-09-03: both were
  #                                   DROPPED from two profiles (theme=dark,
  #                                   modelSettings={claude-opus-5:{effortLevel:
  #                                   xhigh}}).
  # A repo's .claude/settings.local.json is not the alternative home for these:
  # they are GLOBAL UI preferences, so "put it back per-repo" means re-setting it
  # in every repo forever. None is a permission, so preserving them widens
  # nothing — the owned list (env hooks permissions sandbox) is what enforcement
  # compares, and it is untouched.
  "claude|sandbox_templates/claude/claude-settings.json|claude-home/settings.json|overwrite|env hooks permissions sandbox|skipAutoPermissionPrompt model effortLevel agentPushNotifEnabled skipWorkflowUsageWarning tui theme modelSettings"
  "antigravity|sandbox_templates/antigravity/antigravity-settings.json|gemini-home/antigravity-cli/settings.json|merge|permissions toolPermission|"
)

# converge_agent_policy <agent> <src> <dst> <mode> "<owned keys>" "<preserve keys>"
#
# Writes only when the result differs (it runs on EVERY up — churning the file
# would fight the running agent for no reason), writes atomically (.tmp +
# os.replace), and REFUSES a dst that exists but is not valid JSON: a corrupt
# policy file is the agent's to report, not ours to silently replace, and its
# other keys may still be recoverable by hand.
#
# Under `overwrite` the loss has to be VISIBLE, and that is most of this
# function:
#
#   1. Every key the template does not own is written to
#      claude-home/settings.discarded.json BEFORE the overwrite — recoverable
#      from disk, not from scrollback, and present even on the silent runs.
#      That directory is inside the container mount, so the file is
#      agent-writable: it is recovery capture, NOT audit evidence. The
#      authoritative drift signal is the tier-1 check in `verify`.
#   2. The capture includes the content diff of any OWNED key that differs.
#      Top-level capture alone misses a change INSIDE an owned key, and that is
#      the case that actually happened: an in-session "Yes, and don't ask again"
#      lands an allow rule in `permissions` — the single most sandbox-owned key
#      in the repo — which the overwrite reverts. Silent reversion is the exact
#      failure this whole item exists to prevent (measured live, 2026-08-24).
#   3. The warning fires ONLY when the captured SIGNATURE changes: the set of
#      dropped key names plus a digest of the owned-key diffs. Claude rewrites
#      `model` and `effortLevel` every session, so an unconditional warning
#      fires on every `up` forever and stops being read — going quiet in the
#      reader's head exactly when a genuinely new key appears. Values are noise;
#      a NEW dropped key, or ANY change inside an owned key, is signal.
#
# Requirement 3 subsumes the "unexpected top-level key" detector: a key a future
# Claude release invents surfaces as a dropped key on the next `up`.
converge_agent_policy() {
  local agent="$1" src="$2" dst="$3" mode="$4" owned="$5" preserve="${6:-}"
  local defaults="${POLICY_DEFAULTS:-0}"
  [[ -f "$src" ]] || return 0
  mkdir -p "$(dirname "$dst")"
  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 absent — cannot converge the $agent policy into $dst"
    return 0
  fi

  local out
  if ! out=$(AGENT="$agent" SRC="$src" DST="$dst" MODE="$mode" \
             OWNED="$owned" PRESERVE="$preserve" DEFAULTS="$defaults" python3 - <<'PY'
import hashlib, json, os, sys

agent = os.environ["AGENT"]
src, dst = os.environ["SRC"], os.environ["DST"]
mode = os.environ["MODE"]
owned = os.environ["OWNED"].split()
preserve = os.environ["PRESERVE"].split()
use_defaults = os.environ.get("DEFAULTS") == "1"

def emit(kind, msg):
    sys.stdout.write("%s:%s\n" % (kind, msg))

tpl = json.load(open(src))
live = {}
if os.path.exists(dst) and os.path.getsize(dst):
    try:
        live = json.load(open(dst))
    except Exception:
        # A corrupt policy file is the agent's problem to report, not ours to
        # silently replace — its other keys may still be recoverable by hand.
        emit("warn", "%s policy at %s is not valid JSON — leaving it alone" % (agent, dst))
        raise SystemExit(0)
if not isinstance(live, dict):
    emit("warn", "%s policy at %s is not a JSON object — leaving it alone" % (agent, dst))
    raise SystemExit(0)

before = json.dumps(live, sort_keys=True)

def strip_doc(o):
    """Drop '_'-prefixed annotation keys. JSON has no comments, so the templates
    carry '_comment'/'_*_note' keys instead; no agent ever writes one, so they
    are never a real diff."""
    if isinstance(o, dict):
        return {k: strip_doc(v) for k, v in o.items() if not k.startswith("_")}
    if isinstance(o, list):
        return [strip_doc(v) for v in o]
    return o

if mode == "merge":
    result = dict(live)
    for k in owned:
        if k in tpl:
            result[k] = tpl[k]
elif mode == "overwrite":
    result = json.loads(json.dumps(tpl))
    # PRESERVE, both halves. A live value wins over the template; a key the live
    # file does not carry falls through to the template default (that is the
    # `result` copy above, so it needs no branch here). `--defaults` skips the
    # first half — the template default wins for every preserved key — and
    # records what it replaced, so the reset is recoverable like any other loss.
    pref_resets = {}
    for k in preserve:
        if k not in live:
            continue
        if use_defaults:
            if k not in tpl:
                # No default to reset TO. Dropping it here would be a silent
                # one-way loss of a key with nowhere else to live, so treat the
                # absence of a template value as "nothing to reset".
                result[k] = live[k]
            elif live[k] != tpl[k]:
                pref_resets[k] = {"was_live": live[k], "now_template": tpl[k]}
        else:
            result[k] = live[k]

    dropped = {k: v for k, v in live.items()
               if k not in tpl and k not in preserve}
    owned_changes = {}
    for k in owned:
        if k in live and strip_doc(live[k]) != strip_doc(tpl.get(k)):
            owned_changes[k] = {"was_live": live[k], "now_template": tpl.get(k)}

    discard = os.path.join(os.path.dirname(dst), "settings.discarded.json")
    sig = {
        "dropped_keys": sorted(dropped),
        "owned_diff": hashlib.sha256(
            json.dumps(owned_changes, sort_keys=True).encode()).hexdigest()[:16],
        # A --defaults reset is an EXPLICIT operator action, so unlike the other
        # two it must never be silenced by a matching previous signature: the
        # digest carries the replaced VALUES, not just the key names.
        "pref_reset": hashlib.sha256(
            json.dumps(pref_resets, sort_keys=True, default=str).encode()).hexdigest()[:16],
    }
    prev_sig = None
    if os.path.exists(discard):
        try:
            prev_sig = json.load(open(discard)).get("_signature")
        except Exception:
            prev_sig = None

    # Write ONLY when there is something to record AND it is new. Two halves,
    # both load-bearing:
    #   "something to record" — a clean run must not blank the file. The run
    #   right after a converge drops nothing (the live file IS the template
    #   until the agent next writes to it), so clearing on empty would give the
    #   operator exactly one `up` to notice a captured grant before the record
    #   of it vanished. The file is the last ACTUAL discard, not the last run.
    #   "and it is new" — see the signature comment above.
    if (dropped or owned_changes or pref_resets) and sig != prev_sig:
        record = {
            "_comment": (
                "Keys the %s policy convergence did NOT keep, captured before the "
                "overwrite that dropped them. RECOVERY CAPTURE, not audit evidence: "
                "this file lives inside the container mount and the agent can write "
                "it. The authoritative drift signal is `scripts/profile.sh <p> "
                "verify`. Rewritten whenever the captured set changes; see "
                "docs/permissions-model.md for where each key can be put back."
            ) % agent,
            "agent": agent,
            "template": src,
            "dropped": dropped,
            "owned_key_changes": owned_changes,
            "preference_resets": pref_resets,
            "_signature": sig,
        }
        tmp = discard + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(record, fh, indent=2, default=str)
            fh.write("\n")
        os.replace(tmp, discard)
        if dropped:
            emit("warn", "%s policy converge DISCARDED %d key(s) the template does not own: %s"
                 % (agent, len(dropped), ", ".join(sorted(dropped))))
        for k in sorted(owned_changes):
            emit("warn", "%s policy converge REVERTED the sandbox-owned key '%s' to the template "
                         "(an in-session grant does not survive converge — edit the template to keep it)"
                 % (agent, k))
        for k in sorted(pref_resets):
            emit("warn", "%s policy converge --defaults RESET the preference '%s' to the template "
                         "default (%r, was %r)"
                 % (agent, k, pref_resets[k]["now_template"], pref_resets[k]["was_live"]))
        emit("warn", "captured in %s" % discard)
        emit("info", "put a preference back per-repo in <repo>/.claude/settings.local.json "
                     "(model/effortLevel/theme/statusLine/agentPushNotifEnabled live there) — "
                     "but a repo file can only TIGHTEN permissions, never re-allow what the "
                     "sandbox denies, and never promote an `ask` to `allow`")
else:
    emit("warn", "unknown convergence mode '%s' for %s — refusing to guess" % (mode, agent))
    raise SystemExit(0)

if json.dumps(result, sort_keys=True) != before:
    tmp = dst + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(result, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, dst)
    emit("changed", dst)
PY
  ); then
    warn "could not converge the $agent policy into $dst"
    return 0
  fi

  local line
  while IFS= read -r line; do
    case "$line" in
      warn:*)    warn "${line#warn:}" ;;
      info:*)    info "${line#info:}" ;;
      changed:*) : ;;
    esac
  done <<< "$out"
}

# converge_antigravity_hooks — the ONE whole-file extra in the descriptor table.
#
# gemini-home/config/hooks.json is replaced wholesale: nothing but the sandbox
# writes it. Its SIBLINGS in that directory are not ours at all, which is why
# this copies one file and never mirrors the tree.
converge_antigravity_hooks() {
  local tdir="$SCRIPT_DIR/sandbox_templates/antigravity"
  local dst="$PROFILES_ROOT/$PROFILE/gemini-home/config/hooks.json"
  [[ -f "$tdir/hooks.json" ]] || return 0
  mkdir -p "$(dirname "$dst")"
  cmp -s "$tdir/hooks.json" "$dst" 2>/dev/null || cp "$tdir/hooks.json" "$dst"
}

# converge_agent_policies [--defaults] — every descriptor, plus the whole-file
# extras. This is what `up`, `recreate`, `rebuild`, `wipe` and `converge` all
# run. `--defaults` is the opt-out described on the preserve list above and is
# only ever passed by `converge` — the lifecycle commands must never reset an
# operator's preferences behind their back.
converge_agent_policies() {
  local p="$PROFILES_ROOT/$PROFILE"
  local POLICY_DEFAULTS=0 a
  for a in "$@"; do [[ "$a" == "--defaults" ]] && POLICY_DEFAULTS=1; done
  converge_antigravity_hooks
  local row agent src dst mode owned preserve
  for row in "${AGENT_POLICY_DESCRIPTORS[@]}"; do
    IFS='|' read -r agent src dst mode owned preserve <<< "$row"
    converge_agent_policy "$agent" "$SCRIPT_DIR/$src" "$p/$dst" "$mode" "$owned" "$preserve"
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
  # EVERY agent's policy converges on every `up` (ADR-0007), by one function and
  # one descriptor table. Claude's settings.json used to be seeded create-only
  # right here — which meant the most security-relevant file in the repo was the
  # one thing that silently lagged its template, the exact failure ADR-0005 was
  # written about, never applied where it matters most.
  converge_agent_policies
  # Refresh the managed sandbox-notice in the agent's GLOBAL memory
  # (~/.claude/CLAUDE.md, auto-loaded every session) so agents see the
  # capabilities and prohibitions even in a workspace repo whose own AGENTS.md
  # has not been synced. Rewrites only the marked block, idempotently.
  if [[ -f "$SCRIPT_DIR/scripts/sync-agent-notice.sh" ]]; then
    bash "$SCRIPT_DIR/scripts/sync-agent-notice.sh" "$p/claude-home/CLAUDE.md" >/dev/null \
      || warn "could not sync sandbox-notice into $p/claude-home/CLAUDE.md"
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
# check_agent_policy_sync — tier-1 drift detector for every agent's policy.
#
# HOST-SIDE for the same reason check_allowlist_sync is: verify-sandbox.sh is
# streamed into the AGENT container, which cannot see this repo (the sandbox
# repo is not bind-mounted into /workspace), so it has no template to compare
# against. Only the host has both halves.
#
# Nothing reported a profile lagging its policy template before 2026-08-24 —
# which is how the 96-rule Claude deny list sat in the template and in none of
# the three live profiles for five days, undetected. Convergence on `up` is the
# fix; this is the check that says convergence actually happened.
#
# OWNED KEYS ONLY, deliberately. Comparing whole files would fire on `model`
# and `effortLevel` — which the agent rewrites every session — and a check that
# fires on every run is a check that gets trained away. '_'-prefixed annotation
# keys are stripped for the same reason: no agent writes one.
#
# The preserved keys are NOT owned keys, and since 2026-08-24 the template
# carries defaults for three of them. A live `model` that differs from the
# template default is the preserve list working exactly as designed, so it must
# not trip this check — which it cannot, because `owned` never names them.
check_agent_policy_sync() {
  local p="$PROFILES_ROOT/$PROFILE"
  local row agent src dst mode owned preserve
  command -v python3 >/dev/null 2>&1 || { warn "python3 absent — cannot check agent policy drift"; return 0; }
  local rc=0
  for row in "${AGENT_POLICY_DESCRIPTORS[@]}"; do
    IFS='|' read -r agent src dst mode owned preserve <<< "$row"
    [[ -f "$SCRIPT_DIR/$src" ]] || continue
    if [[ ! -s "$p/$dst" ]]; then
      printf '\033[0;31m[FAIL]\033[0m  %s policy missing from this profile: %s\n' "$agent" "$p/$dst" >&2
      printf '        fix: scripts/profile.sh %s converge\n' "$PROFILE" >&2
      rc=1; HOST_FAILS=$(( ${HOST_FAILS:-0} + 1 )); continue
    fi
    local delta
    if delta=$(SRC="$SCRIPT_DIR/$src" DST="$p/$dst" OWNED="$owned" python3 - <<'PY2'
import json, os, sys
def strip(o):
    if isinstance(o, dict):
        return {k: strip(v) for k, v in o.items() if not k.startswith("_")}
    if isinstance(o, list):
        return [strip(v) for v in o]
    return o
tpl = json.load(open(os.environ["SRC"]))
try:
    live = json.load(open(os.environ["DST"]))
except Exception:
    print("live policy is not valid JSON")
    raise SystemExit(1)
bad = [k for k in os.environ["OWNED"].split()
       if k in tpl and strip(live.get(k)) != strip(tpl[k])]
if bad:
    print("sandbox-owned key(s) differ from the template: " + ", ".join(bad))
    raise SystemExit(1)
PY2
    ); then
      ok "$agent policy matches its template on the sandbox-owned keys ($owned)"
    else
      printf '\033[0;31m[FAIL]\033[0m  %s policy DRIFT in %s\n' "$agent" "$p/$dst" >&2
      printf '        %s\n' "$delta" >&2
      printf '        fix: scripts/profile.sh %s converge   (then restart the agent in the container)\n' "$PROFILE" >&2
      rc=1; HOST_FAILS=$(( ${HOST_FAILS:-0} + 1 ))
    fi
  done
  return "$rc"
}

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
       an existing profile's overlay for the canonical shape."
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
    # still need their COMPOSE_PROFILE enabled to appear — for a postgres profile that's
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
    # Same reason, same place: the streamed script runs INSIDE the agent, which
    # cannot see this repo, so it has no template to compare a policy against.
    check_agent_policy_sync || verify_rc=1

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

  converge)
    # ONE reset, replacing reset-settings and reset-skills (ADR-0007). Those two
    # were near-identical commands with different semantics — one overwrote with
    # a backup, one mirrored — and that confusion is what let the Claude policy
    # sit behind its template. Removed outright rather than aliased.
    #
    # Runs exactly what `up` runs and touches NO container, except for
    # --defaults, which `up` never passes: it additionally overwrites the
    # PRESERVED preference keys with the template defaults instead of keeping
    # the live values, capturing what it replaced to settings.discarded.json.
    converge_agent_policies "$@"
    converge_skills
    if [[ -f "$SCRIPT_DIR/scripts/sync-agent-notice.sh" ]]; then
      bash "$SCRIPT_DIR/scripts/sync-agent-notice.sh" \
        "$PROFILES_ROOT/$PROFILE/claude-home/CLAUDE.md" >/dev/null \
        || warn "could not sync sandbox-notice into claude-home/CLAUDE.md"
    fi
    case " $* " in
      *" --defaults "*) ok "policy + skills converged for '$PROFILE' from sandbox_templates/ (preferences RESET to template defaults)" ;;
      *)                ok "policy + skills converged for '$PROFILE' from sandbox_templates/" ;;
    esac
    # THE RESTART LINE IS THE CONTRACT, not a courtesy. Converging under a live
    # session is a lost-update race in BOTH directions: the session holds its
    # settings in memory and can write them back over the converge, and the
    # converge can revert a grant the session just made.
    info "restart claude (and agy) inside the container to pick this up."
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
