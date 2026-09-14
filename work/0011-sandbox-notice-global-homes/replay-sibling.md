# 0011 — replaying the notice delivery on windows-ai-sandbox

**State:** ready once macolima's C1–C2 are done. **Written:** 2026-09-14.
**Carrier:** human-ferried, like 0008's replay. W opens its own work item
from this file; the decision is [ADR-0015](../../docs/adr/0015-the-sandbox-briefs-agents-from-their-homes.md),
shared number.

## 0. Start conditions

1. macolima has landed the neutral notice, marker, `--strip`, both targets,
   the verify check and the scanner flag, converged every Mac profile, and
   stripped the blocks on the Mac.
2. Any correction found while doing that is in §3 below before the file is
   carried.

## 1. What differs on W

| | macolima | W |
|---|---|---|
| Agent home | `/home/agent` (UID 1000) | `/root` — which is why the notice says `~` |
| gemini home mount | `profiles/<p>/gemini-home` → `/home/agent/.gemini` | `~/.ai-sandbox/profiles/<p>/gemini-home` → `/root/.gemini` (`docker-compose.yml:72`) |
| Second target on the host | `gemini-home/config/rules/sandbox-notice.md` | same relative path |
| Sync call sites | `profile.sh:898` (`ensure_state`) and `:1811` (`converge`) | `profile.sh:917` and `:1849`, same shape, both `claude-home/CLAUDE.md` only |
| verify streaming | `docker exec -i "$AGENT" bash -s -- "$@" < "$src"` (`:1658`) | identical at `:1547`; add `-e NOTICE_SHA=…` the same way |
| Docs that describe a per-repo sync as automated | none | `AGENTS.md:234–238`, `docs/index.md:64` and `:107`; `scripts/sync-agent-notice.sh:13,16–18` documents a directory-glob form |
| `agent-notice.test.sh` | 13 checks | the same 13; the neutral text passes W's copy unchanged (measured on the Mac clone) |
| GPU | none | real, via `/dev/dxg` — the neutral bullet covers both; W's three CUDA bullets are gone from the shared text |
| ADR index | `docs/adr/README.md` | `docs/index.md:12–23`; add 0013 (owed by 0008) and 0015 |

## 2. Steps (R-numbered for W's item)

- **R1 — W repo, once:** adopt `sandbox_templates/common/agent-notice.md`
  verbatim from macolima; the sync script's neutral `BEGIN_MARK`, legacy
  list and `--strip`; the second target at both call sites; `NOTICE_SHA` on
  the verify exec and the verify check (`/root` paths); the scanner flag if
  W carries `workspace-scan.py`, else the equivalent grep in its scan; the
  ADR as 0015; rewrite the three doc sites in §1 (the per-repo route is
  retired, the directory-glob example goes); `just test-offline`.
- **R2 — per machine, strip:** every checkout on that machine that carries a
  block (`grep -rl 'BEGIN sandbox-notice' --include=AGENTS.md --include=CLAUDE.md --include=GEMINI.md ~/repo/`).
  **Read the region first:** on the Mac, two of eight blocks held
  repo-authored text inside the markers (live DB documentation; a webfetch
  measurement). Move such text below the markers, then `--strip`, review the
  region diff, `git add AGENTS.md`, commit per repo. Pulls from the Mac will
  already have stripped the shared ones.
- **R3 — converge every profile**, then `verify` each: both home files
  present, neutral marker, hash matches.
- **R4 — measure agy** on one signed-in profile: a word planted in
  `~/.gemini/config/rules/sandbox-notice.md` is repeated by `agy -p`. Record
  the result; if negative, drop the second target and re-record the gap.

## 3. What the Mac rollout learned

Filled in at C2. Until then, the 0008 replay's §3a items 11 and 21 are the
relevant history (the managed block was where the wrong instruction lived;
one repo, two sandboxes, one slot).

## 4. Report back

Into macolima `work/0011-…/notes.md`: W's commit; which checkouts carried
blocks and whether any held repo text; R4's result; anything in ADR-0015
that turned out wrong on Linux.
