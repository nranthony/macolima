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
#   just verify work        ->  scripts/setup.sh   work --verify
#   just setup work --name "W" --email w@x
#
# Exceptions (no profile arg): `list`, and the `colima-*` VM-lifecycle recipes
# below — Colima is shared across all profiles, so those front the VM scripts
# (scripts/start.sh, scripts/stop.sh), not profile.sh/setup.sh. Still thin
# pass-throughs; still no `docker compose`.
# =============================================================================

profile_sh := justfile_directory() / "scripts" / "profile.sh"
setup_sh   := justfile_directory() / "scripts" / "setup.sh"

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

# force-rebuild the shared image (profile arg required but unused). Accepts --no-cache / --pull
build profile *args:
    {{profile_sh}} {{profile}} build {{args}}

# shell into the agent container (zsh as the agent user)
attach profile:
    {{profile_sh}} {{profile}} attach

# tail container logs
logs profile:
    {{profile_sh}} {{profile}} logs

# run an arbitrary command inside the agent container
exec profile *args:
    {{profile_sh}} {{profile}} exec {{args}}

# list all existing profiles (no profile arg)
list:
    {{profile_sh}} list

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

# `glab auth login` inside the container
auth-gitlab profile:
    {{profile_sh}} {{profile}} auth-gitlab

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

# overwrite this profile's claude skills from config/skills/ (backs up old)
reset-skills profile:
    {{profile_sh}} {{profile}} reset-skills

# ---- one-shot onboarding / lifecycle flags (setup.sh) -----------------------

# full onboarding for a profile: up + claude + git config + auth.
# e.g. just setup work --name "W" --email w@x
setup profile *args:
    {{setup_sh}} {{profile}} {{args}}

# sanity checks (auth status, mounts, git config) and exit
verify profile:
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
