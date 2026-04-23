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

# bwrap + socat are deliberately NOT installed (Claude Code's bwrap sandbox
# can't run here — seccomp correctly blocks unprivileged user namespaces —
# and socat was a raw-TCP exfil channel bypassing Squid HTTP egress). Absent
# is correct; presence is drift.
command -v bwrap >/dev/null && fail "bwrap present (should be uninstalled)" || pass "bwrap absent (intended)"
command -v socat >/dev/null && fail "socat present (should be uninstalled)" || pass "socat absent (intended)"

# Claude CLI present
command -v claude >/dev/null && pass "claude CLI present" || fail "claude CLI missing"

echo ""
echo "== $PASS passed | $FAIL failed | $WARN warnings =="
[[ $FAIL -eq 0 ]]
