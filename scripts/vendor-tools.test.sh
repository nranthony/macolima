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

sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
        else shasum -a 256 "$1" | awk '{print $1}'; fi; }

# A COMPLETE channel root: a real payload with correct hashes. It has to be
# complete even for the pointer tests, because since V3 resolution is followed
# immediately by the hash gate — a fixture that only looks like a channel from
# the outside now fails for the right reason at the wrong assertion.
mkchannel() {
  local c="$WORK/chan$1"; rm -rf "$c"
  mkdir -p "$c/dist/wheels" "$c/dist/skills/demo"
  printf 'WHEEL\n' > "$c/dist/wheels/demo-9.9.9-py3-none-any.whl"
  printf 'SKILL\n' > "$c/dist/skills/demo/SKILL.md"
  cat > "$c/manifest.toml" <<TOML
schema = 1
[artifact.demo]
kind = "wheel+skill"
version = "9.9.9"
source_commit = "abcdef0123456789abcdef0123456789abcdef01"
wheel = "dist/wheels/demo-9.9.9-py3-none-any.whl"
wheel_sha256 = "$(sha "$c/dist/wheels/demo-9.9.9-py3-none-any.whl")"
skill = "dist/skills/demo/SKILL.md"
skill_sha256 = "$(sha "$c/dist/skills/demo/SKILL.md")"
TOML
  printf '%s' "$c"
}

# Every invocation below points SANDBOX_DRIVE — profile.sh's test seam, which
# vendor-tools.sh mirrors — at a path that does not exist, so the pointer/mirror
# cases never see the live profile root and the wheel-delivery step stands down
# with an INFO line. The delivery suite at the bottom passes a real throwaway
# drive instead. Without this, `vend` against a machine that has profiles would
# write into real workspaces.
NODRIVE="$WORK/nodrive"

run() {  # run <repo> [env-assignment...] -- the monitor form, output+status
  local r="$1"; shift
  ( cd "$r" && env SANDBOX_DRIVE="$NODRIVE" "$@" bash "$r/scripts/vendor-tools.sh" --check 2>&1 )
}

