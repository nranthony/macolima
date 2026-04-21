#!/usr/bin/env bash
# =============================================================================
# setup.sh — first-time profile setup and lifecycle operations
# =============================================================================
# Wraps profile.sh into higher-level flows. Use this for onboarding a new
# profile in one shot, or for common lifecycle actions (restart, recreate,
# remove, reset) without having to remember the subcommands.
#
# USAGE
#   scripts/setup.sh <profile> --name "Name" --email "you@x.com" [flags]
#   scripts/setup.sh <profile> --restart | --recreate | --remove | --reset | --verify
#
# FIRST-TIME SETUP FLAGS
#   --name "Name"       git user.name for this profile         (required unless --no-git-config)
#   --email "addr"      git user.email for this profile        (required unless --no-git-config)
#   --github            run gh auth login                      (default)
#   --gitlab            run glab auth login
#   --both              run both gh and glab auth
#   --no-git-auth       skip gh/glab auth (just up + claude + git config)
#   --no-git-config     skip git user.name/email set
#   --no-claude-auth    skip `claude login`
#
# LIFECYCLE FLAGS (pick one; mutually exclusive with setup flags)
#   --restart           docker compose restart
#   --recreate          docker compose up -d --force-recreate
#   --remove            docker compose down (keeps persistent state)
#   --reset             WIPE profile state dir + fresh setup. Requires --yes.
#   --verify            sanity checks (auth status, mounts, git config) and exit
#
# OTHER
#   --yes               skip confirmation prompts (needed for --reset)
#   -h, --help          this help
#
# EXAMPLES
#   # Brand-new profile: creates dirs, brings stack up, runs claude + gh auth,
#   # sets git identity, verifies.
#   scripts/setup.sh nranthony --name "neilanthony" --email "nelly@x.com"
#
#   # Same but authenticate GitLab instead of GitHub:
#   scripts/setup.sh therapod --name "Work Name" --email "w@x" --gitlab
#
#   # Both platforms:
#   scripts/setup.sh work --name "W" --email "w@x" --both
#
#   # Restart an existing profile (no auth/config changes):
#   scripts/setup.sh work --restart
#
#   # Force recreate after a compose/seccomp/mount change:
#   scripts/setup.sh work --recreate
#
#   # Nuke and start over (destroys all profile state — USE CAREFULLY):
#   scripts/setup.sh work --reset --yes --name "W" --email "w@x"
# =============================================================================
set -euo pipefail

DRIVE="/Volumes/DataDrive"
PROFILES_ROOT="$DRIVE/.claude-colima/profiles"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_SH="$SCRIPT_DIR/profile.sh"

info()  { printf '\033[0;36m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[0;32m[ OK ]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
step()  { printf '\n\033[1;35m[ >> ]\033[0m  %s\n' "$*"; }
fail()  { printf '\033[0;31m[FAIL]\033[0m  %s\n' "$*"; exit 1; }

usage() { awk 'NR<3{next} /^[^#]/{exit} {sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"; exit 1; }

# --- parse args -------------------------------------------------------------
[[ $# -ge 1 ]] || usage
[[ "$1" == "-h" || "$1" == "--help" ]] && usage

PROFILE="$1"; shift
[[ "$PROFILE" =~ ^[a-zA-Z0-9_-]+$ ]] || fail "Profile name must match [a-zA-Z0-9_-]+"

GIT_NAME=""; GIT_EMAIL=""
GIT_HOSTS="github"           # github | gitlab | both | none
SKIP_GIT_CONFIG=0
SKIP_CLAUDE_AUTH=0
ACTION=""                     # "" | restart | recreate | remove | reset | verify
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)            GIT_NAME="$2"; shift 2 ;;
    --email)           GIT_EMAIL="$2"; shift 2 ;;
    --github)          GIT_HOSTS="github"; shift ;;
    --gitlab)          GIT_HOSTS="gitlab"; shift ;;
    --both)            GIT_HOSTS="both"; shift ;;
    --no-git-auth)     GIT_HOSTS="none"; shift ;;
    --no-git-config)   SKIP_GIT_CONFIG=1; shift ;;
    --no-claude-auth)  SKIP_CLAUDE_AUTH=1; shift ;;
    --restart)         ACTION="restart"; shift ;;
    --recreate)        ACTION="recreate"; shift ;;
    --remove)          ACTION="remove"; shift ;;
    --reset)           ACTION="reset"; shift ;;
    --verify)          ACTION="verify"; shift ;;
    --yes|-y)          ASSUME_YES=1; shift ;;
    -h|--help)         usage ;;
    *)                 fail "Unknown option: $1" ;;
  esac
done

export PROFILE
export COMPOSE_PROJECT_NAME="macolima-$PROFILE"
AGENT="claude-agent-$PROFILE"

