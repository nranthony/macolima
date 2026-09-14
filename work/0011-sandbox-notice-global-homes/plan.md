# 0011 — plan

`H` = host/human step. Step IDs are stable; the replay section (§D) cites
them. Public-repo rule: `scripts/private-names-check.sh` gates
`sandbox_templates/` (the notice), `scripts/`, AGENTS.md, docs/index.md — no
profile or repo names in any of those. Names stay in this work item.

## Order of operations, and where 0008 sits

0008 is one line from exit, and that line is this item's problem (a sibling
block in ikigai's `AGENTS.md`). So 0008 does **not** wait for 0011 as a
whole; it waits for C1, the strip of the eight blocks, which is a host-side
edit the owner can do the moment the neutral notice and the tolerant sync
script exist (A1, B1–B2). Everything else in 0011 is independent of 0008.

| Stage | What | Who | Done when |
|---|---|---|---|
| A1 | Land the neutral notice + neutral marker + tolerant sync script (B1–B3), offline gate green | me | `just test-offline` |
| A2 | **Measure agy's global rules** (needs a sign-in) | owner signs in; me | agy repeats a word from `~/.gemini/config/rules/sandbox-notice.md` |
| B | profile.sh writes both targets; verify asserts both; scanner flag; docs; ADR — one PR with A1 | me | `just verify <p>` green on one profile |
| C1 | **H** strip the eight repo blocks, commit per repo | owner | `just workspace-scan --fail-on NOTICE-IN-REPO` exits 0 → **0008's done-check exits 0 too** |
| C2 | `converge` all four profiles | owner | four verifies green |
| D | Replay section ferried to the sibling | owner | its report back |
| E | Archive: 0008 first (its exit criteria are met at C1 + its own replay), then 0011 after D | me | ADRs distilled |

If A2 fails (agy does not load the global rules file), B still lands for
Claude Code and the agy target is dropped; the "gated but not briefed" gap
stays recorded with the measurement beside it. C1 still happens, because the
repo blocks are wrong regardless of where agy's briefing lives.

## Phase A — text and script (no live change)

### A1 / B1. The neutral notice

`sandbox_templates/common/agent-notice.md` ← the draft (scratchpad,
`agent-notice.neutral.md`, 133 lines, 13/13 on `agent-notice.test.sh`).
Changes from the current text, all neutrality or condensing:

- header: "Repos under this workspace are edited by an agent inside a sandbox
  container" — no sandbox name;
- every `/home/agent/…` → `~/…` (five sites);
- GPU: one bullet, "check, don't assume" — `/dev/dxg` present ⇒ WSL2
  passthrough, `nvidia-smi` by full path, leave `LD_LIBRARY_PATH`/`NVIDIA_*`
  alone; absent ⇒ no GPU is the correct answer. Replaces our four-line
  "Colima has no GPU" and the sibling's three CUDA bullets;
- "Adding a capability" folded into the persistence bullet; the dependency
  rules and the fail list tightened; nothing dropped that the test locks
  (all eight fetch-and-run spellings kept).

`agent-notice.test.sh` needs no change: its negatives fixture is a
self-contained heredoc (`:106–115`), independent of the notice text. The draft
passes 13/13 here and 13/13 on the sibling's copy of the suite, and
`private-names-check.sh` (which scans `sandbox_templates/**`) flags nothing
in it.

### B2. Neutral marker, tolerant sync

`scripts/sync-agent-notice.sh`:

- `BEGIN_MARK='<!-- BEGIN sandbox-notice (managed by the sandbox — do not edit here) -->'`;
  `END_MARK` unchanged.
- **Legacy markers**: an array of the two old BEGIN lines. `sync_one` treats
  any of the three as "marker present" and the awk replaces from whichever
  BEGIN it finds to the END. Without this, the first sync after the rename
  appends a second block into every `claude-home/CLAUDE.md` — the exact
  failure this item exists to remove.
