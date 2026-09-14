# ADR-0015 — The sandbox briefs agents from their global homes, never from a repo

- **Status:** Accepted (2026-09-14)
- **Deciders:** nranthony + agent
- **Work item:** `work/0011-sandbox-notice-global-homes/`

## Context

The sandbox notice (`sandbox_templates/common/agent-notice.md`) is the text
that tells an agent what fails here, what is a human step, and how venvs, web
reads and databases work. It reached agents by two routes. One worked: the
marker region in each profile's `claude-home/CLAUDE.md`, regenerated on every
`up` and `converge`, which Claude Code loads in every session. The other did
not: a marker block placed by hand at the top of a repo's `AGENTS.md`, the
route the conventions scaffold instructed and the sibling repo documented as
automated. No verb in either sandbox ever ran it.

Eight repos on this drive carried such a block, every one the sibling's,
never refreshed, and by 2026-09-14 contradicting the repos around them (one
told agents to `export UV_PROJECT_ENVIRONMENT=.venv-linux`, two said
`uv sync` was denied). Two defects made them unfixable in place:

- **The block was not neutral.** Each sandbox wrote its own marker
  (`managed by macolima` / `managed by windows-ai-sandbox`), so one sync run
  over the other's block appended a second block instead of replacing it.
  Measured. The texts differed only in the home path, one venv bullet, and
  two contradictory GPU sections; the other ~85% was byte-identical.
- **Repo agents may not edit inside the markers**, by the conventions
  skill's rule. A stale block therefore stayed wrong until a human touched
  the repo. That block was the last line failing work/0008's done-check.

Meanwhile agy, the second agent in every profile, had no briefing at all:
"gated but not briefed" was a recorded gap, on the belief that agy had no
global context file to write into.

Measured before deciding (2026-09-14):

- Claude Code 2.1.270 loads a `CLAUDE.md` from an ancestor directory of the
  cwd, but does not follow `@` imports inside that ancestor file, in any
  spelling. The same import in the cwd's own file resolves.
- agy 1.2.0's embedded documentation: rules (`AGENTS.md`, `GEMINI.md`, or
  `rules/*.md`) are discovered by walking "from the current working
  directory to the repository root (the folder containing `.git`)", and
  separately from the global customization root `~/.gemini/config/`, which
  "applies to all projects and workspaces". Rules merge and deduplicate; they
  do not override each other. The global path is documented, not yet
  observed: the measurement needs an Antigravity sign-in and is recorded in
  the work item when done.

## Decision

**One neutral notice, written by the sandbox into each agent's global home
on every `up`, `recreate`, `rebuild` and `converge`, and never into a repo.**

- The text names no sandbox and no user: the agent home is `~`, the GPU
  bullet is "a GPU exists only if `/dev/dxg` does", and the venv bullet is
  the rule both sandboxes share ([ADR-0013](0013-the-environment-names-the-venv.md)).
- The marker is neutral: `managed by the sandbox — do not edit here`. The
  sync script recognises the two old markers so migration replaces rather
  than stacks.
- Two targets per profile, both regenerated from the one template:
  `claude-home/CLAUDE.md` (`~/.claude/CLAUDE.md`) and
  `gemini-home/config/rules/sandbox-notice.md` (`~/.gemini/config/rules/`).
  Neither points at the other. agy has no import syntax, and making Claude's
  briefing import from agy's home would couple two mounts to save one write.
- No notice block in any repo. Blocks placed by hand are stripped once,
  host-side, with `scripts/sync-agent-notice.sh --strip`; the workspace scan
  flags any that return (`NOTICE-IN-REPO`); `verify-sandbox.sh` asserts both
  home files carry the current template, by hash, so a stale converge fails
  loudly.

## Consequences

- The "gated but not briefed" gap closes for agy, subject to the
  measurement above. If agy does not load the global rules file, the second
  target is dropped and the gap is re-recorded with the measurement beside
  it; nothing else in this decision changes.
- A repo's `AGENTS.md` is the repo's own text, top to bottom. The conventions
  scaffold's instruction to place a notice at its top is retired (a depot
  handoff); a block met in the wild is stale by definition.
- The sibling adopts the same text, marker and two targets by replay. Its
  home is `/root`, which is why the text says `~`.
- `verify` passes its first host-computed value into the streamed check
  script (the template's hash, as an environment variable). Until now the
  script could see nothing of the repo.

## Rejected alternatives

- **A file at the workspace root** (`/workspace/AGENTS.md` plus a
  `/workspace/CLAUDE.md` stub), one location per profile that both agents
  would read. For Claude Code the root file would need the full text (imports
  there are not followed), duplicating a global file that already works. For
  agy the workspace root is above every repo's `.git`, outside its documented
  walk. The scanner enumerates git repos only, so the root pair would be
  unvalidated. And it would not have removed the repo blocks.
- **Neutral per-repo blocks.** Ends the marker fight and keeps the
  unfixable-from-inside rule, the hand-placed drift and the n-way copies.
- **Claude's home file importing agy's rules file.** One real copy, two
  coupled mounts, and a briefing that disappears if the gemini home is
  missing.
- **Automating the per-repo sync** on `up`. The sibling's own objection
  stands: a container start should not rewrite files in the operator's git
  tree.
