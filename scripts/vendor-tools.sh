#!/usr/bin/env bash
# =============================================================================
# vendor-tools.sh — consume the depot channel into sandbox_templates/
# =============================================================================
# Ported from windows-ai-sandbox (work/0002 V1). THIS FILE IS INCOMPLETE BY
# DESIGN: V1 lands only the channel POINTER and its failure modes. Hash
# verification, the payload mirror and VENDORED.lock arrive with V3. Every code
# path here is read-only — nothing is copied, nothing is written.
#
# Usage:
#   scripts/vendor-tools.sh            # report where the channel is and what it publishes
#   scripts/vendor-tools.sh --check    # monitor form: SKIP / FAIL / report
#
# WHERE THE CHANNEL IS — THREE STATES, THREE OUTCOMES, NEVER TWO:
#
#   nothing configured          -> [SKIP], exit 0    ordinary
#   configured, target missing  -> [FAIL], exit 1    never ordinary
#   configured and present      -> proceed
#
# There is deliberately NO guessed fallback path. A guess collapses "never
# configured" and "moved away" into one output, and the collapsed state is the
# silent one.
#
# That is not a hypothetical. windows-ai-sandbox's own header records the
# 2026-08-14 depot move going "invisible to both existing monitors while a real
# three-release wheel drift went green" — and it has happened a SECOND time: as
# of 2026-09-02 that repo has neither $DEPOT_DIR nor .depot-dir.local after the
# channel moved to repo/nranthony/depot/, so its `just tools-check` is green
# while vendoring nothing. The distinction below is the whole point of the file.
#
# Pointer sources, in order:
#   $DEPOT_DIR
#   .depot-dir.local   (gitignored, one line, comment-tolerant)
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

info() { printf '\033[0;36m[INFO]\033[0m  %s\n' "$*"; }
ok()   { printf '\033[0;32m[ OK ]\033[0m  %s\n' "$*"; }
skip() { printf '\033[1;35m[SKIP]\033[0m  vendor-tools: %s\n' "$*"; }
die()  { printf '\033[0;31m[FAIL]\033[0m  vendor-tools: %s\n' "$*" >&2; exit 1; }

# --- where the channel is ----------------------------------------------------
# awk rather than `head -n1` because a pointer file may carry a comment header,
# and reading the comment AS the path is a bug the sibling repo has already
# shipped once. Comment-tolerant, CR-tolerant, and expands a leading `~/`.
channel_candidate() {
  local candidate=""
  if [[ -n "${DEPOT_DIR:-}" ]]; then
    candidate="$DEPOT_DIR"
  elif [[ -f "$REPO_ROOT/.depot-dir.local" ]]; then
    candidate="$(awk 'NF && $0 !~ /^[[:space:]]*#/ { print; exit }' \
                   "$REPO_ROOT/.depot-dir.local" | tr -d '\r')"
  fi
  case "$candidate" in "~/"*) candidate="$HOME/${candidate#\~/}" ;; esac
  printf '%s' "$candidate"
}

# Quoted back in every failure so a broken pointer says WHERE to fix it.
channel_origin() {
  if [[ -n "${DEPOT_DIR:-}" ]]; then
    printf '$DEPOT_DIR'
  else
    printf '%s' "$REPO_ROOT/.depot-dir.local"
  fi
}

resolve_channel() {
  local candidate
  candidate="$(channel_candidate)"
  if [[ -z "$candidate" ]]; then
    die "channel location unknown. Set one of:
    DEPOT_DIR=/path/to/depot scripts/vendor-tools.sh
    echo /path/to/depot > $REPO_ROOT/.depot-dir.local   (gitignored)"
  fi
  if [[ ! -d "$candidate" ]]; then
    die "configured channel root is absent (from $(channel_origin)): $candidate
        the pointer names a path that does not exist — REPOINT it, do not delete
        it: an empty pointer stands down silently and stops watching the boundary"
  fi
  if [[ ! -f "$candidate/manifest.toml" ]]; then
    die "not a channel root — no manifest.toml (from $(channel_origin)): $candidate"
  fi
  (cd "$candidate" && pwd)
}

# --- read-only manifest summary ----------------------------------------------
# tomllib, not a hand-rolled parser: the manifest is a security-relevant file
# and a second parser of it is a second thing to get wrong. Emits flat
# TAB-separated `artifact<TAB>kind<TAB>version<TAB>source_commit` lines so
# everything downstream stays bash + coreutils.
manifest_summary() {
  local root="$1"
  python3 - "$root/manifest.toml" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
if doc.get("schema") != 1:
    print(f"unsupported manifest schema: {doc.get('schema')!r}", file=sys.stderr)
    raise SystemExit(2)
for name, a in sorted(doc.get("artifact", {}).items()):
    print("\t".join([name, a.get("kind", "?"), a.get("version", "?"),
                     (a.get("source_commit") or "?")[:9]]))
PY
}

report_channel() {
  local root="$1" line n=0
  ok "channel: $root  (from $(channel_origin))"
  while IFS="$(printf '\t')" read -r name kind version commit; do
    if [[ -z "$name" ]]; then continue; fi
    printf '        %-12s %-12s %-8s %s\n' "$name" "$kind" "$version" "$commit"
    n=$(( n + 1 ))
  done <<EOF
$(manifest_summary "$root")
EOF
  info "$n artifact(s) published. V1 reports the channel only — hash verification,"
  info "the payload mirror and VENDORED.lock land with work/0002 V3."
}

# --- entry point -------------------------------------------------------------
mode="report"
for a in "$@"; do
  case "$a" in
    --check) mode="check" ;;
    -h|--help) sed -n '2,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown flag '$a' (valid: --check)" ;;
  esac
done

if [[ -z "$(channel_candidate)" ]]; then
  # State 1. Ordinary, and it must stay distinguishable from state 2 forever.
  skip "no channel configured (set \$DEPOT_DIR or write $REPO_ROOT/.depot-dir.local)"
  exit 0
fi

# States 2 and 3. resolve_channel exits 1 on a configured-but-broken pointer.
root="$(resolve_channel)"
report_channel "$root"
if [[ "$mode" == "check" ]]; then
  info "pointer OK. This check does NOT yet compare against VENDORED.lock (V3)."
fi
