#!/usr/bin/env bash
# =============================================================================
# verify-sandbox.sh — run INSIDE the container to confirm hardening is active
# =============================================================================
# Usage (from host):
#   docker exec -it claude-agent bash /workspace/nranthony/macolima/scripts/verify-sandbox.sh
# =============================================================================
set -uo pipefail

PASS=0; FAIL=0; WARN=0
pass() { printf '\033[0;32m[PASS]\033[0m %s\n' "$*"; ((PASS++)); }
fail() { printf '\033[0;31m[FAIL]\033[0m %s\n' "$*"; ((FAIL++)); }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; ((WARN++)); }

# Non-root
[[ "$(id -u)" -ne 0 ]] && pass "non-root (UID $(id -u))" || fail "running as root"

# Read-only rootfs
if touch /test-ro 2>/dev/null; then rm -f /test-ro; fail "rootfs writable"; else pass "rootfs read-only"; fi

# /tmp writable
if touch /tmp/.t 2>/dev/null; then rm -f /tmp/.t; pass "/tmp writable (tmpfs)"; else fail "/tmp not writable"; fi

# Capabilities
CAP_EFF=$(grep CapEff /proc/self/status | awk '{print $2}')
[[ "$CAP_EFF" == "0000000000000000" ]] && pass "caps dropped" || warn "CapEff=$CAP_EFF"

# Seccomp
SM=$(grep Seccomp /proc/self/status | awk '{print $2}')
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
if curl -s --connect-timeout 5 https://api.github.com >/dev/null 2>&1; then
  pass "proxied request to allowed domain works"
else
  warn "proxied request failed — check allowed_domains.txt / proxy running"
fi
if curl -s --connect-timeout 5 https://example.com >/dev/null 2>&1; then
  fail "disallowed domain (example.com) was reachable"
else
  pass "disallowed domain blocked by proxy"
fi

# Bubblewrap present (Claude Code sandbox dep)
command -v bwrap >/dev/null && pass "bubblewrap present" || fail "bubblewrap missing"

# Claude CLI present
command -v claude >/dev/null && pass "claude CLI present" || fail "claude CLI missing"

echo ""
echo "== $PASS passed | $FAIL failed | $WARN warnings =="
[[ $FAIL -eq 0 ]]
