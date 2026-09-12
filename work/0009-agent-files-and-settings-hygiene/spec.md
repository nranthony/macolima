# 0009 — Agent instruction files and Claude settings, across every repo

**State:** spec only, not scheduled. **Opened:** 2026-09-11, split out of
[0008](../0008-venv-per-environment/spec.md) by owner decision. 0008 keeps the
venv half of the scan; this item takes the half that isn't about venvs.

**Source:** the 0008 all-repo scan, `just workspace-scan` (`scripts/workspace-scan.py`),
run 2026-09-11 over all four profiles plus the host-only `sandbox/` root. The
full per-repo report is local only (`work/0008-venv-per-environment/scan.local.md`,
untracked); this spec names only repos that need action.

## 1. The rule being enforced

**AGENTS.md is the source; CLAUDE.md is a stub that imports it.** Two agents
run in every profile, and they read different files:

- Claude Code reads `CLAUDE.md`, never `AGENTS.md` on its own ("Claude Code reads
  `CLAUDE.md`, not `AGENTS.md` … create a `CLAUDE.md` that imports it",
  code.claude.com/docs/en/memory).
- agy reads `AGENTS.md`.

So a repo with only a `CLAUDE.md` gives agy nothing, and a repo with two
separate files gives the agents two diverging sets of instructions. Valid stub
shapes, all accepted by the scanner: a line `@AGENTS.md`; an inline import
(`See @AGENTS.md for …`); or `CLAUDE.md` symlinked to `AGENTS.md`. An import
inside a code span or fenced block is **not** an import: Claude Code skips
those. macolima's own `scripts/sync-agent-files.sh` writes the first shape and
is the reference.

**Machine-local files stay local.** `.claude/settings.local.json` is one
machine's accumulated approvals. Committed, it ships this machine's host paths
and grants to every clone and container.

## 2. Findings (2026-09-11)

| ID | # | Repos |
|---|---|---|
| `CLAUDE-ONLY` | 20 | fluidmomenta: clickup, takeaction, website · nranthony: VoiceInk, arxivqml, ikigai, ikigai_delete_or_not, job_search_agent, lifetime, mercor_boilerplate, my-agentic-tools, quantum-computing-fundamentals-2833097, research-assist · therapod: app_zero, core, engine, financials, misc_code, reference_agentic, web |
| `BOTH-SUBSTANTIVE` | 2 | nranthony/shrec (184-line CLAUDE.md, no import), nranthony/webridge (88 lines, no import) |
| `NESTED-CLAUDE-ONLY` | 2 | nranthony/mac_docker `claude_init_files/` (possibly template payload; check before migrating), therapod/core `core/` |
| `TRACKED-LOCAL` | 4 | tracked `.claude/settings.local.json` in therapod/app_blast (`apps/dashboard/`), therapod/app_zero, therapod/wearable_data_testing (the last carries host-path grants: `Read(//Volumes/…)`, `Write(/Users/…/.crawl4ai/**)`); nranthony/VoiceInk `VoiceInk.local.entitlements` (Xcode, legitimately committed: needs a repo `!` exception, not untracking) |
| `CLAUDE-NOT-TRACKED` | 1 | nranthony/research-assist: its CLAUDE.md exists but isn't committed |
| `NO-AGENT-FILES` | 17 | informational: course material, dotfiles, archived sites. **In scope only if the owner says the repo is live** (§4) |

**Security, outside the file-shape rule but found by the same scan:**
therapod/project-mgmt's *local* (gitignored) settings allow
`Read(//Users/neilanthony/**)`. That makes the whole home directory readable,
`~/.ssh` and credential files included, whenever an agent works in that repo
on the Mac host. Narrow it to the paths actually needed.

## 3. The fixes, by shape

- **CLAUDE-ONLY** — mechanical and reversible: `git mv CLAUDE.md AGENTS.md`,
  then write the stub `CLAUDE.md`. Then read the moved text for Claude-only
  wording that agy should also follow, or should not. Where the repo has
  adopted myconv, `apply-conventions` does this; elsewhere it is a two-file
  commit.
- **BOTH-SUBSTANTIVE** — a merge, not mechanical: fold CLAUDE.md's content into
  AGENTS.md, resolve contradictions, then write the stub. It needs the repo's
  owner-context, so it is agent work *inside* that repo.
- **NESTED-CLAUDE-ONLY** — decide first whether the directory is guidance or
  payload. Payload gets excluded from the scan (it has an exclude list); guidance
  gets the CLAUDE-ONLY fix.
- **TRACKED-LOCAL `settings.local.json`** — `git rm --cached`, which keeps the
  file, plus the `.local` ignore pair from 0008 wave 2. **Order matters:** land the
  ignore first, or the next `git add -A` re-adds it. Any grant that should be
  shared moves to the tracked `settings.json` in its `uv run …` / scoped form.
- **VoiceInk** — `!VoiceInk/VoiceInk.local.entitlements` beside the `.local` pair.
- **CLAUDE-NOT-TRACKED** — commit it (as a stub, after the CLAUDE-ONLY fix) or
  state why it stays local.

## 4. Decisions (owner, 2026-09-12)

1. **Live = a commit in the last six months.** Measured 2026-09-12 against a
   2026-03-12 cutoff, from each repo's last commit date.
2. **Bundle with 0008 wave 2.** One handoff per repo covers both items, so each
   repo is opened, reviewed and committed once.
3. **A host-side pass**, by me, for the mechanical work. The two
   `BOTH-SUBSTANTIVE` merges need the repo's own agent and its context — the
   owner starts those separately (see §4.1).

### 4.1 The live subset

**Live `CLAUDE-ONLY` (10 of 20)** — the host pass:
fluidmomenta/takeaction, fluidmomenta/website · nranthony/VoiceInk,
nranthony/ikigai · therapod/app_zero, therapod/core, therapod/engine,
therapod/financials, therapod/misc_code, therapod/web.

**Dormant, skipped (10):** fluidmomenta/clickup (2026-03-08) · nranthony:
arxivqml, ikigai_delete_or_not, job_search_agent (2026-03-08), lifetime,
mercor_boilerplate, my-agentic-tools, quantum-computing-fundamentals-2833097,
research-assist · therapod/reference_agentic (2026-03-06). Three sit within a
week of the cutoff (clickup, job_search_agent, reference_agentic): if any comes
back to life, it joins the pass rather than being re-argued.

**Needs its own repo agent, both live:** nranthony/shrec (2026-06-02),
nranthony/webridge (2026-04-23). Merging two substantive instruction files is a
judgement about which rules survive, not a rename.

**Also live, so in scope:** the nested cases (nranthony/mac_docker, and
therapod/core's `core/`) and all four `TRACKED-LOCAL` repos (therapod/app_blast,
app_zero, wearable_data_testing; nranthony/VoiceInk's Xcode exception).
research-assist's untracked CLAUDE.md is dormant, so it stays as it is.

## 5. Exit

For every repo the owner marks live:
`just workspace-scan --fail-on CLAUDE-ONLY,BOTH-SUBSTANTIVE,NESTED-CLAUDE-ONLY,TRACKED-LOCAL`
exits 0, or each remaining hit has a recorded reason. The project-mgmt home-dir
grant is narrowed.