confirm() {
  (( ASSUME_YES )) && return 0
  read -rp "$1 [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# --- lifecycle actions ------------------------------------------------------
if [[ -n "$ACTION" ]]; then
  cd "$SCRIPT_DIR/.."
  case "$ACTION" in
    restart)
      step "Restarting profile '$PROFILE'"
      docker compose restart
      ok "Restarted."
      exit 0
      ;;
    recreate)
      step "Force-recreating profile '$PROFILE'"
      "$PROFILE_SH" "$PROFILE" up >/dev/null  # ensures state dirs exist
      docker compose up -d --force-recreate
      ok "Recreated."
      exit 0
      ;;
    remove)
      step "Removing containers for profile '$PROFILE' (state preserved)"
      docker compose down
      ok "Removed. Persistent state kept at $PROFILES_ROOT/$PROFILE/"
      exit 0
      ;;
    reset)
      warn "This will DELETE all state for profile '$PROFILE':"
      warn "  $PROFILES_ROOT/$PROFILE/"
      warn "Containers will also be removed. /workspace repo contents are NOT touched."
      if ! confirm "Continue?"; then fail "Aborted."; fi
      docker compose down -v 2>/dev/null || true
      rm -rf "$PROFILES_ROOT/$PROFILE"
      ok "Profile state wiped."
      # Fall through to full setup if name/email given, otherwise exit.
      if [[ -z "$GIT_NAME$GIT_EMAIL" ]] && (( ! SKIP_GIT_CONFIG )); then
        ok "Done. Re-run with --name/--email to set up from scratch."
        exit 0
      fi
      # else continue to setup flow below
      ACTION=""
      ;;
    verify)
      step "Verifying profile '$PROFILE'"
      docker compose ps
      echo
      info "Claude auth:"
      docker exec "$AGENT" sh -c 'jq -r ".claudeAiOauth.expiresAt, .claudeAiOauth.subscriptionType" /home/agent/.claude/.credentials.json 2>/dev/null || echo "(not authed)"'
      echo
      info "GitHub auth:"
      docker exec "$AGENT" gh auth status 2>&1 || true
      echo
      info "GitLab auth:"
      docker exec "$AGENT" glab auth status 2>&1 || true
      echo
      info "Git identity:"
      docker exec "$AGENT" git config --global --list 2>&1 || true
      exit 0
      ;;
  esac
fi

# --- setup flow -------------------------------------------------------------
if (( ! SKIP_GIT_CONFIG )); then
  [[ -n "$GIT_NAME"  ]] || fail "--name is required (or pass --no-git-config to skip)"
  [[ -n "$GIT_EMAIL" ]] || fail "--email is required (or pass --no-git-config to skip)"
fi

step "Setting up profile '$PROFILE'"
info "Project: $COMPOSE_PROJECT_NAME   Container: $AGENT"

step "1/5  Bringing stack up"
"$PROFILE_SH" "$PROFILE" up

step "2/5  Claude authentication"
if (( SKIP_CLAUDE_AUTH )); then
  warn "Skipping (--no-claude-auth)."
elif docker exec "$AGENT" test -s /home/agent/.claude/.credentials.json 2>/dev/null \
     && docker exec "$AGENT" jq -e '.claudeAiOauth.accessToken' /home/agent/.claude/.credentials.json >/dev/null 2>&1; then
  ok "Already authenticated — skipping. (Force re-auth with:  scripts/profile.sh $PROFILE auth)"
else
  docker exec -it "$AGENT" claude login
fi

step "3/5  Git host authentication ($GIT_HOSTS)"
do_github_auth() {
  if docker exec "$AGENT" gh auth status >/dev/null 2>&1; then
    ok "gh: already authenticated."
  else
    docker exec -it "$AGENT" gh auth login
  fi
  # Wire gh as git credential helper regardless (idempotent).
  docker exec "$AGENT" gh auth setup-git || warn "gh auth setup-git failed (non-fatal)"
}
do_gitlab_auth() {
  if docker exec "$AGENT" glab auth status >/dev/null 2>&1; then
    ok "glab: already authenticated."
  else
    docker exec -it "$AGENT" glab auth login
  fi
}
case "$GIT_HOSTS" in
  github) do_github_auth ;;
  gitlab) do_gitlab_auth ;;
  both)   do_github_auth; do_gitlab_auth ;;
  none)   warn "Skipping git host auth (--no-git-auth)." ;;
esac

step "4/5  Setting git identity"
if (( SKIP_GIT_CONFIG )); then
  warn "Skipping (--no-git-config)."
else
  docker exec "$AGENT" git config --global user.name  "$GIT_NAME"
  docker exec "$AGENT" git config --global user.email "$GIT_EMAIL"
  docker exec "$AGENT" git config --global init.defaultBranch main
  ok "user.name='$GIT_NAME'  user.email='$GIT_EMAIL'"
fi

step "5/5  Verification"
"$SCRIPT_DIR/setup.sh" "$PROFILE" --verify 2>&1 | sed 's/^/  /'

echo
ok "Profile '$PROFILE' is ready."
info "Attach with:   scripts/profile.sh $PROFILE attach"
info "Shut down:     scripts/profile.sh $PROFILE down"
