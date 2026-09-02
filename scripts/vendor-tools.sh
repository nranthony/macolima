#!/usr/bin/env bash
# =============================================================================
# vendor-tools.sh — consume the depot channel into sandbox_templates/
# =============================================================================
# Ported from windows-ai-sandbox (work/0002 V1 + V3).
#
# WHAT THIS IS. One door for every artifact that enters the image. The channel
# publishes `manifest.toml` (versions + sha256 + source commits) alongside a
# `dist/` tree; this script verifies those hashes, mirrors the payloads into
# `sandbox_templates/`, and records what it took in
# `sandbox_templates/VENDORED.lock`.
#
# WHY THIS IS SECURITY-SENSITIVE. Everything it copies is baked into the image
# (the wheel) or converged into every profile (the skills). A bug here puts
# unverified content inside the sandbox boundary, which is why the hash gate runs
# over EVERY artifact before ANY file is copied — a partial mirror that fails
# halfway is a half-updated image with no record of which half.
#
# NOT YET IMPLEMENTED, AND SAID SO PLAINLY: the CONTENT check. A hash proves an
# artifact did not change in transit; it cannot prove the wheel matches the
# `source_commit` it claims. W cross-checks each artifact against its member
# checkout when reachable. That needs the member-pointer machinery and lands with
# a later step. Until then `--check` verifies hash-and-lock only, and says so —
# a check that implies more coverage than it has is worse than none.
#
# Usage:
#   scripts/vendor-tools.sh             # verify + mirror + write the lock
#   scripts/vendor-tools.sh --dry-run   # verify and report, copy nothing
#   scripts/vendor-tools.sh --check     # monitor: is the lock behind the channel?
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
TEMPLATES="$REPO_ROOT/sandbox_templates"
WHEEL_DIR="$TEMPLATES/wheels"
LOCK="$TEMPLATES/VENDORED.lock"

# ALL diagnostics go to stderr, without exception. `verify_all` returns the flat
# manifest table on STDOUT and the caller captures it — so a single progress line
# printed to stdout from inside it lands in the table, and the artifact loop then
# reads that line as an artifact name with no `kind`. Caught here on 2026-09-02
# before the first real mirror: the --dry-run path hid it (its case has no
# default arm), while the mirror loop's `unvalidated artifact` assertion would
# have fired. Keep the `>&2`.
info() { printf '\033[0;36m[INFO]\033[0m  %s\n' "$*" >&2; }
ok()   { printf '\033[0;32m[ OK ]\033[0m  %s\n' "$*" >&2; }
skip() { printf '\033[1;35m[SKIP]\033[0m  vendor-tools: %s\n' "$*" >&2; }
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

# --- the single manifest extraction point ------------------------------------
# The manifest is TOML, so it is read by `python3 -m tomllib` at exactly ONE
# point that emits flat `artifact<TAB>key<TAB>value` lines; everything downstream
# is bash + coreutils. That is the opposite of hand-rolling a TOML parser in awk,
# which would be a second parser of a security-relevant file. `VENDORED.lock` is
# deliberately NOT TOML for the same reason.
manifest_flat() {
  python3 - "$1/manifest.toml" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
if doc.get("schema") != 1:
    print(f"unsupported manifest schema {doc.get('schema')!r} — this script "
          "mirrors schema 1 only", file=sys.stderr)
    raise SystemExit(2)
for name, a in sorted(doc.get("artifact", {}).items()):
    for key, val in sorted(a.items()):
        if isinstance(val, (str, int, float)):
            print(f"{name}\t{key}\t{val}")
        # Lists (proposed_allow/ask/deny) and tables belong to the permissions
        # leg, not the mirror. Reported by name so a new KEY whose shape this
        # loop cannot represent is never half-consumed as a stringified repr.
        else:
            print(f"[NOTE] {name}.{key}: not a scalar, skipped by the mirror",
                  file=sys.stderr)
PY
}

