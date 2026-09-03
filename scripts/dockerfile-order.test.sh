#!/usr/bin/env bash
# =============================================================================
# dockerfile-order.test.sh — the build-layer ORDER is load-bearing
# =============================================================================
# Five separate comments in the Dockerfile each claim a position, and together
# they form one chain that must hold:
#
#   AI_CLI_REFRESH ARG  <  claude/agy install  <  npmrc (Gate 2)  <  uv+pip (Gate 3)
#     <  myclickup wheel
#
# The two repos' chains overlap but neither contains the other. windows-ai-sandbox
# chains `beads` ahead of all of these and macolima deliberately does not port it;
# macolima chains the myclickup wheel behind them and windows-ai-sandbox does not,
# because the two images put that layer in different places for the same stated
# reason (see the wheel link below).
#
# Why each link matters:
#
#   Gate 2 (npmrc) AFTER the claude/agy install — THIS IS THE ONE THAT BREAKS
#     BUILDS. `min-release-age` applies to `npm install` at BUILD time too, so
#     writing it earlier makes `@anthropic-ai/claude-code@latest` unresolvable
#     whenever the newest release is inside the quarantine window. The failure is
#     intermittent by nature: it depends on when upstream last published, so it
#     passes locally and breaks a week later. Worse, because `--refresh-ai`
#     re-runs the CLI install every time, a mis-order surfaces on a routine
#     version bump rather than only on a cold rebuild.
#
#   Gate 3 (uv/pip) BEFORE the wheel — it is config-only and has no build-time
#     dependency of its own, and `no-build = true` is what makes installing the
#     wheel safe to do at all.
#
#   myclickup wheel LAST — the position is a CACHE decision, and the one anchor
#     windows-ai-sandbox does not have. Pre-1.0 this is the most frequently
#     re-vendored artifact in the tree, and this image has five network fetches
#     between Gate 3 and the tail (oh-my-zsh, three plugin clones, the gitstatusd
#     release) that a wheel bump must not re-run. Above the AI_CLI_REFRESH
#     cache-buster it would also re-run the Claude Code/agy install and both
#     gates. Drifting upward costs minutes per bump and nothing else — silent,
#     which is why it is anchored rather than left to the comment.
#
# Anchored on STRINGS, never line numbers: line numbers drift on every edit above
# them, and a test that needs updating for unrelated edits gets updated
# carelessly. If a deliberate rename makes an anchor vanish, this fails with
# "0 occurrences" and names the anchor to fix — loudly, which is the point.
#
# Fully offline. No docker, no network, no build.
#
# Usage:  bash scripts/dockerfile-order.test.sh
# =============================================================================

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DF="$HERE/../Dockerfile"
[[ -f "$DF" ]] || { echo "missing $DF" >&2; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf "  ok   %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  FAIL %s\n       %s\n" "$1" "$2"; }

# The chain, in required order. Each entry is "label|anchor string".
# macolima chain. One of windows-ai-sandbox's six anchors does not exist here and
# is NOT a placeholder to be restored: `beads` was deliberately not ported (a
# work/0001 §1 judgement call, default no). The load-bearing link — Gate 2 AFTER
# the claude/agy install — is fully preserved, and it is the one that breaks
# builds.
#
# The AI_CLI_REFRESH ARG must stay immediately ahead of the install it busts: an
# ARG only invalidates the cache for layers AFTER it, so an ARG that drifts below
# its RUN makes --refresh-ai silently stop refreshing — a no-op that looks like
# it worked, which is the worst failure shape available here.
ANCHORS=(
  "AI-CLI refresh ARG|ARG AI_CLI_REFRESH"
  "claude/agy install|npm install -g --allow-scripts=@anthropic-ai/claude-code"
  "Gate 2 npmrc write|> /usr/etc/npmrc"
  "Gate 3 uv write|> /etc/uv/uv.toml"
  "Gate 3 pip write|> /etc/pip.conf"
  "myclickup wheel COPY|COPY sandbox_templates/wheels/"
)

