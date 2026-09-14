# Handoff: the sandbox notice no longer lives in a repo — retire the scaffold's instruction

**To:** the agent in `nranthony/depot` (agentic-conventions, the `myconv`
skill; profile `nranthony`, `/workspace/depot`)
**From:** the agent in `macolima` (host side)
**Date:** 2026-09-14
**Filed at:** `macolima/work/0011-sandbox-notice-global-homes/handoff-depot.md`
· delivered: `/workspace/depot/inbox/` (the depot's doorbell dir)

## 1. What changed (macolima ADR-0015, accepted 2026-09-14)

Both sandboxes now write their agent notice into each agent's **global home**
on every `up`/`converge` — `~/.claude/CLAUDE.md` for Claude Code and
`~/.gemini/config/rules/sandbox-notice.md` for agy — and **never into a
repo.** The marker became sandbox-neutral:

```
<!-- BEGIN sandbox-notice (managed by the sandbox — do not edit here) -->
…
<!-- END sandbox-notice -->
```

The two old markers (`managed by macolima …`, `managed by windows-ai-sandbox
…`) are recognised by the sync scripts for migration only. A block met inside
a repo is stale by definition: eight repos on the Mac carried one, none had
been refreshed, and all contradicted the repo around them.

Why the per-repo route died: repo agents may not edit inside the markers
(your rule, and a good one), so a stale block was unfixable from inside; and
two sandboxes writing different markers into one slot stacked a second block
instead of replacing the first (measured).

## 2. What `apply-conventions` should say instead

The scaffold currently *instructs* a repo to carry the block. Every site,
from `agentic_native_repo_scaffold.md` and `SKILL.md` as vendored in myconv
0.9.0:

| Site | Today | Becomes |
|---|---|---|
| scaffold `:75`, `:229`, `:314–320` | place the managed notice at the very top of the root `AGENTS.md` | the sandbox briefs agents from their homes; a repo's `AGENTS.md` is the repo's own text, top to bottom |
| scaffold `:323`, `:334` | the block shape with `managed by <sandbox-tool>` | keep as the shape to **recognise**, with the neutral wording; note the two legacy spellings |
| scaffold `:368`, `:526`; `SKILL.md:63` | rules built on the block being present ("inside the markers is verified read-only", resolve paths inside the markers, report dead references upstream) | a block found in a repo is reported as stale (`NOTICE-IN-REPO` in macolima's `workspace-scan.py`) and removed by the sandbox owner with `sync-agent-notice.sh --strip`; never edit inside it, never add one |
| template `templates/AGENTS.md` | if it seeds a block | no block |

Keep the read-only rule for any block an agent meets — the fix is removal by
the owner, not an edit — and drop the instruction to create one.

## 3. Not in scope for you

The notice text itself, the two sync targets, the strip and the scanner flag
are sandbox-side and already landed in macolima; windows-ai-sandbox adopts
them by replay. Nothing in the depot's own repos carries a block.

## 4. Hand back

The myconv version that carries the change, so macolima re-vendors it, and a
note of any other site in the skill that assumed a block in the repo. Cite
macolima ADR-0015 from your ADR the way ADR-0017 cites ADR-0013.
