# Handoff: the sandbox now names its own venv — retire pipeline's `.venv-linux` and its OS switch, in one pass

**To:** the agent working in `therapod/pipeline` (sandbox profile `therapod`, `/workspace/pipeline`)
**From:** the agent in `macolima` (host side)
**Date:** 2026-09-11 (rewritten the same day: final form, applied after the switch)
**Reciprocal-to:** —
**Filed at:** `macolima/work/0008-venv-per-environment/handoff-pipeline.md` ·
delivered: `/workspace/inbox/0008/handoff-pipeline.md` (the therapod workspace
root, outside every repo; this repo has no `inbox/`)

## 0. Precondition — check before touching anything

```sh
echo "$UV_PROJECT_ENVIRONMENT"
```

It must print **`.venv-sandbox`**. If it prints nothing, **stop and report**:
the switch hasn't reached this container yet. In that state a `uv run` or
`uv sync` here would treat the Mac's `.venv` as its target and rebuild it. This
caveat belongs to this handoff only; nothing you write into the repo should
repeat it.

## 1. What changed

Owner decision, 2026-09-11 (macolima work/0008). **The environment names the
venv; a repo never chooses it:**
- every sandbox container exports `UV_PROJECT_ENVIRONMENT=.venv-sandbox`;
- every host (macOS, WSL, bare Linux, CI runners) leaves it unset, so uv uses
  `.venv`.

uv reads the variable itself and resolves it against the project root. So
`uv sync` / `uv run` pick the right venv everywhere with no help from this
repo. **Choosing a venv by OS is exactly what the rule retires:** a Linux host
and the Linux sandbox are both "linux", and on the WSL / bare-Linux machines
they share a checkout. This repo pins `.venv-linux` in 117 lines across about
30 files, and chooses it by OS in two places.

**One exception: `uv pip …` ignores the variable** and falls back to `.venv`,
which in the container is the host's. Wherever this repo documents or runs
`uv pip`, prefer `uv sync` / `uv run`; if it must stay, give it
`--python "${UV_PROJECT_ENVIRONMENT:-.venv}"`.

**Write everything for the end state:** docs describe `.venv` (host) and
`.venv-sandbox` (sandbox, selected by the variable); commands use `uv run …`.
No transitional wording.

## 2. What does NOT change

- The host keeps `.venv`. The macOS `just` path behaves exactly as before.
- `PIPELINE_VENV` stays the explicit override.
- **Nothing is deleted.** The old `.venv-linux/` stays on disk, unused, until
  the owner removes it after a clean run. Removing it is a human step, and not
  part of this handoff.
- Tests, recipes and the database setup are unchanged; only which venv they run in.

## 3. What to change — checks, not claims

Read from a host-side copy at `4551275` (2026-09-07); yours may be newer. Find
every live reference with:

```sh
git grep -n -e '\.venv-linux' -e 'os() == "macos"' -- . ':!work/archive' ':!docs/_archive' ':!docs/adr'
```

**Files that are executed or followed. Each must change:**

