# 0011 — The sandbox notice: one neutral text, delivered to each agent's global home, never into a repo

**State:** spec + plan, checked against the code 2026-09-14; not started.
**Opened:** 2026-09-14, from 0008's ikigai hand-back (a stale sibling-managed
notice block was the last line failing 0008's done-check).
**Plan:** [plan.md](plan.md). **Sibling side:** plan §D, ferried.

## 1. The problem

The sandbox notice (`sandbox_templates/common/agent-notice.md`) is the
briefing that tells an agent what fails here, what is a human step, and how
venvs, web reads and databases work. It reaches agents three ways today, and
two of them are wrong.

| Route | Who reads it | State |
|---|---|---|
| `profiles/<p>/claude-home/CLAUDE.md`, marker region replaced on every `up` and `converge` (`profile.sh` `:898` in `ensure_state`, `:1811` in `converge`) | Claude Code, every session, any cwd | **Works.** One file per profile, regenerated from the template. |
| A marker block inside a repo's `AGENTS.md` | Claude Code (via the stub) and agy | **Eight repos on this drive carry one, and every one of them is the sibling's** (`managed by windows-ai-sandbox`), placed by hand, never refreshed, and now contradicting the repos they sit in (ikigai: "`uv sync` is denied", `UV_PROJECT_ENVIRONMENT=.venv-linux`). macolima has never written a block into a repo. The sibling documents a per-repo sync as if automated, but no verb runs it (its `profile.sh` syncs only `claude-home/CLAUDE.md`, like ours). |
| Nothing | agy | **The gap** `sandbox_templates/antigravity/README.md` records as "gated but not briefed": agy inherits the hook and the env, but no text tells it why things fail. |

Two defects follow from the repo route, both measured in 0008:

- **The block is not neutral, so two sandboxes fight over one slot.** Each
  sync script writes its own marker (`managed by macolima` / `managed by
  windows-ai-sandbox`), so running one over the other's block appends a second
  block instead of replacing it. The text differs only in the home path
  (`/home/agent` vs `/root`), the venv bullet the sibling has not adopted yet,
  and two contradictory GPU sections; the other ~85% is byte-identical.
- **Repo agents may not edit inside the markers**, by the conventions skill's
  rule, so a stale block is unfixable from inside the repo and stays wrong
  until a human touches it. That is what kept 0008's done-check red.

## 2. Measured facts (2026-09-14)

| Claim | Result |
|---|---|
| Claude Code (2.1.270) loads a `CLAUDE.md` from an ancestor directory of the cwd | **yes** — a parent's text appeared alongside the child's |
| `@` imports inside that ancestor file are followed | **no** — `@AGENTS.md`, `@./AGENTS.md`, an absolute path and `@../AGENTS.md` all failed; the same `@AGENTS.md` in the cwd's own `CLAUDE.md` resolved |
| `~/.claude/CLAUDE.md` is loaded every session | in use since 0005; not re-measured |
| agy (1.2.0) loads `AGENTS.md` from ancestors of the cwd | **docs only:** "walks up from the current working directory to the repository root (the folder containing `.git`)" — a file above the repo root is outside the walk |
| agy has a global rules location | **docs only:** `~/.gemini/config/` is a customization root that "applies to all projects and workspaces"; within any root, rules live in `rules/` or as a standalone `AGENTS.md`/`GEMINI.md`; rules merge and deduplicate rather than override |
| agy accepts `/tmp` as a workspace with no trust flag | yes (server log) |

The agy rows could not be measured: the `nranthony` profile has no
Antigravity sign-in and sign-in is interactive. The measurement is plan step
A2 and takes a minute once someone has signed in.

## 3. The rule (owner decision, 2026-09-14)

**One neutral notice, written by the sandbox into each agent's global home,
and never into a repo.**

- The text names no sandbox and no user: `~` for the agent home, one GPU
  bullet ("a GPU exists only if `/dev/dxg` does"), the venv bullet as the rule
  both sandboxes now share (ADR-0013). Drafted and passing
  `agent-notice.test.sh` at 133 lines against 196.
- The marker is neutral too: `managed by the sandbox — do not edit here`. The
  sync script recognises the two old markers once, so migration replaces
  rather than stacks.
- Two targets per profile, both regenerated on every `up` and `converge` from
  the one template, so they cannot drift from it or from each other:
  - `claude-home/CLAUDE.md` (`~/.claude/CLAUDE.md`) — as today;
  - `gemini-home/config/rules/sandbox-notice.md` (`~/.gemini/config/rules/`)
    — new. Neither file points at the other: agy has no import syntax, and
    making Claude's briefing import from agy's home would couple the two
    mounts for the price of one 133-line write.
- **No notice block in any repo.** The eight stale blocks are stripped once,
  host-side, by the owner (an edit to the owner's own tree, not an agent
  mutating a target repo). `workspace-scan.py` gains `NOTICE-IN-REPO` so a
  block cannot come back through a pull unnoticed. That flag is this item's
  done-check.

**Rejected: a file at the workspace root** (`/workspace/AGENTS.md` +
`/workspace/CLAUDE.md`). For Claude Code the root file would need the full
text (imports there are not followed), duplicating a global file that already
works. For agy the root is above every repo's `.git`, outside its documented
walk. And the scanner sees only git repos, so the root pair would be a blind
spot. It also would not have removed the repo blocks.

**Rejected: keep per-repo blocks, make them neutral.** Fixes the marker fight
and leaves the unfixable-from-inside problem, the hand-placed drift, and the
eight-way duplication.

## 4. Non-goals

- Repo-level guidance (`AGENTS.md` as source, `CLAUDE.md` stub) — that is
  0009, done.
- The sibling's own notice content beyond neutrality; it adopts the text and
  the two targets by replay (plan §D), the same way 0008 did.
- Any change to what the notice *says* about policy. This is delivery and
  neutrality; wording changes ride along only where a sandbox-specific
  sentence had to become neutral.

## 5. Exit criteria

- `converge` on every profile writes both targets; `just verify <p>` asserts
  both carry the current block (a hash of the template, compared inside the
  container).
- agy measured loading `~/.gemini/config/rules/sandbox-notice.md` in one
  profile (A2), recorded in notes.
- `just workspace-scan --fail-on NOTICE-IN-REPO` exits 0 across all four
  profiles.
- `sandbox_templates/antigravity/README.md` no longer lists "gated but not
  briefed".
- ADR (next free shared number) accepted; the replay section ferried; the
  sibling's report back per that section.
