# justfile — discoverable front door over scripts/profile.sh + scripts/setup.sh
# =============================================================================
# CONVENIENCE LAYER ONLY. The bash scripts remain canonical (see CLAUDE.md
# "Script layers"). Every recipe is a thin pass-through — it must NOT call
# `docker compose` directly. Both scripts export COMPOSE_PROJECT_NAME and
# PROFILE before invoking compose, and the compose file's `${PROFILE:?...}`
# guard fails fast without them. Reimplementing any logic here would bypass
# that. If you add a command to profile.sh/setup.sh, add the pass-through here.
#
# Profile is the FIRST positional arg to every recipe, mirroring the scripts:
#   just up work            ->  scripts/profile.sh work up
#   just attach work        ->  scripts/profile.sh work attach
#   just verify work        ->  scripts/profile.sh work verify
#   just setup-verify work  ->  scripts/setup.sh   work --verify
#   just setup work --name "W" --email w@x
#
# Exceptions (no profile arg): `list`, `health`, `build` (the image is shared) and
# `dashboard` (host-side ops console);
# the `colima-*` VM-lifecycle recipes
# below — Colima is shared across all profiles, so those front the VM scripts
# (scripts/start.sh, scripts/stop.sh), not profile.sh/setup.sh; and the
# `test-*` recipes, which run host-side offline suites that take no profile and
# need no VM. `code` is a pass-through too, but to scripts/code-attach.sh — a
# host-side VS Code addressing helper that starts nothing. All still thin
# pass-throughs; still no `docker compose`.
# =============================================================================

profile_sh := justfile_directory() / "scripts" / "profile.sh"
setup_sh   := justfile_directory() / "scripts" / "setup.sh"
code_sh    := justfile_directory() / "scripts" / "code-attach.sh"
dash_sh    := justfile_directory() / "scripts" / "dashboard.sh"
vendortools_sh := justfile_directory() / "scripts" / "vendor-tools.sh"

# default: banner + recipe list (a bare `just` lists, never runs a recipe).
_default:
    @echo "macolima — sandbox lifecycle. Canonical scripts: scripts/profile.sh, scripts/setup.sh"
    @echo "Usage: just <recipe> <profile> [args]   (e.g. just up work)"
    @echo
    @just --list

# ---- lifecycle (profile.sh) -------------------------------------------------

# build (if needed) + start the stack for a profile. Accepts --expose-dev.
up profile *args:
    {{profile_sh}} {{profile}} up {{args}}

# stop + remove containers (keeps persistent state)
down profile:
    {{profile_sh}} {{profile}} down

# force-recreate containers — picks up compose/seccomp/proxy/mount/dns changes (no image rebuild)
recreate profile *args:
    {{profile_sh}} {{profile}} recreate {{args}}

# rebuild the image + recreate this profile's containers. Accepts --no-cache / --pull
rebuild profile *args:
    {{profile_sh}} {{profile}} rebuild {{args}}

# force-rebuild the shared image (no profile arg — it's shared).
# Accepts --no-cache / --pull / --refresh-ai / --claude-version=X.Y.Z
build *args:
    {{profile_sh}} build {{args}}

# shell into the agent container (zsh as the agent user)
attach profile:
    {{profile_sh}} {{profile}} attach

# open a container folder in VS Code (`just code therapod engine`; no folder = list; -r reuses window)
code profile *args:
    {{code_sh}} {{profile}} {{args}}

# all containers in this profile's compose project, any state (running + stopped)
status profile *args:
    {{profile_sh}} {{profile}} status {{args}}

# tail container logs
logs profile:
    {{profile_sh}} {{profile}} logs

# run an arbitrary command inside the agent container
exec profile *args:
    {{profile_sh}} {{profile}} exec {{args}}

# dependency posture for a profile's workspace (host-side, read-only)
deps profile *args:
    {{profile_sh}} {{profile}} deps {{args}}

# list all existing profiles (no profile arg)
list:
    {{profile_sh}} list

# cross-profile health: flag any profile whose agent/proxy/DB aren't all up together (no profile arg)
health:
    {{profile_sh}} health

# tier-1 hardening tripwire: allowlist enforcement (host) + verify-sandbox.sh (in-container)
verify profile *args:
    {{profile_sh}} {{profile}} verify {{args}}

# tier-2 structured audit (~85 probes, JSON to the profile's claude-home). Accepts --stage-only / --clean / --compact
audit profile *args:
    {{profile_sh}} {{profile}} audit {{args}}

