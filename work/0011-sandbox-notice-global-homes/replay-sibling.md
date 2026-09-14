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

Filled in after C2, 2026-09-14. The 0008 replay's §3a items 11 and 21 are
the history (the managed block was where the wrong instruction lived; one
repo, two sandboxes, one slot); both now carry a supersession note pointing
here. Read the two replays together: 0008's R1 no longer re-syncs anything.

1. **Ten repos, not eight.** The scan counted marker LINES of the two known
   spellings. Two depot members (`myclickup`, `paperbridge`) carried a
   hand-written block whose BEGIN comment wraps across four lines, so no
   whole-line match saw it. Detection is now by PREFIX (`<!-- BEGIN
   sandbox-notice`) plus "skip through the END line"; W's copy of the sync
   script and its scan must do the same or they will miss the same two.
2. **Four of ten regions held repo text inside the markers.** ikigai: live
   Postgres documentation (host, port, role, DSN, how the password reaches
   `psql`). app_blast: a webfetch operating rule. myclickup and paperbridge:
   one golden-rules bullet each on lockfile discipline. Every one had to be
   moved BELOW the markers before the strip, or the strip would have deleted
   repo knowledge. Read the region first, always; diff the strip.
3. **`--strip` and update must write INTO the target, never `mv` over it.**
   The first strip landed every repo `AGENTS.md` at mode 600 (mktemp's mode),
   which a container reading the file under another uid cannot open.
   `cat "$tmp" > "$target"` keeps mode, owner and inode. A test locks it;
   port the test with the script.
4. **Prose outside the markers points at the block.** Three repos said "the
   sandbox notice above"; once the block is gone that points at nothing.
   grep for `notice above` / `notice block` after the strip and reword to
   `~/.claude/CLAUDE.md`. One commit per repo, the prose fix separate from
   the strip.
5. **The scaffold is the source.** The hand-placed blocks all came from
   `myconv`'s `apply-conventions` scaffold, which templates a block into a
   new repo's `AGENTS.md`. Until the depot handoff lands and the plugin is
   re-vendored, a fresh scaffold will plant a new block; the scanner flag
   (`NOTICE-IN-REPO`) is the tripwire.
6. **agy's global rules are still unmeasured.** The path is documented in
   agy's embedded docs (global customisation root `~/.gemini/config/`,
   `rules/*.md`, "applies to all projects"), not yet observed loading; it
   needs an interactive sign-in. R4 stands.
7. **Two commits, not one, on the Mac.** The feature landed as one commit
   (script, targets, verify, scanner, ADR, docs) and the strip's mode fix
   plus the work-item paper as a second. W can take both in one PR.

## 4. Report back

Into macolima `work/0011-…/notes.md`: W's commit; which checkouts carried
blocks and whether any held repo text; R4's result; anything in ADR-0015
that turned out wrong on Linux.
