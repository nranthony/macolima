#!/usr/bin/env bash
# =============================================================================
# vendor-tools.test.sh — the channel POINTER contract (work/0002 V1)
# =============================================================================
# Locks the three-states-three-outcomes rule, which is the single thing this
# mechanism has actually got wrong in production — twice, in the sibling repo:
# a depot move left the pointer dangling, "unconfigured" and "moved away"
# collapsed into one silent output, and the monitor stayed green over a real
# three-release drift. Both occurrences are recorded in vendor-tools.sh's header.
#
#   nothing configured          -> [SKIP], exit 0
#   configured, target missing  -> [FAIL], exit 1
#   configured and present      -> exit 0
#
# Runs the REAL script against throwaway repo skeletons — it never reimplements
# the resolver, and it never touches the live .depot-dir.local.
#
# Fully offline. No docker, no network. Usage: bash scripts/vendor-tools.test.sh
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/vendor-tools.sh"
[[ -f "$SRC" ]] || { echo "missing $SRC" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  ok   %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  FAIL %s\n       %s\n" "$1" "${2:-}"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vendortools.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# A throwaway repo whose scripts/ holds a copy of the real script, so REPO_ROOT
# (derived from BASH_SOURCE) points at the fake root and .depot-dir.local can be
# varied without touching this checkout.
mkrepo() {
  local r="$WORK/repo$1"; rm -rf "$r"; mkdir -p "$r/scripts"
  cp "$SRC" "$r/scripts/vendor-tools.sh"; chmod +x "$r/scripts/vendor-tools.sh"
  printf '%s' "$r"
}

# A directory that looks like a channel root.
mkchannel() {
  local c="$WORK/chan$1"; rm -rf "$c"; mkdir -p "$c"
  cat > "$c/manifest.toml" <<'TOML'
schema = 1
[artifact.demo]
kind = "wheel+skill"
version = "9.9.9"
source_commit = "abcdef0123456789"
TOML
  printf '%s' "$c"
}

run() {  # run <repo> [env-assignment...] -- capture output+status
  local r="$1"; shift
  ( cd "$r" && env "$@" bash "$r/scripts/vendor-tools.sh" --check 2>&1 )
}

echo "-- vendor-tools: the channel pointer contract --"

# ---- state 1: nothing configured -> SKIP, exit 0 ----------------------------
R="$(mkrepo 1)"
out="$(run "$R" DEPOT_DIR=)"; st=$?
if [[ $st -eq 0 ]] && printf '%s' "$out" | grep -q 'SKIP'; then
  ok "unconfigured: SKIP and exit 0 (ordinary — must never become a failure)"
else
  bad "unconfigured did not SKIP/exit 0" "status=$st out=$out"
fi

# ---- state 2: configured, target missing -> FAIL, exit 1 --------------------
out="$(run "$R" DEPOT_DIR="$WORK/does-not-exist")"; st=$?
if [[ $st -eq 1 ]] && printf '%s' "$out" | grep -q 'FAIL'; then
  ok "configured but absent: FAIL and exit 1  <-- THE REGRESSION LOCK"
else
  bad "a dangling pointer did not fail" "status=$st out=$out"
fi

# The two states must not print the same thing. This is the actual defect that
# shipped twice: not a wrong verdict, but two states rendered identically.
out1="$(run "$R" DEPOT_DIR=)"
out2="$(run "$R" DEPOT_DIR="$WORK/does-not-exist")"
if [[ "$out1" != "$out2" ]]; then
  ok "unconfigured and dangling produce DIFFERENT output"
else
  bad "unconfigured and dangling are indistinguishable" "both: $out1"
fi

# ---- a real directory that is not a channel --------------------------------
mkdir -p "$WORK/notachannel"
out="$(run "$R" DEPOT_DIR="$WORK/notachannel")"; st=$?
if [[ $st -eq 1 ]] && printf '%s' "$out" | grep -q 'no manifest.toml'; then
  ok "a directory without manifest.toml is rejected, and says why"
else
  bad "non-channel directory not rejected" "status=$st out=$out"
fi

# ---- state 3: configured and present -> exit 0, reports the artifacts -------
C="$(mkchannel 1)"
out="$(run "$R" DEPOT_DIR="$C")"; st=$?
if [[ $st -eq 0 ]] && printf '%s' "$out" | grep -q 'demo' && printf '%s' "$out" | grep -q '9.9.9'; then
  ok "valid channel: exit 0 and the manifest's artifacts are reported"
else
  bad "valid channel not reported" "status=$st out=$out"
fi

# ---- pointer FILE: comment-tolerant ----------------------------------------
# Reading the comment AS the path is a bug the sibling repo shipped once, which
# is why the parser is awk and not `head -n1`.
R2="$(mkrepo 2)"
printf '# where the depot channel lives\n# (gitignored)\n%s\n' "$C" > "$R2/.depot-dir.local"
out="$(run "$R2" DEPOT_DIR=)"; st=$?
if [[ $st -eq 0 ]] && printf '%s' "$out" | grep -q 'demo'; then
  ok ".depot-dir.local skips comment lines  <-- 'read the comment as the path' lock"
else
  bad "comment header broke the pointer parse" "status=$st out=$out"
fi

# ---- pointer FILE: CRLF tolerant -------------------------------------------
printf '%s\r\n' "$C" > "$R2/.depot-dir.local"
out="$(run "$R2" DEPOT_DIR=)"; st=$?
if [[ $st -eq 0 ]]; then
  ok "a CRLF pointer file still resolves"
else
  bad "CRLF in the pointer broke resolution" "status=$st out=$out"
fi

# ---- $DEPOT_DIR outranks the pointer file ----------------------------------
printf '%s\n' "$WORK/does-not-exist" > "$R2/.depot-dir.local"
out="$(run "$R2" DEPOT_DIR="$C")"; st=$?
if [[ $st -eq 0 ]] && printf '%s' "$out" | grep -q 'DEPOT_DIR'; then
  ok "\$DEPOT_DIR wins over .depot-dir.local, and the report names which was used"
else
  bad "env did not outrank the pointer file" "status=$st out=$out"
fi

# ---- the failure names WHERE to fix it -------------------------------------
printf '%s\n' "$WORK/does-not-exist" > "$R2/.depot-dir.local"
out="$(run "$R2" DEPOT_DIR=)"
if printf '%s' "$out" | grep -q '.depot-dir.local'; then
  ok "a dangling pointer file failure names the pointer file itself"
else
  bad "failure did not say where the bad pointer lives" "out=$out"
fi

# ---- read-only: V1 must not write anything ---------------------------------
before="$(find "$R2" -type f | sort; find "$C" -type f | sort)"
run "$R2" DEPOT_DIR="$C" >/dev/null 2>&1
after="$(find "$R2" -type f | sort; find "$C" -type f | sort)"
if [[ "$before" == "$after" ]]; then
  ok "no files created or removed in repo or channel (V1 is read-only)"
else
  bad "V1 modified the tree" "$(diff <(printf '%s' "$before") <(printf '%s' "$after") | head -5)"
fi

printf "\n  %d passed, %d failed\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