echo "-- Dockerfile layer order --"

# Each anchor must appear EXACTLY once. Two occurrences make "the line number of
# the anchor" ambiguous and would let a duplicated block reorder itself unseen.
declare -a LINES=() LABELS=()
for entry in "${ANCHORS[@]}"; do
  label="${entry%%|*}"; anchor="${entry#*|}"
  n="$(grep -cF -- "$anchor" "$DF")"
  if [[ "$n" -eq 1 ]]; then
    ok "anchor present exactly once: $label"
    LINES+=("$(grep -nF -- "$anchor" "$DF" | cut -d: -f1)")
    LABELS+=("$label")
  else
    bad "anchor '$label' occurs $n times (want 1)" \
        "string: $anchor
       If this was renamed deliberately, update ANCHORS in this file. If it
       vanished, the layer it guards may have been removed — check the ordering
       comments in the Dockerfile before 'fixing' the test."
  fi
done

# Strictly increasing line numbers = the chain holds.
if [[ "${#LINES[@]}" -eq "${#ANCHORS[@]}" ]]; then
  order_ok=1
  for (( i=1; i<${#LINES[@]}; i++ )); do
    if (( LINES[i] <= LINES[i-1] )); then
      order_ok=0
      bad "layer order violated: '${LABELS[i]}' (line ${LINES[i]}) must come AFTER '${LABELS[i-1]}' (line ${LINES[i-1]})" \
          "See the ordering comments in the Dockerfile. The link most likely to
       break a build is Gate 2 after the claude/agy install: min-release-age
       applies at BUILD time, so writing it earlier makes
       @anthropic-ai/claude-code@latest unresolvable whenever the newest release
       is inside the quarantine window — an intermittent, self-inflicted break."
    fi
  done
  (( order_ok )) && ok "chain holds: $(printf '%s ' "${LINES[@]}" | sed 's/ $//' | tr ' ' '<')"
else
  bad "cannot check order — an anchor is missing" "resolve the anchor failures above first"
fi

# The Gate 2 layer self-checks inside its own RUN. Cheap to assert, and it is
# what makes a mis-order fail at build time rather than at first agent install.
if grep -qF 'npm config get min-release-age' "$DF"; then
  ok "Gate 2 layer verifies its own write in-layer (npm config get)"
else
  bad "Gate 2 layer no longer self-checks" \
      "the RUN that writes /usr/etc/npmrc should end with an assertion, so a
       broken write fails the build instead of silently disabling the age gate"
fi

# The wheel layer verifies as the RUNTIME user, not just as the build user. This
# image runs the agent as UID 1000; a root-only `myclickup --version` would pass
# on a tool the agent cannot reach, which is precisely the shape of failure the
# UV_TOOL_DIR pin exists to prevent. windows-ai-sandbox needs no equivalent line
# because its runtime user IS root.
if grep -qF "su -s /bin/sh agent -c 'myclickup --version'" "$DF"; then
  ok "wheel layer verifies as the agent user, not only as root"
else
  bad "wheel layer no longer checks the tool as UID 1000" \
      "a build-time check running as root proves nothing about the runtime user;
       see the UV_TOOL_DIR block for what it is guarding against"
fi

# The pins that decide whether any of this survives to runtime.
if grep -qF 'UV_TOOL_DIR=/opt/uv/tools' "$DF" && grep -qF 'UV_TOOL_BIN_DIR=/usr/local/bin' "$DF"; then
  ok "uv tool dirs pinned off the noexec tmpfs"
else
  bad "UV_TOOL_DIR / UV_TOOL_BIN_DIR pin is gone" \
      "unpinned, uv installs into /home/agent/.local — a noexec tmpfs wiped at
       container start. The build stays green and the tool is absent at runtime."
fi

printf "\n  %d passed, %d failed\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
