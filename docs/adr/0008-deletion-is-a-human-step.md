# ADR-0008 — Deletion is proposed, not performed

- **Status:** Accepted (2026-09-03)
- **Deciders:** nranthony + agent

## Context

`/workspace` is a host bind mount of a real git tree, and the agent runs in
`acceptEdits`. The irrecoverable things in this system are few and specific:
unpushed code in `/workspace`, Claude session history, and database rows.
Nothing regenerates them.

Matcher-level denies cannot carry this rule, because destructiveness here is a
property of *flag shape and argument list*, not of the command prefix:
`rm -rf` and `rm file.txt` share a prefix, and `find . -delete` is a `find`.

## Decision

**Every file deletion is proposed first — single files included, and even when
an approved plan names them.**

Three tiers, enforced by the `PreToolUse` hook rather than the matcher:

1. **DENIED outright** — recursive deletion in every spelling: `rm -rf`,
   `find -delete`, `git clean`.
2. **ASK, every time** — `rm` of anything non-disposable, `unlink`, `git rm`,
   the discarding forms of `git checkout`/`git restore`, `git stash
   drop`/`clear`, `git branch -d`/`-D`.
3. **Never prompts** — genuinely disposable paths: `/tmp`, `/var/tmp`,
   `/home/agent/.cache`, and anything inside a `.venv`, `node_modules`,
   `__pycache__`, a `.pytest_cache`/`.mypy_cache`/`.ruff_cache`, a `build` or
   `dist` directory, or any `*.pyc`.

**One non-disposable path anywhere in the argument list makes the whole command
ask.**

## Consequences

- **With no human at the prompt — a subagent, or a non-interactive run — the
  call does not happen** and the agent receives the notice instead. That is the
  designed outcome: stop and report what you wanted to delete.
- **Decomposing a blocked bulk delete into one-file-at-a-time calls is
  explicitly named as the thing these rules exist to catch.** Stating it in the
  notice is part of the control, because the decomposition is otherwise a
  reasonable-looking next step.
- Ordinary cleanup stays frictionless, which is what keeps the ask tier
  credible. A rule that fires on `rm -rf node_modules` gets routed around.