| Where | Now | End state |
|---|---|---|
| `just/vars.just:20-22` | `default_venv := if os() == "macos" { ".venv" } else { ".venv-linux" }` + `venv := env_var_or_default("PIPELINE_VENV", default_venv)` | `venv := env_var_or_default("PIPELINE_VENV", env_var_or_default("UV_PROJECT_ENVIRONMENT", ".venv"))`; drop `default_venv` and its comment |
| `justfile:215-222` (`install`) | comment says "OS-selected venv"; sets `UV_PROJECT_ENVIRONMENT={{ root / venv }}` | keep the prefix, since it carries a `PIPELINE_VENV` override through to uv; fix the comment |
| `just/sandbox.just` | names `.venv-linux` | whatever it names, derive it from `venv` or use `uv run` |
| `scripts/bootstrap_host.sh:41-42` | `if Darwin → .venv else .venv-linux` | `VENV="${UV_PROJECT_ENVIRONMENT:-.venv}"`: a host is `.venv` on every OS. Fix the header comment at L14 |
| `.github/workflows/ci.yml` | matrix `venv: .venv-linux` / `.venv`; Install step's `UV_PROJECT_ENVIRONMENT`; `${{ matrix.venv }}/bin/python`; the "Why the venv path differs per OS" block | a runner is a host: drop the matrix `venv:` key and the step's `UV_PROJECT_ENVIRONMENT` (uv defaults to `.venv` on both legs), make the version step `uv run python --version`, and delete the explanatory block. Keep `UV_PYTHON` |
| `.claude/settings.json:9-10` | allow `Bash(.venv-linux/bin/alembic upgrade *)`, `Bash(.venv-linux/bin/ruff check *)` | `Bash(uv run alembic upgrade *)`, `Bash(uv run ruff check *)`, same tier. The convention: allow rules use the `uv run …` form; ask/deny rules must list every spelling |
| `.claude/skills/mitdb-truth-harness/SKILL.md:13, 30, 33, 36, 44, 91, 93` | "Use `.venv-linux/bin/python` in the container, `.venv/bin/python` on the macOS host" + command lines | "Run everything through `uv run …`; the environment picks the venv." Commands become `uv run pytest …` / `uv run python …` |
| `AGENTS.md:242-250` | "Pick the venv that matches where the shell runs … Swap `.venv` → `.venv-linux`…" | one sentence: host `.venv`, sandbox `.venv-sandbox` via `UV_PROJECT_ENVIRONMENT`, use `uv run …`. Commands become `uv run pytest …` |
| `tests/conftest.py:83`, `scripts/convert_mitdb.py`, `scripts/backfill_h10.py`, `sandbox/*.py` | run hints naming `.venv-linux/bin/python` | `uv run python …` |

**Docs** (`README.md`, `docs/{api,dev_runbook,host_bootstrap,host_reset,mitdb_truth_harness,polar_h10_bringup,release_plan,dev_tooling_followups}.md`,
`sandbox/README.md`, `BACKLOG.md`): the same rewrite, `uv run …` in commands,
and the two-venv explanations collapsed to the rule above. `docs/adr/`,
`work/archive/` and `docs/_archive/` are history: leave them.
**Notebooks:** change instructions in markdown and code cells; leave recorded
outputs alone.

**Also in this pass:**
- `.gitignore`: replace the `.venv/` and `.venv-linux/` lines with `.venv*/`,
  and add `*.local`, `*.local.*` and `!*.local.example*`.
- A tracked `.python-version` containing `3.12`. CI and `requires-python`
  already say 3.12, and the sandbox image bakes 3.12 and 3.13 only.

## 4. Ordered steps

1. §0 precondition.
2. The executed and followed files in the §3 table, then prove the justfile:
   - `just --evaluate py` → `…/.venv-sandbox/bin/python` in this container;
   - `PIPELINE_VENV=.venv-x just --evaluate py` → `.venv-x`.
3. **Build the venv:** `just install`, which runs `uv sync --frozen --extra dev`
   into `.venv-sandbox`. It needs packages. If the uv cache is cold, **stop
   and ask the owner** to open an egress window. Don't work around it.
4. Run the gate: `just test`, or whatever the repo's gate is. The DB-backed
   tests use the sibling `postgres` as before.
5. The docs and notebooks sweep, `.gitignore` and `.python-version`.
6. Re-run the `git grep` from §3. What's left should be history only
   (`docs/adr/`, the archives).
7. Commit locally, one commit or a small series. Don't delete `.venv-linux/`.

## 5. What has to happen on the sandbox side (do not attempt)

Already done before you read this: the compose variable, a deletion-hook
exception for `.venv-sandbox`, a "Python environments" section in the sandbox
notice, and a verify check. Still to come, all the owner's: the egress window
for step 3 if needed, re-commenting the planning-mode domains afterwards, and
later deleting `.venv-linux/`.

## 6. What to hand back

Via the owner, into `macolima/work/0008-venv-per-environment/notes.md`:
1. The commit hash(es), and the step-2 `--evaluate` outputs.
2. Step 3: built from the cache, or needed egress; and the gate result.
3. Step 6: what the `git grep` still shows, and why each remaining hit is history.
4. Anything in §3 that no longer matched your tree.

macolima then re-runs `just workspace-scan --fail-on HARDCODED-VENV-LINUX,OS-VENV-SELECT`
host-side; this repo must no longer appear.
