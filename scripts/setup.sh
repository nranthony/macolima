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

# verify_git_token <label> <host-token-file> <token-value-regex> <probe-url> \
#                  <in-container-live-cmd> <login-hint>
# Credential-safe auth check for git forges. The bare `gh auth status` /
# `glab auth status` make a LIVE API call to validate the token, so at the
# autonomous egress baseline (api.github.com / gitlab.com blocked by Squid)
# they always report "failed" even when the stored token is perfectly valid —
# a false negative that scared operators. This instead:
#   1. Confirms the token FILE is present and actually holds a token value —
#      read on the HOST via the config bind mount. We `grep -q` only (never
#      print the file) and report just presence + mtime, so no credential is
#      ever echoed, logged, or held in a variable.
#   2. Attempts live validation ONLY when egress to the forge is open (probed
#      via the agent's proxied curl). Closed egress -> "not live-validated
#      (egress closed)", NOT "failed". Open + rejected -> a real re-auth nudge.
verify_git_token() {
  local label="$1" tokfile="$2" valre="$3" probe="$4" livecmd="$5" hint="$6"
  local mt code
  if [[ ! -s "$tokfile" ]]; then
    warn "$label: no token file — not authed (run: $hint)"
    return 0
  fi
  mt=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$tokfile" 2>/dev/null || echo unknown)
  if ! grep -Eq "$valre" "$tokfile" 2>/dev/null; then
    warn "$label: token file present but holds no token value (modified $mt) — re-auth (run: $hint)"
    return 0
  fi
  ok "$label: token present (modified $mt)"
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$AGENT"; then
    info "  live validation skipped — agent container not running"
    return 0
  fi
  # -w prints the HTTP code even on proxy refusal (000 via Squid's CONNECT
  # deny); `|| true` keeps that 000 from tripping `set -e`.
  code=$(docker exec "$AGENT" curl -sS -o /dev/null -w '%{http_code}' --max-time 6 "$probe" 2>/dev/null || true)
  if [[ -z "$code" || "$code" == "000" ]]; then
    info "  not live-validated — egress to ${probe#https://} is closed (autonomous baseline); token unverified against server"
  elif docker exec "$AGENT" sh -c "$livecmd" >/dev/null 2>&1; then
    ok "  live-validated against ${probe#https://}"
  else
    warn "  token REJECTED by ${probe#https://} — re-auth needed (run: $hint)"
  fi
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
      # --reset is the "I want a totally fresh start" path: nuke everything
      # under the profile dir + recreate the auth chain. Different from
      # `profile.sh wipe`, which preserves Claude/gh/glab/git auth and only
      # tears down rotating state. Use --reset when you intend to re-login.
      warn "This will DELETE all state for profile '$PROFILE':"
      warn "  $PROFILES_ROOT/$PROFILE/  (claude tokens, gh/glab tokens, settings, sessions)"
      warn "Containers will also be removed."
      warn "Named volumes that WILL be dropped: ${COMPOSE_PROJECT_NAME}_vscode-server, ${COMPOSE_PROJECT_NAME}_cache"
      warn "DB volumes (${COMPOSE_PROJECT_NAME}_postgres-data / _mongo-data) are PRESERVED unless you also pass --all-volumes."
      warn "/workspace repo contents are NOT touched."
      if ! confirm "Continue?"; then fail "Aborted."; fi
      # Take down containers; drop only the throwaway named volumes by name
      # (vscode-server + cache). DB volumes are explicit-opt-in via
      # --all-volumes — same default as `profile.sh wipe`. If --all-volumes
      # is passed, fall through to `down -v` which nukes every named volume
      # attached to the project.
      if (( ASSUME_YES )) && [[ " $* " == *" --all-volumes "* ]]; then
        # (parser doesn't currently capture --all-volumes; keep this guard
        # available for future expansion and to make intent visible)
        docker compose down -v 2>/dev/null || true
      else
        docker compose down 2>/dev/null || true
        for v in vscode-server cache; do
          docker volume rm "${COMPOSE_PROJECT_NAME}_${v}" 2>/dev/null || true
        done
      fi
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
      # Run jq with `-e` (exit-nonzero-on-null) and discard its stderr — on a
      # corrupt/missing file we want a clean "(not authed)" signal, not a jq
      # parse-error message that quotes the file path. The comma operator
      # outputs both fields on separate lines if both are present.
      docker exec "$AGENT" sh -c '
        set +e
        out=$(jq -er ".claudeAiOauth.expiresAt, .claudeAiOauth.subscriptionType" /home/agent/.claude/.credentials.json 2>/dev/null)
        if [ -n "$out" ]; then printf "%s\n" "$out"; else echo "(not authed)"; fi
      '
      echo
      info "GitHub auth:"
      verify_git_token "GitHub" \
        "$PROFILES_ROOT/$PROFILE/config/gh/hosts.yml" \
        '^[[:space:]]*oauth_token:[[:space:]]*[^[:space:]]' \
        "https://api.github.com" "gh auth status" "gh auth login"
      echo
      info "GitLab auth:"
      verify_git_token "GitLab" \
        "$PROFILES_ROOT/$PROFILE/config/glab-cli/config.yml" \
        '^[[:space:]]*token:[[:space:]]*[^[:space:]]' \
        "https://gitlab.com" "glab auth status" "glab auth login"
      echo
      info "Git identity:"
      docker exec "$AGENT" git config --global --list 2>&1 || true
      echo
      info "Egress sentinel:"
      # Surface any uncleaned scripts/with-egress.sh sentinel — tells the
      # operator the proxy is currently widened beyond autonomous-mode policy.
      sentinel="$PROFILES_ROOT/.egress-widened-$PROFILE"
      if [[ -e "$sentinel" ]]; then
        warn "egress is currently widened — $(cat "$sentinel" 2>/dev/null || echo 'unknown')"
        warn "  delete the sentinel + restart egress-proxy to restore autonomous policy:"
        warn "    rm '$sentinel' && PROFILE=$PROFILE COMPOSE_PROJECT_NAME=macolima-$PROFILE docker compose restart egress-proxy"
      else
        ok "egress allowlist is at autonomous-mode baseline"
      fi
      echo
      info "db.env perms:"
      dbenv="$PROFILES_ROOT/$PROFILE/db.env"
      if [[ -f "$dbenv" ]]; then
        mode=$(stat -f '%Lp' "$dbenv" 2>/dev/null || stat -c '%a' "$dbenv" 2>/dev/null)
        if [[ "$mode" == "600" ]]; then ok "db.env is 600"
        else warn "db.env is $mode (should be 600 — contains DB superuser password)"
        fi
      else
        ok "db.env not present (DBs not configured for this profile)"
      fi
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