# field lookup: mf <flat> <artifact> <key>
mf() { awk -F'\t' -v a="$2" -v k="$3" '$1==a && $2==k {print $3; exit}' <<<"$1"; }

# --- path safety -------------------------------------------------------------
# The manifest is machine-generated, but it names paths this script then reads
# FROM, and it crosses a repo boundary. A `../` escaping the channel root would
# read outside it; refuse rather than trust the producer's generator.
assert_inside() {
  local root="$1" rel="$2" what="$3"
  case "$rel" in
    /*|*..*) die "manifest $what path escapes the channel root, refusing: $rel" ;;
  esac
  [[ -e "$root/$rel" ]] || die "manifest names a $what that is not in the channel: $rel"
}

# macOS ships `shasum`, not GNU `sha256sum`. Both spellings, so this file is the
# same on either substrate.
sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# ONE HASH IMPLEMENTATION, NOT TWO. Tree identity comes from the channel's own
# bin/dirhash.py, invoked off the channel path. A bash reimplementation would be
# a new cross-repo boundary of exactly the kind the channel exists to delete.
tree_hash() {
  local root="$1" target="$2"
  [[ -f "$root/bin/dirhash.py" ]] || die "channel has no bin/dirhash.py — cannot verify a
       tree artifact without reimplementing the channel's hash, which this
       script will not do"
  python3 "$root/bin/dirhash.py" "$root/$target" | awk '{print $NF}'
}

# --- verify EVERY artifact before copying ANY --------------------------------
# Returns the flat manifest on stdout so the caller does not re-read it. Any
# mismatch is fatal here, before a single file has moved.
verify_all() {
  local root="$1" flat art kind rel want got pair
  flat="$(manifest_flat "$root")"
  [[ -n "$flat" ]] || die "manifest declares no artifacts: $root/manifest.toml"

  while read -r art; do
    kind="$(mf "$flat" "$art" kind)"
    case "$kind" in
      wheel+skill)
        for pair in "wheel wheel_sha256" "skill skill_sha256"; do
          set -- $pair
          rel="$(mf "$flat" "$art" "$1")"; want="$(mf "$flat" "$art" "$2")"
          [[ -n "$rel" && -n "$want" ]] || die "$art: manifest is missing $1/$2"
          assert_inside "$root" "$rel" "$1"
          got="$(sha_of "$root/$rel")"
          [[ "$got" == "$want" ]] || die "HASH MISMATCH $art/$1
       manifest: $want
       actual:   $got
       the channel's own copy does not match what it published — a CHANNEL-side
       fault, not something to clear by re-vendoring here. Run \`just verify\`
       at the channel root."
          info "verified $art/$1  $(printf '%.12s' "$want")…"
        done
        ;;
      plugin)
        rel="$(mf "$flat" "$art" tree)"; want="$(mf "$flat" "$art" tree_sha256)"
        [[ -n "$rel" && -n "$want" ]] || die "$art: manifest is missing tree/tree_sha256"
        assert_inside "$root" "$rel" tree
        got="$(tree_hash "$root" "$rel")"
        [[ "$got" == "$want" ]] || die "HASH MISMATCH $art/tree
       manifest: $want
       actual:   $got
       computed by the channel's own bin/dirhash.py, so this is a channel-side
       fault. Run \`just verify\` at the channel root."
        info "verified $art/tree  $(printf '%.12s' "$want")…"
        ;;
      "") die "$art: manifest entry has no kind" ;;
      *)  die "$art: unknown artifact kind '$kind' — this script mirrors
       wheel+skill and plugin only. A new kind must be taught here explicitly
       rather than skipped, or it would enter the image unverified." ;;
    esac
  done < <(cut -f1 <<<"$flat" | sort -u)

  printf '%s' "$flat"
}

# --- lock --------------------------------------------------------------------
# Flat, sorted, four fields: `artifact version sha256 source_commit`. A
# wheel+skill artifact contributes TWO rows (`<name>.wheel`, `<name>.skill`) so
# the one-row-one-hash shape survives and the two halves can be seen to drift
# independently.
write_lock() {
  local flat="$1" art kind ver commit tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/vendorlock.XXXXXX")"
  {
    printf '# Generated by scripts/vendor-tools.sh — do not hand-edit.\n'
    printf '# What this image was built from. Fields: artifact version sha256 source_commit\n'
    printf '# Channel: manifest.toml consumed from the depot channel root.\n'
    while read -r art; do
      kind="$(mf "$flat" "$art" kind)"
      ver="$(mf "$flat" "$art" version)"
      commit="$(mf "$flat" "$art" source_commit)"
      case "$kind" in
        wheel+skill)
          printf '%s.wheel %s %s %s\n' "$art" "$ver" "$(mf "$flat" "$art" wheel_sha256)" "$commit"
          printf '%s.skill %s %s %s\n' "$art" "$ver" "$(mf "$flat" "$art" skill_sha256)" "$commit"
          ;;
        plugin)
          printf '%s.tree %s %s %s\n' "$art" "$ver" "$(mf "$flat" "$art" tree_sha256)" "$commit"
          ;;
        # An artifact reaching the lock without a known kind means the flat table
        # disagrees with what verify_all validated. A lock missing a row is worse
        # than no lock — it reads as a complete record.
        *) die "internal: unvalidated artifact '$art' (kind '$kind') reached the lock" ;;
      esac
    done < <(cut -f1 <<<"$flat" | sort -u)
  } > "$tmp"
  # Header first, payload sorted — a stable file, so a lock diff shows a real
  # change and never a reordering.
  { grep '^#' "$tmp"; grep -v '^#' "$tmp" | sort; } > "$LOCK"
  rm -f "$tmp"
}

# --- vendor ------------------------------------------------------------------
do_vendor() {
  local dry="${1:-}" root flat art kind rel ver

  root="$(resolve_channel)"
  ok "channel: $root  (from $(channel_origin))"
  flat="$(verify_all "$root")"

  if [[ "$dry" == "--dry-run" ]]; then
    printf '\nwould mirror:\n'
    while read -r art; do
      kind="$(mf "$flat" "$art" kind)"; ver="$(mf "$flat" "$art" version)"
      case "$kind" in
        wheel+skill)
          printf '  %-12s %-8s wheel -> sandbox_templates/wheels/\n' "$art" "$ver"
          printf '  %-12s %-8s skill -> sandbox_templates/skills/%s/SKILL.md\n' "" "" "$art"
          ;;
        plugin)
          printf '  %-12s %-8s tree  -> sandbox_templates/skills/%s/\n' "$art" "$ver" "$art"
          ;;
      esac
    done < <(cut -f1 <<<"$flat" | sort -u)
    printf '\nwould write: %s\n' "${LOCK#"$REPO_ROOT"/}"
    printf 'nothing was copied (--dry-run)\n'
    return 0
  fi

  # Past this line every hash has already been checked. Mirror.
  while read -r art; do
    kind="$(mf "$flat" "$art" kind)"
    case "$kind" in
      wheel+skill)
        mkdir -p "$WHEEL_DIR" "$TEMPLATES/skills/$art"
        # rm -f before cp is load-bearing: two wheels in this directory is a
        # deliberate BUILD REFUSAL (Dockerfile, V4), not a pick-one. Leaving the
        # old version beside the new turns a version bump into a failed build.
        rm -f "$WHEEL_DIR"/"$art"-*.whl
        rel="$(mf "$flat" "$art" wheel)"; cp "$root/$rel" "$WHEEL_DIR/"
        rel="$(mf "$flat" "$art" skill)"; cp "$root/$rel" "$TEMPLATES/skills/$art/SKILL.md"
        ;;
      plugin)
        # delete-then-copy, not a merge: a file deleted upstream must vanish
        # here. Same rule ADR-0005 enforces for skill convergence, same failure
        # (phantom copies surviving releases) it exists to prevent.
        rel="$(mf "$flat" "$art" tree)"
        rm -rf "${TEMPLATES:?}/skills/$art"
        mkdir -p "$TEMPLATES/skills/$art"
        cp -R "$root/$rel/." "$TEMPLATES/skills/$art/"
        ;;
      *) die "internal: unvalidated artifact '$art' (kind '$kind') reached the mirror" ;;
    esac
    ok "mirrored $art ($(mf "$flat" "$art" version))"
  done < <(cut -f1 <<<"$flat" | sort -u)

  write_lock "$flat"
  ok "wrote ${LOCK#"$REPO_ROOT"/}"
  printf '\nNext: just build             (the wheel is baked in; `up` does not rebuild)\n'
  printf 'Then: just recreate <p>      (per running profile)\n'
}

# --- check -------------------------------------------------------------------
do_check() {
  local cand root flat expected actual

  cand="$(channel_candidate)"
  if [[ -z "$cand" ]]; then
    skip "no depot channel configured — channel drift NOT checked.
       set \$DEPOT_DIR, or: echo /path/to/depot > $REPO_ROOT/.depot-dir.local"
    return 0
  fi
  root="$(resolve_channel)"

  if [[ ! -f "$LOCK" ]]; then
    skip "no VENDORED.lock — nothing has been vendored from the channel on this
       machine yet, so there is nothing to compare (run: just vendor-tools)"
    return 0
  fi

  flat="$(verify_all "$root")"
  expected="$(mktemp "${TMPDIR:-/tmp}/vendorexp.XXXXXX")"
  actual="$(mktemp "${TMPDIR:-/tmp}/vendoract.XXXXXX")"
  # Double-quoted on purpose: the PATHS are expanded into the trap string now.
  # Single quotes would defer expansion to exit time, when these locals are out
  # of scope and `set -u` turns cleanup into "expected: unbound variable".
  # shellcheck disable=SC2064
  trap "rm -f '$expected' '$actual'" EXIT

  LOCK="$expected" write_lock "$flat"
  grep -v '^#' "$expected" | sort > "$actual"
  grep -v '^#' "$LOCK"     | sort > "$expected"

  if ! diff -u "$expected" "$actual" > /dev/null; then
    printf 'vendor-tools --check: DRIFT — the channel has moved since the last vendor\n\n'
    diff -u --label 'VENDORED.lock (consumed)' --label 'manifest.toml (published)' \
         "$expected" "$actual" || true
    die "re-vendor:  just vendor-tools
       then bake:  just build   (the wheel is baked into the image, so a green
                   check does NOT mean running containers have the new version —
                   recreate them too)"
  fi
  ok "VENDORED.lock matches the channel manifest ($(grep -vc '^#' "$LOCK") artifact rows)"
  info "hash-and-lock only: the artifacts are NOT content-checked against their"
  info "source_commit yet (see the header). That check lands with a later step."
}

# --- entry point -------------------------------------------------------------
mode="vendor"; dry=""
for a in "$@"; do
  case "$a" in
    --check)   mode="check" ;;
    --dry-run) dry="--dry-run" ;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown flag '$a' (valid: --check --dry-run)" ;;
  esac
done

if [[ "$mode" == "check" ]]; then
  do_check
  exit 0
fi

# The vendor path REQUIRES a channel: an unconfigured pointer is ordinary for a
# monitor, but "vendor from nowhere" is not a thing to succeed quietly at.
if [[ -z "$(channel_candidate)" ]]; then
  die "no channel configured — nothing to vendor from. Set one of:
    DEPOT_DIR=/path/to/depot scripts/vendor-tools.sh
    echo /path/to/depot > $REPO_ROOT/.depot-dir.local   (gitignored)"
fi
do_vendor "$dry"