# ---- control dashboard (host-side Streamlit, no profile arg) ----------------

# launch the ops dashboard on http://127.0.0.1:8501 (Ctrl-C to stop)
dashboard *args:
    {{dash_sh}} {{args}}

# vendor every channel artifact into sandbox_templates/ (hash-gated). Accepts --dry-run
vendor-tools *args:
    {{vendortools_sh}} {{args}}

# is this repo current with the depot channel? (offline; SKIPs loudly when unconfigured)
tools-check:
    {{vendortools_sh}} --check

# dashboard parser + render regression suite (needs dashboard/.venv; no docker required)
test-dashboard:
    {{justfile_directory()}}/dashboard/.venv/bin/python {{justfile_directory()}}/dashboard/tests/test_allowlist_roundtrip.py

# ---- offline test suites (no profile arg, no docker, no network) ------------
# These run on the host with the VM down. They are the only thing standing
# between a silently-inverted check and a green-looking sandbox, so they need a
# front door — before this recipe existed the four suites could only be run by
# remembering four paths, which is how a suite goes quietly red.
#
# `just` aborts the recipe on the first failing line, so a red suite stops the
# run and names itself. Run one directly if you want the rest to continue.

# every offline suite (179 assertions across four files)
test-offline:
    bash {{justfile_directory()}}/sandbox_templates/claude/hooks/deny-destructive.test.sh
    bash {{justfile_directory()}}/scripts/depaudit.test.sh
    bash {{justfile_directory()}}/scripts/with-egress.test.sh
    bash {{justfile_directory()}}/scripts/dockerfile-order.test.sh
    bash {{justfile_directory()}}/scripts/vendor-tools.test.sh

# just the Dockerfile layer-order chain (also included in test-offline)
test-dockerfile:
    bash {{justfile_directory()}}/scripts/dockerfile-order.test.sh

# ---- Colima VM lifecycle (shared across profiles — no profile arg) ----------

# start Colima VM after a reboot (idempotent). Optionally also up a profile: `just colima-up therapod`
colima-up *args:
    {{justfile_directory()}}/scripts/start.sh {{args}}

# stop all running profiles' containers, then the Colima VM (reclaims RAM).
colima-down:
    {{justfile_directory()}}/scripts/stop.sh

# Colima VM status
colima-status:
    colima status

# ---- auth (profile.sh) ------------------------------------------------------

# `claude login` inside the container (one-time per profile)
auth profile:
    {{profile_sh}} {{profile}} auth

# `gh auth login` inside the container
auth-github profile:
    {{profile_sh}} {{profile}} auth-github

# `agy` (Antigravity CLI) inside the container — interactive console sign-in
auth-antigravity profile:
    {{profile_sh}} {{profile}} auth-antigravity

# ---- state management (profile.sh) ------------------------------------------

# prune rotating state (old backups, paste-cache, shell-snapshots). Accepts --deep
clean profile *args:
    {{profile_sh}} {{profile}} clean {{args}}

# wipe per-profile state but KEEP auth. Accepts --dry-run / --yes / --all-volumes
wipe profile *args:
    {{profile_sh}} {{profile}} wipe {{args}}

# wipe the postgres data volume + fresh initdb. Accepts --yes
db-reset profile *args:
    {{profile_sh}} {{profile}} db-reset {{args}}

# overwrite this profile's claude settings.json from config/ (backs up old)
reset-settings profile:
    {{profile_sh}} {{profile}} reset-settings

# overwrite this profile's claude skills from sandbox_templates/skills/ (backs up old)
reset-skills profile:
    {{profile_sh}} {{profile}} reset-skills

# ---- one-shot onboarding / lifecycle flags (setup.sh) -----------------------

# full onboarding for a profile: up + claude + git config + auth.
# e.g. just setup work --name "W" --email w@x
setup profile *args:
    {{setup_sh}} {{profile}} {{args}}

# onboarding sanity block (auth status, mounts, git config) and exit
setup-verify profile:
    {{setup_sh}} {{profile}} --verify

# docker compose restart (via setup.sh lifecycle flag)
restart profile:
    {{setup_sh}} {{profile}} --restart

# docker compose down, keeping persistent state (via setup.sh lifecycle flag)
remove profile:
    {{setup_sh}} {{profile}} --remove

# WIPE profile state dir + fresh setup (requires --yes + --name/--email). e.g.
# just reset work --yes --name "W" --email w@x
reset profile *args:
    {{setup_sh}} {{profile}} --reset {{args}}