# Pointer resolution is asserted through --dry-run, not --check: since V3,
# --check SKIPs when there is no VENDORED.lock, so it stops short of reading the
# manifest. --dry-run resolves, verifies and reports without writing anything,
# which is the path that proves the pointer actually reached the channel.
run_dry() {
  local r="$1"; shift
  ( cd "$r" && env SANDBOX_DRIVE="$NODRIVE" "$@" bash "$r/scripts/vendor-tools.sh" --dry-run 2>&1 )
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
out="$(run_dry "$R" DEPOT_DIR="$C")"; st=$?
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
out="$(run_dry "$R2" DEPOT_DIR=)"; st=$?
if [[ $st -eq 0 ]] && printf '%s' "$out" | grep -q 'demo'; then
  ok ".depot-dir.local skips comment lines  <-- 'read the comment as the path' lock"
else
  bad "comment header broke the pointer parse" "status=$st out=$out"
fi

# ---- pointer FILE: CRLF tolerant -------------------------------------------
printf '%s\r\n' "$C" > "$R2/.depot-dir.local"
out="$(run_dry "$R2" DEPOT_DIR=)"; st=$?
if [[ $st -eq 0 ]]; then
  ok "a CRLF pointer file still resolves"
else
  bad "CRLF in the pointer broke resolution" "status=$st out=$out"
fi

# ---- $DEPOT_DIR outranks the pointer file ----------------------------------
printf '%s\n' "$WORK/does-not-exist" > "$R2/.depot-dir.local"
out="$(run_dry "$R2" DEPOT_DIR="$C")"; st=$?
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
run_dry "$R2" DEPOT_DIR="$C" >/dev/null 2>&1
after="$(find "$R2" -type f | sort; find "$C" -type f | sort)"
if [[ "$before" == "$after" ]]; then
  ok "no files created or removed in repo or channel (V1 is read-only)"
else
  bad "V1 modified the tree" "$(diff <(printf '%s' "$before") <(printf '%s' "$after") | head -5)"
fi

# =============================================================================
# V3 — the hash gate, the mirror, and the lock
# =============================================================================
# Fixtures use the `wheel+skill` kind, which needs no dirhash.py. The plugin
# (tree) path additionally needs the channel's own hash implementation, so those
# assertions copy it from the configured channel and SKIP loudly without one —
# a skip is not a pass.

# mkchan2 <n> [wheelbody] -> a channel with one wheel+skill artifact, hashes correct
mkchan2() {
  local c="$WORK/ch$1"; rm -rf "$c"; mkdir -p "$c/dist/wheels" "$c/dist/skills/demo"
  printf '%s' "${2:-WHEELBODY}" > "$c/dist/wheels/demo-1.0.0-py3-none-any.whl"
  printf 'skill body
' > "$c/dist/skills/demo/SKILL.md"
  cat > "$c/manifest.toml" <<TOML
schema = 1
[artifact.demo]
kind = "wheel+skill"
version = "1.0.0"
source_commit = "1111111111111111111111111111111111111111"
wheel = "dist/wheels/demo-1.0.0-py3-none-any.whl"
wheel_sha256 = "$(sha "$c/dist/wheels/demo-1.0.0-py3-none-any.whl")"
skill = "dist/skills/demo/SKILL.md"
skill_sha256 = "$(sha "$c/dist/skills/demo/SKILL.md")"
TOML
  printf '%s' "$c"
}

vend() { local r="$1"; shift
  ( cd "$r" && env SANDBOX_DRIVE="$NODRIVE" "$@" bash "$r/scripts/vendor-tools.sh" 2>&1 ); }

echo
echo "-- vendor-tools: the hash gate, the mirror, the lock --"

# ---- a clean vendor lands both payloads and writes the lock ----------------
R3="$(mkrepo 3)"; C3="$(mkchan2 3)"
out="$(vend "$R3" DEPOT_DIR="$C3")"; st=$?
if [[ $st -eq 0 ]]    && [[ -f "$R3/sandbox_templates/wheels/demo-1.0.0-py3-none-any.whl" ]]    && [[ -f "$R3/sandbox_templates/skills/demo/SKILL.md" ]]    && [[ -f "$R3/sandbox_templates/VENDORED.lock" ]]; then
  ok "a clean vendor mirrors wheel + skill and writes VENDORED.lock"
else
  bad "clean vendor did not land the payloads" "status=$st out=$out"
fi

# ---- the lock is stable across runs ----------------------------------------
cp "$R3/sandbox_templates/VENDORED.lock" "$WORK/lock1"
vend "$R3" DEPOT_DIR="$C3" >/dev/null 2>&1
if diff -q "$WORK/lock1" "$R3/sandbox_templates/VENDORED.lock" >/dev/null; then
  ok "re-vendoring the same channel produces a byte-identical lock (no reordering)"
else
  bad "the lock is not stable across runs" "$(diff "$WORK/lock1" "$R3/sandbox_templates/VENDORED.lock" | head -4)"
fi

# ---- HASH MISMATCH: fatal, and NOTHING is copied ---------------------------
# The load-bearing property of the whole script: verify EVERY artifact before
# copying ANY. A partial mirror is a half-updated image with no record of which
# half, so the gate must run to completion before the first cp.
R4="$(mkrepo 4)"; C4="$(mkchan2 4)"
printf 'TAMPERED' > "$C4/dist/wheels/demo-1.0.0-py3-none-any.whl"
out="$(vend "$R4" DEPOT_DIR="$C4")"; st=$?
copied=0; [[ -e "$R4/sandbox_templates/wheels/demo-1.0.0-py3-none-any.whl" ]] && copied=1
[[ -e "$R4/sandbox_templates/skills/demo/SKILL.md" ]] && copied=1
[[ -e "$R4/sandbox_templates/VENDORED.lock" ]] && copied=1
if [[ $st -ne 0 ]] && printf '%s' "$out" | grep -q 'HASH MISMATCH' && [[ $copied -eq 0 ]]; then
  ok "a tampered payload is fatal AND nothing was copied  <-- VERIFY-BEFORE-COPY"
else
  bad "hash mismatch did not stop the mirror" "status=$st copied=$copied out=$out"
fi

# ---- the failure blames the CHANNEL, not the consumer ----------------------
if printf '%s' "$out" | grep -q 'channel root'; then
  ok "a hash mismatch says it is a channel-side fault and names \`just verify\` there"
else
  bad "mismatch message does not route to the channel" "out=$out"
fi

# ---- wheel ROTATION: a bump must not leave two wheels ----------------------
# Two wheels in that directory is a deliberate BUILD REFUSAL (V4), so a stale
# sibling turns a version bump into a failed build.
R5="$(mkrepo 5)"; C5="$(mkchan2 5)"
vend "$R5" DEPOT_DIR="$C5" >/dev/null 2>&1
C5b="$WORK/ch5b"; rm -rf "$C5b"; cp -R "$C5" "$C5b"
mv "$C5b/dist/wheels/demo-1.0.0-py3-none-any.whl" "$C5b/dist/wheels/demo-2.0.0-py3-none-any.whl"
sed -i.bak 's/demo-1\.0\.0-py3-none-any\.whl/demo-2.0.0-py3-none-any.whl/; s/version = "1.0.0"/version = "2.0.0"/' "$C5b/manifest.toml"
rm -f "$C5b/manifest.toml.bak"
vend "$R5" DEPOT_DIR="$C5b" >/dev/null 2>&1
n="$(find "$R5/sandbox_templates/wheels" -name 'demo-*.whl' | wc -l | tr -d ' ')"
if [[ "$n" -eq 1 ]] && [[ -f "$R5/sandbox_templates/wheels/demo-2.0.0-py3-none-any.whl" ]]; then
  ok "a version bump ROTATES the wheel (exactly 1 left, the new one)"
else
  bad "wheel rotation left $n wheel(s)" "$(ls "$R5/sandbox_templates/wheels")"
fi

# ---- manifest path escaping is refused -------------------------------------
R6="$(mkrepo 6)"; C6="$(mkchan2 6)"
sed -i.bak 's|wheel = "dist/wheels/demo-1.0.0-py3-none-any.whl"|wheel = "../../../etc/passwd"|' "$C6/manifest.toml"
rm -f "$C6/manifest.toml.bak"
out="$(vend "$R6" DEPOT_DIR="$C6")"; st=$?
if [[ $st -ne 0 ]] && printf '%s' "$out" | grep -q 'escapes the channel root'; then
  ok "a manifest path containing ../ is refused before any read"
else
  bad "path escape not refused" "status=$st out=$out"
fi

# ---- an unknown artifact kind is refused, never skipped --------------------
R7="$(mkrepo 7)"; C7="$(mkchan2 7)"
sed -i.bak 's/kind = "wheel+skill"/kind = "somethingnew"/' "$C7/manifest.toml"
rm -f "$C7/manifest.toml.bak"
out="$(vend "$R7" DEPOT_DIR="$C7")"; st=$?
if [[ $st -ne 0 ]] && printf '%s' "$out" | grep -q 'unknown artifact kind'; then
  ok "an unknown kind is a refusal, not a silent skip (it would enter unverified)"
else
  bad "unknown kind was not refused" "status=$st out=$out"
fi

# ---- --dry-run copies nothing ----------------------------------------------
R8="$(mkrepo 8)"; C8="$(mkchan2 8)"
vend "$R8" DEPOT_DIR="$C8" --dry-run >/dev/null 2>&1
if [[ ! -e "$R8/sandbox_templates/VENDORED.lock" ]] && [[ ! -d "$R8/sandbox_templates/wheels" ]]; then
  ok "--dry-run verifies and reports without copying anything"
else
  bad "--dry-run wrote to the tree" "$(find "$R8/sandbox_templates" -type f 2>/dev/null | head -3)"
fi

# ---- --check: clean, drifted, and absent-lock ------------------------------
R9="$(mkrepo 9)"; C9="$(mkchan2 9)"
vend "$R9" DEPOT_DIR="$C9" >/dev/null 2>&1
( cd "$R9" && env DEPOT_DIR="$C9" bash "$R9/scripts/vendor-tools.sh" --check >/dev/null 2>&1 )
if [[ $? -eq 0 ]]; then
  ok "--check exits 0 when the lock matches the channel"
else
  bad "--check failed on a matching lock"
fi

sed -i.bak 's/ 1\.0\.0 / 0.9.0 /' "$R9/sandbox_templates/VENDORED.lock"; rm -f "$R9/sandbox_templates/VENDORED.lock.bak"
out="$( cd "$R9" && env DEPOT_DIR="$C9" bash "$R9/scripts/vendor-tools.sh" --check 2>&1 )"; st=$?
if [[ $st -ne 0 ]] && printf '%s' "$out" | grep -q 'DRIFT'; then
  ok "--check FAILS on a stale lock and shows the lock-vs-manifest diff"
else
  bad "--check did not catch a stale lock" "status=$st out=$out"
fi

rm -f "$R9/sandbox_templates/VENDORED.lock"
out="$( cd "$R9" && env DEPOT_DIR="$C9" bash "$R9/scripts/vendor-tools.sh" --check 2>&1 )"; st=$?
if [[ $st -eq 0 ]] && printf '%s' "$out" | grep -q 'SKIP'; then
  ok "--check SKIPs (exit 0) when nothing has been vendored yet"
else
  bad "absent lock was not a clean skip" "status=$st out=$out"
fi

# ---- plugin trees: delete-then-copy, not merge -----------------------------
# A file deleted upstream must VANISH here. Needs the channel's dirhash.py.
DIRHASH=""
cand="${DEPOT_DIR:-}"
[[ -z "$cand" && -f "$HERE/../.depot-dir.local" ]] &&   cand="$(awk 'NF && $0 !~ /^[[:space:]]*#/ { print; exit }' "$HERE/../.depot-dir.local")"
[[ -n "$cand" && -f "$cand/bin/dirhash.py" ]] && DIRHASH="$cand/bin/dirhash.py"

if [[ -z "$DIRHASH" ]]; then
  printf "  SKIP no channel dirhash.py reachable — plugin-tree pruning NOT verified
"
else
  mkplugin() {  # <dir> <extra-file-or-empty>
    local c="$1"; rm -rf "$c"; mkdir -p "$c/bin" "$c/dist/plugins/demoplug/skills/a"
    cp "$DIRHASH" "$c/bin/dirhash.py"
    printf 'A
' > "$c/dist/plugins/demoplug/skills/a/SKILL.md"
    [[ -n "${2:-}" ]] && { mkdir -p "$c/dist/plugins/demoplug/skills/b"; printf 'B
' > "$c/dist/plugins/demoplug/skills/b/SKILL.md"; }
    local h; h="$(python3 "$c/bin/dirhash.py" "$c/dist/plugins/demoplug" | awk '{print $NF}')"
    cat > "$c/manifest.toml" <<TOML
schema = 1
[artifact.demoplug]
kind = "plugin"
version = "1.0.0"
source_commit = "2222222222222222222222222222222222222222"
tree = "dist/plugins/demoplug"
tree_sha256 = "$h"
TOML
  }
  R10="$(mkrepo 10)"
  mkplugin "$WORK/cp1" withb
  vend "$R10" DEPOT_DIR="$WORK/cp1" >/dev/null 2>&1
  had_b=0; [[ -f "$R10/sandbox_templates/skills/demoplug/skills/b/SKILL.md" ]] && had_b=1
  mkplugin "$WORK/cp2"            # b removed upstream
  vend "$R10" DEPOT_DIR="$WORK/cp2" >/dev/null 2>&1
  if [[ $had_b -eq 1 ]] && [[ ! -e "$R10/sandbox_templates/skills/demoplug/skills/b" ]]      && [[ -f "$R10/sandbox_templates/skills/demoplug/skills/a/SKILL.md" ]]; then
    ok "a file deleted upstream VANISHES here (delete-then-copy, not merge)"
  else
    bad "plugin tree was merged rather than replaced" "had_b=$had_b remaining: $(find "$R10/sandbox_templates/skills/demoplug" -type f | tr '\n' ' ')"
  fi
fi

# ---- --permissions: REPORT-ONLY, and it must not cry wolf ------------------
# The security property is the one worth locking: an artifact must not widen
# the sandbox by being vendored, so this path may never write to the policy
# template. The rest guards the two ways a permissions report becomes useless —
# reporting a gap that is already covered, and missing one that is real.
mkperm_channel() {                 # a channel whose artifact carries proposals
  local c="$WORK/permchan"; rm -rf "$c"
  mkdir -p "$c/dist/wheels" "$c/dist/skills/demo"
  printf 'WHEEL\n' > "$c/dist/wheels/demo-9.9.9-py3-none-any.whl"
  printf 'SKILL\n' > "$c/dist/skills/demo/SKILL.md"
  cat > "$c/manifest.toml" <<TOML
schema = 1
[artifact.demo]
kind = "wheel+skill"
version = "9.9.9"
source_commit = "abcdef0123456789abcdef0123456789abcdef01"
wheel = "dist/wheels/demo-9.9.9-py3-none-any.whl"
wheel_sha256 = "$(sha "$c/dist/wheels/demo-9.9.9-py3-none-any.whl")"
skill = "dist/skills/demo/SKILL.md"
skill_sha256 = "$(sha "$c/dist/skills/demo/SKILL.md")"
proposed_allow = ["Bash(demo read:*)", "Bash(demo list:*)"]
proposed_ask = ["Bash(demo write:*)"]
proposed_deny = ["Bash(demo destroy:*)"]
TOML
  printf '%s' "$c"
}

mkpolicy() {                        # <repo> <allow-json> <ask-json> <deny-json>
  mkdir -p "$1/sandbox_templates/claude"
  cat > "$1/sandbox_templates/claude/claude-settings.json" <<JSON
{ "permissions": { "allow": [$2], "ask": [$3], "deny": [$4] } }
JSON
}

run_perm() {
  local r="$1"; shift
  ( cd "$r" && env "$@" bash "$r/scripts/vendor-tools.sh" --permissions 2>&1 )
}

PC="$(mkperm_channel)"

# no channel configured -> SKIP, exit 0 (the same three-state rule as --check)
RP0="$(mkrepo p0)"; mkpolicy "$RP0" '' '' ''
out="$(run_perm "$RP0" DEPOT_DIR= 2>&1)"; rc=$?
if [[ $rc -eq 0 ]] && printf '%s' "$out" | grep -q 'SKIP'; then
  ok "--permissions with no channel: SKIPs loudly, exit 0"
else
  bad "--permissions unconfigured should SKIP and exit 0" "rc=$rc out=$out"
fi

# THE LOCK: it reports, and the policy file is byte-identical afterwards
RP1="$(mkrepo p1)"; mkpolicy "$RP1" '' '' ''
before="$(sha "$RP1/sandbox_templates/claude/claude-settings.json")"
out="$(run_perm "$RP1" DEPOT_DIR="$PC")"
after="$(sha "$RP1/sandbox_templates/claude/claude-settings.json")"
if [[ "$before" == "$after" ]]; then
  ok "--permissions NEVER edits claude-settings.json  <-- LOCK"
else
  bad "--permissions wrote to the policy template" "an artifact must not widen the sandbox by being vendored"
fi

if printf '%s' "$out" | grep -q 'MISSING: Bash(demo destroy:\*)'; then
  ok "a proposed deny absent from the template is reported MISSING"
else
  bad "an absent proposed deny was not reported" "$out"
fi

if printf '%s' "$out" | grep -q 'WRITE-SURFACE GAP'; then
  ok "an ungated write is called out as a gap, not left in a column"
else
  bad "no write-surface gap reported for an ungated ask+deny" "$out"
fi

# already covered -> exact, NOT missing. A report that flags what is already
# there is a report that gets ignored.
RP2="$(mkrepo p2)"
mkpolicy "$RP2" '"Bash(demo read:*)", "Bash(demo list:*)"' '"Bash(demo write:*)"' '"Bash(demo destroy:*)"'
out="$(run_perm "$RP2" DEPOT_DIR="$PC")"
if ! printf '%s' "$out" | grep -q 'MISSING:'; then
  ok "a fully-adopted proposal reports nothing MISSING  <-- FALSE-FAIL LOCK"
else
  bad "a fully-adopted proposal still reported gaps" "$out"
fi
if ! printf '%s' "$out" | grep -q 'WRITE-SURFACE GAP'; then
  ok "no write-surface gap once every write is gated"
else
  bad "gap reported although every write is gated" "$out"
fi

# an `ask` satisfied by the STRONGER `deny` counts as gated
RP3="$(mkrepo p3)"
mkpolicy "$RP3" '' '' '"Bash(demo write:*)", "Bash(demo destroy:*)"'
out="$(run_perm "$RP3" DEPOT_DIR="$PC")"
if ! printf '%s' "$out" | grep -q 'WRITE-SURFACE GAP'; then
  ok "a proposed ask covered by deny is gated, not a gap  <-- FALSE-FAIL LOCK"
else
  bad "deny did not satisfy a proposed ask" "$out"
fi

# a proposed `ask` that the owner PROMOTED to `allow` is a recorded decision:
# visible in the report, counted in neither MISSING nor the gap tally. Both
# halves matter — hidden, a widening goes unreviewed; counted as a gap, the
# report cries wolf on every run after a deliberate promotion and gets ignored.
RP5="$(mkrepo p5)"
mkpolicy "$RP5" '"Bash(demo read:*)", "Bash(demo list:*)", "Bash(demo write:*)"' '' '"Bash(demo destroy:*)"'
out="$(run_perm "$RP5" DEPOT_DIR="$PC")"
if printf '%s' "$out" | grep -q 'PROMOTED to allow.*Bash(demo write:\*)'; then
  ok "an ask proposal sitting on allow is reported as PROMOTED (visible)"
else
  bad "promotion not surfaced" "$out"
fi
if ! printf '%s' "$out" | grep -q 'MISSING:' && ! printf '%s' "$out" | grep -q 'WRITE-SURFACE GAP'; then
  ok "a promoted write is not MISSING and not a gap  <-- FALSE-FAIL LOCK"
else
  bad "a deliberate promotion was reported as a gap" "$out"
fi

# prefix coverage: a deployed shorter prefix covers a longer proposal
RP4="$(mkrepo p4)"; mkpolicy "$RP4" '"Bash(demo r:*)"' '' ''
out="$(run_perm "$RP4" DEPOT_DIR="$PC")"
if printf '%s' "$out" | grep -q 'covered by prefix: Bash(demo read:\*)'; then
  ok "a shorter deployed prefix is reported as covering, not missing"
else
  bad "prefix coverage not detected" "$out"
fi

# =============================================================================
# work/0010 D1-A — wheel delivery into per-profile dist/
# =============================================================================
# Two properties are under test, and they pull in opposite directions on
# purpose. V3's is unchanged: nothing unverified is copied, anywhere. The new
# one belongs to the CONSUMERS: `dist/` is append-only, because a consumer's
# uv.lock pins a wheel by FILENAME and hash — so a delivery that deletes or
# rewrites a same-named file breaks `uv sync --frozen` in a repo this script
# never reads and cannot see. Identical is a skip, different is an error, an
# old version survives a bump, and no profile gets anything it did not ask for.
#
# Everything here runs against a throwaway SANDBOX_DRIVE (profile.sh's seam),
# so the live profile root and real workspaces are never touched.

# mkdrive <n> <profile>... -> a drive with BOTH halves of the real layout for
# each profile: the state dir under .claude-colima/profiles/ and the workspace
# under repo/. Opt-in files are added per test.
mkdrive() {
  local d="$WORK/drive$1"; shift; rm -rf "$d"
  local p
  for p in "$@"; do mkdir -p "$d/.claude-colima/profiles/$p" "$d/repo/$p"; done
  printf '%s' "$d"
}

optin() {  # optin <drive> <profile> <line>...
  local d="$1" p="$2"; shift 2
  printf '%s\n' "$@" > "$d/.claude-colima/profiles/$p/dist-wheels"
}

vend_d() {  # vend_d <repo> <drive> [env...] -- a real vendor against a fake drive
  local r="$1" dr="$2"; shift 2
  ( cd "$r" && env SANDBOX_DRIVE="$dr" "$@" bash "$r/scripts/vendor-tools.sh" 2>&1 )
}

dry_d() {   # the same, --dry-run
  local r="$1" dr="$2"; shift 2
  ( cd "$r" && env SANDBOX_DRIVE="$dr" "$@" bash "$r/scripts/vendor-tools.sh" --dry-run 2>&1 )
}

echo
echo "-- vendor-tools: wheel delivery into per-profile dist/ --"

WHEEL="demo-1.0.0-py3-none-any.whl"

# ---- opted in receives it; not opted in receives NOTHING -------------------
RD1="$(mkrepo d1)"; CD1="$(mkchan2 d1)"; DD1="$(mkdrive 1 alpha beta)"
# Comments, a blank line, indentation and a CR: the state-file format itself is
# the contract here, and it is the one .depot-dir.local already uses.
printf '# what this profile asked for\n\n   demo   \r\n  # demo2, later\n' \
  > "$DD1/.claude-colima/profiles/alpha/dist-wheels"
out="$(vend_d "$RD1" "$DD1" DEPOT_DIR="$CD1")"; st=$?
if [[ $st -eq 0 ]] && [[ -f "$DD1/repo/alpha/dist/$WHEEL" ]] \
   && [[ "$(sha "$DD1/repo/alpha/dist/$WHEEL")" == "$(sha "$CD1/dist/wheels/$WHEEL")" ]]; then
  ok "an opted-in profile receives the wheel, byte-identical to the channel"
else
  bad "opted-in delivery did not land" "status=$st out=$out"
fi

if printf '%s' "$out" | grep -q "alpha: delivered $WHEEL"; then
  ok "the delivery line names the profile and the file"
else
  bad "delivery not reported per profile" "out=$out"
fi

if [[ ! -e "$DD1/repo/beta/dist" ]] && printf '%s' "$out" | grep -q 'not opted in'; then
  ok "a profile with no dist-wheels file gets NOTHING, and is said to  <-- OPT-IN LOCK"
else
  bad "a non-opted-in profile was written to" "$(find "$DD1/repo/beta" 2>/dev/null | head -3)"
fi

# ---- an identical file is skipped, not re-copied ---------------------------
# Inode equality, not just content: a re-copy would satisfy a content check
# while still rewriting a file a consumer's lock is pinning.
ino1="$(ls -i "$DD1/repo/alpha/dist/$WHEEL" | awk '{print $1}')"
out="$(vend_d "$RD1" "$DD1" DEPOT_DIR="$CD1")"; st=$?
ino2="$(ls -i "$DD1/repo/alpha/dist/$WHEEL" | awk '{print $1}')"
if [[ $st -eq 0 ]] && [[ "$ino1" == "$ino2" ]] \
   && printf '%s' "$out" | grep -q 'already present, byte-identical'; then
  ok "a second run skips the identical wheel and does not rewrite it"
else
  bad "identical file was not skipped" "status=$st ino $ino1/$ino2 out=$out"
fi

# ---- APPEND-ONLY: a version bump leaves the OLD wheel in place -------------
# The deliberate inverse of the sandbox_templates/wheels rotation asserted
# above: there two wheels are a build refusal, here the old one is what an
# existing uv.lock still resolves against.
CD1b="$WORK/chd1b"; rm -rf "$CD1b"; cp -R "$CD1" "$CD1b"
mv "$CD1b/dist/wheels/$WHEEL" "$CD1b/dist/wheels/demo-2.0.0-py3-none-any.whl"
sed -i.bak 's/demo-1\.0\.0-py3-none-any\.whl/demo-2.0.0-py3-none-any.whl/; s/version = "1.0.0"/version = "2.0.0"/' "$CD1b/manifest.toml"
rm -f "$CD1b/manifest.toml.bak"
out="$(vend_d "$RD1" "$DD1" DEPOT_DIR="$CD1b")"; st=$?
n_dist="$(find "$DD1/repo/alpha/dist" -name 'demo-*.whl' | wc -l | tr -d ' ')"
n_tpl="$(find "$RD1/sandbox_templates/wheels" -name 'demo-*.whl' | wc -l | tr -d ' ')"
if [[ $st -eq 0 ]] && [[ "$n_dist" -eq 2 ]] && [[ -f "$DD1/repo/alpha/dist/$WHEEL" ]] \
   && [[ -f "$DD1/repo/alpha/dist/demo-2.0.0-py3-none-any.whl" ]] && [[ "$n_tpl" -eq 1 ]]; then
  ok "a bump ADDS to dist/ and keeps the old wheel, while the mirror rotates  <-- APPEND-ONLY LOCK"
else
  bad "dist/ did not accumulate across a bump" "status=$st dist=$n_dist templates=$n_tpl"
fi

# ---- a DIFFERENT file of the same name is an error, and is left alone ------
RD2="$(mkrepo d2)"; CD2="$(mkchan2 d2)"; DD2="$(mkdrive 2 gamma)"
optin "$DD2" gamma demo
mkdir -p "$DD2/repo/gamma/dist"
printf 'A DIFFERENT WHEEL\n' > "$DD2/repo/gamma/dist/$WHEEL"
before="$(sha "$DD2/repo/gamma/dist/$WHEEL")"
out="$(vend_d "$RD2" "$DD2" DEPOT_DIR="$CD2")"; st=$?
after="$(sha "$DD2/repo/gamma/dist/$WHEEL")"
if [[ $st -ne 0 ]] && [[ "$before" == "$after" ]] \
   && printf '%s' "$out" | grep -q 'DIFFERENT content'; then
  ok "a same-name wheel with different content is an ERROR and is NOT overwritten"
else
  bad "a differing wheel was overwritten or not reported" "status=$st out=$out"
fi

if [[ -f "$RD2/sandbox_templates/VENDORED.lock" ]] \
   && printf '%s' "$out" | grep -q 'VENDORED.lock are'; then
  ok "the mirror and the lock still completed — delivery fails AFTER them, and says so"
else
  bad "a delivery error left the mirror ambiguous" "out=$out"
fi

# ---- an opt-in naming something the channel does not publish ---------------
RD3="$(mkrepo d3)"; CD3="$(mkchan2 d3)"; DD3="$(mkdrive 3 delta)"
optin "$DD3" delta nosuchthing
out="$(vend_d "$RD3" "$DD3" DEPOT_DIR="$CD3")"; st=$?
if [[ $st -ne 0 ]] && printf '%s' "$out" | grep -q "names 'nosuchthing'"; then
  ok "an opt-in naming an unpublished artifact fails loudly, never silently"
else
  bad "an unknown opt-in name was swallowed" "status=$st out=$out"
fi

# ---- the hash gate covers dist/ too: a tampered wheel delivers NOTHING -----
RD4="$(mkrepo d4)"; CD4="$(mkchan2 d4)"; DD4="$(mkdrive 4 epsilon)"
optin "$DD4" epsilon demo
printf 'TAMPERED' > "$CD4/dist/wheels/$WHEEL"
out="$(vend_d "$RD4" "$DD4" DEPOT_DIR="$CD4")"; st=$?
if [[ $st -ne 0 ]] && printf '%s' "$out" | grep -q 'HASH MISMATCH' \
   && [[ ! -e "$DD4/repo/epsilon/dist" ]]; then
  ok "a tampered payload reaches no workspace either  <-- VERIFY-BEFORE-COPY"
else
  bad "an unverified wheel reached a workspace" "status=$st out=$out"
fi

# ---- --dry-run reports the delivery and copies nothing ---------------------
RD5="$(mkrepo d5)"; CD5="$(mkchan2 d5)"; DD5="$(mkdrive 5 zeta)"
optin "$DD5" zeta demo
out="$(dry_d "$RD5" "$DD5" DEPOT_DIR="$CD5")"; st=$?
if [[ $st -eq 0 ]] && [[ ! -e "$DD5/repo/zeta/dist" ]] \
   && printf '%s' "$out" | grep -q 'would deliver' \
   && printf '%s' "$out" | grep -q "zeta" && printf '%s' "$out" | grep -q "$WHEEL"; then
  ok "--dry-run names the profile and the wheel, and creates no dist/"
else
  bad "--dry-run delivered or stayed silent" "status=$st out=$out"
fi

# ---- no profile root at all: an INFO line, and the mirror still succeeds ---
RD6="$(mkrepo d6)"; CD6="$(mkchan2 d6)"
out="$(vend_d "$RD6" "$WORK/no-such-drive" DEPOT_DIR="$CD6")"; st=$?
if [[ $st -eq 0 ]] && printf '%s' "$out" | grep -q 'no profile root' \
   && [[ -f "$RD6/sandbox_templates/VENDORED.lock" ]]; then
  ok "an absent profile root skips delivery with an INFO line, mirror unaffected"
else
  bad "absent profile root was not a clean skip" "status=$st out=$out"
fi

printf "\n  %d passed, %d failed\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
