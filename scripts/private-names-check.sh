#!/usr/bin/env bash
# =============================================================================
# private-names-check.sh — no real client/project names on public-repo surfaces
# =============================================================================
# Ported from windows-ai-sandbox (work/0005 P1, their ADR-0009).
#
# This repo is PUBLIC (github.com/nranthony/macolima) and profile names double
# as real client/project names. The standard is SEARCHABLE, not "present at
# all": high-visibility surfaces (README, CLAUDE.md, scripts, shipped templates,
# compose/Dockerfile/seccomp) must carry no client names, case-insensitive.
#
# DELIBERATELY OUT OF SCOPE, and this is the part most likely to be "fixed" by
# someone who has not read this far:
#   * work items and archived narrative — the record of what was decided, where
#     the name is the history, not a leak;
#   * proxy/allowed_domains.txt — its provenance comments name the account that
#     owns a workspace ID, and there the name IS the checkable evidence. A
#     redacted attachment-host comment could not be audited at all;
#   * git history. This is a going-forward gate, not a rewrite.
#
# THE NAME LIST MUST NOT LIVE IN THE TRACKED TREE — committing it would
# re-introduce exactly what this checks for. It is read from a gitignored
# `.private-names.local`, one name per line, '#' comments and blanks skipped,
# following the same convention as `.depot-dir.local`.
#
# TWO STATES ONLY, and a skip is not a pass:
#   .private-names.local absent -> loud [SKIP], exit 0
#   present                     -> scan, exit 0 pass / 1 fail
# There is no third "configured but missing" state here, unlike vendor-tools.sh:
# the file IS the config, so its absence and "not configured" are one fact.
#
# TWO KINDS OF HIT, and the second is a macolima addition (windows-ai-sandbox
# greps CONTENTS only). A tracked PATH is at least as searchable as a line
# inside a file — `docs/<client>-profile-seed.md` is visible in the GitHub file
# tree, in search, and in every clone's directory listing without anyone opening
# it. This repo has profile-named documents that theirs does not, so the path
# scan is not optional here. Send it back to them.
#
# Surfaces scanned (tracked files only, via `git ls-files`):
#   README.md CLAUDE.md AGENTS.md ARCHITECTURE.md justfile
#   scripts/ sandbox_templates/ docs/index.md
#   docker-compose*.yml Dockerfile seccomp.json
#   proxy/ EXCEPT proxy/allowed_domains.txt (see the scope note above)
#   ... EXCEPT per-profile compose overlays, `docker-compose.<profile>.yml` and
#   `docker-compose.<profile>.expose-dev.yml`. Here the profile name in the PATH
#   is the mechanism, not a slip: `profile.sh` layers an overlay by building
#   `docker-compose.$PROFILE.yml` and testing for it (profile.sh:986). Renaming
#   one to a placeholder does not hide the name, it unhooks the file. The base
#   `docker-compose.yml` IS scanned.
#
#   That exclusion is a scope decision, not a clean bill of health: a tracked
#   overlay still puts the profile name in a public file tree. The durable fix
#   is to stop tracking per-profile overlays at all — they are user state in the
#   same sense `profiles/` is — but that untracks a file the owner relies on, so
#   it is a decision for them and not a side effect of adding a check.
#
# Usage: bash scripts/private-names-check.sh
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
NAMES_FILE="$REPO_ROOT/.private-names.local"

ok()   { printf '\033[0;32m[ OK ]\033[0m  private-names: %s\n' "$*"; }
skip() { printf '\033[1;35m[SKIP]\033[0m  private-names: %s\n' "$*"; }
fail() { printf '\033[0;31m[FAIL]\033[0m  private-names: %s\n' "$*" >&2; }

if [[ ! -f "$NAMES_FILE" ]]; then
  skip "no .private-names.local — nothing configured to scan for. This is
       ordinary (the names are deliberately not committed); this check provides
       NO COVERAGE until you create it. One name per line, e.g.:
         printf '%s\\n' myclient myproject > .private-names.local
       See this script's header for scope and the deliberate keeps."
  exit 0
fi

# bash 3.2: no mapfile. It fails as an UNSET ARRAY rather than
# command-not-found, so a mapfile here would silently scan zero names and pass.
NAMES=()
while IFS= read -r _n; do
  [[ -n "$_n" ]] && NAMES+=("$_n")
done < <(awk 'NF && $0 !~ /^[[:space:]]*#/ { print }' "$NAMES_FILE" | tr -d '\r')

if [[ "${#NAMES[@]}" -eq 0 ]]; then
  skip ".private-names.local exists but has no names after comments/blanks —
       nothing to scan for."
  exit 0
fi

cd "$REPO_ROOT"

FILES=()
while IFS= read -r _f; do
  [[ -n "$_f" ]] && FILES+=("$_f")
done < <(
  git ls-files -- \
    README.md CLAUDE.md AGENTS.md ARCHITECTURE.md justfile \
    'scripts/**' 'sandbox_templates/**' docs/index.md \
    'docker-compose*.yml' Dockerfile seccomp.json \
    'proxy/**' \
  | grep -v '^proxy/allowed_domains\.txt$' \
  | grep -vE '^docker-compose\..+\.yml$'
)

if [[ "${#FILES[@]}" -eq 0 ]]; then
  fail "git ls-files matched NO files — the scan would pass vacuously.
       Are you inside the repo, and is anything tracked?"
  exit 1
fi

pattern="$(printf '%s\n' "${NAMES[@]}" | paste -sd '|' -)"

failed=0

# 1. Paths. A tracked filename is a public surface in its own right.
path_hits="$(printf '%s\n' "${FILES[@]}" | grep -Ei -- "$pattern" || true)"
if [[ -n "$path_hits" ]]; then
  failed=1
  fail "a tracked PATH carries a private name (visible in the file tree and in
       search without opening anything):"
  while IFS= read -r line; do printf '         %s\n' "$line" >&2; done <<<"$path_hits"
fi

# 2. Contents.
for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || continue
  hits="$(grep -nEi -- "$pattern" "$f" 2>/dev/null || true)"
  if [[ -n "$hits" ]]; then
    failed=1
    fail "$f carries a private name:"
    while IFS= read -r line; do printf '         %s\n' "$line" >&2; done <<<"$hits"
  fi
done

if [[ "$failed" -eq 1 ]]; then
  fail "private name(s) on a public-repo high-visibility surface. Rename to a
       generic placeholder, or — if the name is load-bearing EVIDENCE rather
       than an identifier — move it to a surface this scan excludes and say why
       there. See this script's header."
  exit 1
fi

ok "no private names across ${#FILES[@]} scanned file(s) and their paths, ${#NAMES[@]} name(s) checked."
exit 0