- `--strip <target>…`: remove the marker region (any of the three BEGINs to
  END) **and the one blank line after END**. All eight live blocks were
  prepended under the repo's `# Title` + blank (the conventions scaffold's
  instruction), so the blank before BEGIN is the title's own spacing; the
  stray one is after END. Prints `stripped <file>` / `no block <file>`. C1
  uses it; nothing automated does.
- Keep bash 3.2 / POSIX awk (the header's portability promise).

Tests: a new `scripts/sync-agent-notice.test.sh` (join `test-offline`):
fresh file → created; no marker → appended; each of the three markers →
updated, exactly one block afterwards; `--strip` on each → no marker, the
rest byte-identical; idempotent (second sync no diff).

### B3. Conventions skill and hook

- `sandbox_templates/skills/myconv/…/apply-conventions` is vendored (depot
  channel), so this is a **handoff to the depot**, not an edit here. Checked:
  the marker shape is already a placeholder (`agentic_native_repo_scaffold.md:323,334`,
  `managed by <sandbox-tool>`), so the rename breaks nothing; but the scaffold
  actively **instructs** repos to place the block at the top of the root
  `AGENTS.md` (`:75`, `:229`, `:314`) and builds rules on its presence
  (`:368`, `:526`, `SKILL.md:63`). The handoff covers the instruction, not
  just the string: "the sandbox writes its notice into the agent's home; a
  repo never carries one; a block met in the wild is stale, report it". No
  test or probe in either repo greps the literal markers.
- `deny-destructive.sh` matches `agent-notice.md` by basename for the
  docs-install-cmd WARN; no change.

## Phase B — delivery (one PR with A1)

### B4. `profile.sh`: both targets on `up` and `converge`

At the two call sites (`:898` and `:1811`), after the existing
`claude-home/CLAUDE.md` sync:

```sh
bash "$SCRIPT_DIR/scripts/sync-agent-notice.sh" \
  "$p/gemini-home/config/rules/sandbox-notice.md" >/dev/null \
  || warn "could not sync sandbox-notice into gemini-home/config/rules/"
```

Call sites, checked: site 1 is `profile.sh:898` inside `ensure_state`, which
runs on `up`, `recreate` and `rebuild`; site 2 is `:1811` in the `converge`
arm. So both targets reach every verb that touches state. `sync_one` creates
the file (and `rules/`) when absent via `mkdir -p`. `gemini-home/config/`
exists on every profile because `converge_antigravity_hooks` (`:816`) mkdirs
it for `hooks.json`, and `converge_agent_policies` runs before both sites
(`:892` < `:898`; `:1808` < `:1811`). `ensure_state` itself creates only
`gemini-home/`. Nothing mirrors or wipes `gemini-home/config/` (the policy
merge writes `antigravity-cli/settings.json`, a different directory).
Ownership is fine: everything under the mount reads as `agent:agent`
in-container (measured). Mode note: `sync_one`'s create path yields 644, its
update path 600 (`mktemp` + `mv`), which is why every `claude-home/CLAUDE.md`
is 600 today; harmless, add a comment rather than a chmod.

### B5. `verify-sandbox.sh`: both files carry the current block

Inside the container the script can see `~/.claude/CLAUDE.md` and
`~/.gemini/config/rules/sandbox-notice.md` but not the template. **Checked:
no host→container value channel exists today.** `profile.sh:1658` is
`docker exec -i "$AGENT" bash -s -- "$@" < "$src"` with nothing prepended;
`check_allowlist_sync` runs host-side against the proxy container and
reports through shell variables. Two cheap channels are available:
`docker exec -e NOTICE_SHA=<sha256 of the template> …` (verify-sandbox never
reads `$@`, so a positional arg would also work but shifts the verb's args).
**Decision (owner Q3):** either pass the hash via `-e` and compare against
the region between the neutral markers in each file (catches "converge not
run since the template changed"), or assert only file-present + neutral
marker + no legacy marker (zero new plumbing; catches the migration failure
this item is about but not staleness). `fail` messages say "run `converge`".
`sha256sum` is in the image (coreutils). The sibling's verify streams the
same way (`profile.sh:1547`), so §D inherits the choice.

### B6. Scanner: `NOTICE-IN-REPO`

`scripts/workspace-scan.py`: for every `AGENTS.md`, `CLAUDE.md` (and
`GEMINI.md`, owner Q6) in a git repo, root and tracked nested, any line
starting `<!-- BEGIN sandbox-notice` → ACTION `NOTICE-IN-REPO`, evidence the
marker line and its `managed by` name. **Checked:** `check_agents` (`:309`)
tests `AGENTS.md` with `is_file()` only and never reads it, and `GEMINI.md`
is not enumerated (`:330` filters to AGENTS/CLAUDE), so both are new reads,
not reuse. Nested exclusion reuses `nested_excluded()` (`:301`), which
already covers `archive`/`_archive` parts and fixture paths; no extra path
exclusions are needed while the filename filter holds (the template and the
test fixtures have other names). A new finding id needs no registry:
`r.add("NOTICE-IN-REPO", ACTION, …)` and `--fail-on` matches the string
(`:850`). Test in `workspace-scan.test.sh` (real git fixtures, `mkrepo`):
a repo with each of the three markers is flagged; one with a root `AGENTS.md`
and no marker is not.

### B7. Docs and ADR

- New ADR **0015** (macolima's highest is 0013; 0014 is reserved across
  seven citations in `work/0010`; the sibling's highest is 0012 and its index
  is `docs/index.md:12–23`, it has no `docs/adr/README.md`): "The sandbox
  briefs agents from their global homes, never from a repo". Context (the
  eight stale blocks, the marker fight, the read-only-region rule),
  decision (§3), consequences (two generated files, no repo blocks, the
  scanner flag), the measurements (§2, with A2's result), rejected
  alternatives (workspace root; neutral per-repo blocks; Claude importing
  from agy's home).
- `sandbox_templates/antigravity/README.md`: the whole "Open: agy has the
  policy but not the guidance" section (`:49–79`) goes. It asserts there is
  no global context file to write into (what A2 tests) and prints a
  **per-repo** sync recipe with a hard-coded `/Volumes/DataDrive/repo/…`
  path (`:63–68`), the route 0011 forbids, in a file the private-names gate
  scans. Replacement: "briefed from `~/.gemini/config/rules/`", A2's
  measurement, and the tier note (global rules merge under workspace rules,
  they do not override).
- `docs/extending-a-profile.md` rows ~60–61: "standing instructions for every
  repo in a profile" → the two global files; the per-repo row loses the
  notice case.
- `scripts/sync-agent-notice.sh` header: the usage examples drop the
  directory-glob form (a directory arg still works, but the documented use is
  the two home files); add `--strip`.
- AGENTS.md: one invariant bullet ("the notice is written into both agent
  homes on every `up`/`recreate`/`rebuild`/`converge`; never into a repo;
  marker is neutral") and a pointer row — net new, AGENTS.md says nothing
  about the notice today. `just sync-agent-files`.
- `docs/adr/README.md` index row, and a `docs/index.md` row for the sync
  script and its two tests (also net new: `docs/index.md` has no reference
  to either today).

### B8. Offline gate

`just test-offline`: hook suite, `agent-notice.test.sh`, the new sync test,
`workspace-scan.test.sh`, private-names, sync-agent-files `--check`.

## Phase C — activation

### C1 (H). Strip the eight repos

From the host, once B2 exists:

```sh
scripts/sync-agent-notice.sh --strip \
  /Volumes/DataDrive/repo/nranthony/{project_zenbu,ikigai,numerai} \
  /Volumes/DataDrive/repo/therapod/{pipeline,app_blast,engine} \
  /Volumes/DataDrive/repo/fluidmomenta/agentic_admin_research_ga \
  /Volumes/DataDrive/repo/jeremy_dahl/jeremy_dahl_analytics
```

**Before the strip, rescue repo text from inside the markers (owner Q1, Q2).**
Checked: all eight hold exactly one pair, all the sibling's marker, all at
line 3 under the repo's title. Six are pure sandbox text (two of them
byte-identical to the sibling's current template, four older and shorter).
Two are not:
- **ikigai** (`3→224`): ~19 live lines under the DB bullet — database name,
  `resolve_database_url`, the alembic head, the `PGPASSWORD … psql` recipe —
  are the repo's own documentation. Move them below the markers first.
- **app_blast** (`3→210`): ~26 lines measuring that the image's `webfetch`
  binary lags its docs (which backends the July build accepts, `--via`
  defaulting), plus a "don't trust a written statement of which backend is
  up" rule. Part stale, part live; the owner decides what moves.

Then `--strip`, review each diff **of the region contents** (not just the
surroundings), and commit per repo with `git add AGENTS.md` — two of the
eight (`agentic_admin_research_ga`, `jeremy_dahl_analytics`) carry an
uncommitted `.vscode/settings.json` that `commit -a` would sweep in.
Message: "chore: drop the sandbox notice block — the sandbox now briefs
agents from their home (macolima ADR-0015)". Not pushed by me.
`just workspace-scan --fail-on NOTICE-IN-REPO` → 0, and with it
`--fail-on HARDCODED-VENV-LINUX,OS-VENV-SELECT` → 0: **0008 exits here.**

ikigai's own docs echo two claims from the stale block ("`uv sync` is
denied", "`.venv/` is irreplaceable" — its ADR-0014 rule 5, README:10, the
checkpoint-gate skill). Those are the repo's text, not the block's: one line
in the ikigai hand-back's "still the owner's" list, already there.

### C2 (H). Converge every profile

`scripts/profile.sh <p> converge` ×4 (no recreate: both targets are files in
mounted homes). Then `just verify <p>` ×4 with B5 green.

## Phase D — the sibling (ferried)

A section appended to a new `replay-sibling.md` in this item, same shape as
0008's: what differs (`/root`, its Dockerfile `ENV`, its docs that describe
the per-repo sync as automated at `AGENTS.md:234–238` and `docs/index.md:107`,
its script's directory-glob examples), and the order R1 (adopt the neutral
text and marker, tolerant sync, second target, verify, scanner flag), R2
(strip on each machine's checkouts), R3 (converge), R4 (report: which repos
carried blocks, A2's result on its own agy). It carries the eight repo names
only as "the repos your scan flags".

## Phase E — archive

0008 archives at C1 (its replay already ferried, its exit criteria met; the
ADR-0013 is the durable record). 0011 archives after D's report; the ADR
from B7 is its record.

## Check against the code (2026-09-14)

Every code-facing claim above was verified against the scripts; corrections
are folded in place (B4 line numbers and the `config/` creator; B5's
non-existent prepend channel; B6's "already opened" files; A1's fixture
coupling; C1's prepended-not-appended blocks and the two repos with text
inside the markers; B7's ADR number, README section and net-new index rows).

**Questions for the owner:**

1. ikigai's ~19 lines of live Postgres documentation inside the markers:
   move below the markers in the strip commit (recommended), or hand to the
   ikigai agent?
2. app_blast's ~26 lines of webfetch measurement inside the markers: keep
   the operating rule and drop the July-binary facts (recommended), or keep
   all, or drop all?
3. B5: hash via `docker exec -e` (catches staleness; new plumbing in both
   sandboxes), or marker-only assertion (zero plumbing; catches migration
   only)? Recommended: hash via `-e`, it is one flag.
4. ADR-0015 for this item, leaving 0014 to 0010 as already cited? Recommended.
5. `--strip` trims the blank after END? Recommended yes.
6. Scanner also enumerates `GEMINI.md`? Recommended yes, it is agy's other
   name for the same file.
7. `git add AGENTS.md` per repo, leaving the two dirty `.vscode/settings.json`
   alone? Recommended yes.
