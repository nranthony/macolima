# Handoff: the sandbox now names its own venv — retire wearable_data_testing's `.venv-linux`, in one pass

**To:** the agent working in `therapod/wearable_data_testing` (sandbox profile `therapod`, `/workspace/wearable_data_testing`)
**From:** the agent in `macolima` (host side)
**Date:** 2026-09-11 (rewritten the same day: final form, applied after the switch)
**Reciprocal-to:** —
**Filed at:** `macolima/work/0008-venv-per-environment/handoff-wearable_data_testing.md` ·
delivered: `/workspace/inbox/0008/handoff-wearable_data_testing.md` (the
therapod workspace root, outside every repo; this repo has no `inbox/`)

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
- every host leaves it unset, so uv uses `.venv`.

uv reads the variable itself, so `uv run` / `uv sync` pick the right venv
everywhere. This repo pins `.venv-linux` in two scripts, five allow rules and
its setup doc. Its justfile hard-codes `.venv/bin/python`, which is the Mac's
venv, so that recipe has never worked inside the container.

**One exception: `uv pip …` ignores the variable** and falls back to `.venv`,
which in the container is the host's. The setup doc is the likely place; for
example, a local paperbridge wheel installed with `uv pip install`. Prefer
declaring it in `pyproject.toml` and running `uv sync`; if a `uv pip` line must
stay, give it `--python "${UV_PROJECT_ENVIRONMENT:-.venv}"`.

**Write everything for the end state:** `.venv` on the host, `.venv-sandbox` in
the sandbox, selected by the variable, commands via `uv run …`. No transitional
wording.

## 2. What does NOT change

- The host keeps `.venv`.
- **Nothing is deleted.** `.venv-linux/` stays on disk, unused, until the owner
  removes it after a clean run.
- The tracked `.claude/settings.local.json` (host paths, personal grants) is
  **not** part of this handoff. It belongs to macolima work/0009.
- `CLAUDE.md` (`See @AGENTS.md for …`) is a valid inline import. Leave it.

## 3. What to change — checks, not claims

Read from a host-side copy at `ac7b907` (2026-07-17); yours may be newer.
Sweep with:

```sh
git grep -n -e '\.venv-linux' -e '\.venv/bin/' -- . ':!work/archive' ':!docs/_archive' ':!docs/adr'
```

| Where | Now | End state |
|---|---|---|
| `scripts/preflight.sh:53-54` | `PY=".venv-linux/bin/python"`; "missing $PY (run: uv venv .venv-linux)" | `PY="${UV_PROJECT_ENVIRONMENT:-.venv}/bin/python"`; "missing $PY (run: uv sync)". Keeps the `-x` check that makes preflight a preflight |
| `scripts/preseed_sdk_cache.sh:15` | `PY=".venv-linux/bin/python"` | `PY="${UV_PROJECT_ENVIRONMENT:-.venv}/bin/python"` |
| `justfile:9` | `python := ".venv/bin/python"` | `python := env_var_or_default("UV_PROJECT_ENVIRONMENT", ".venv") / "bin/python"` |
| `.claude/settings.json` | five allow rules `Bash(.venv-linux/bin/python scripts/<x>.py …)` | `Bash(uv run python scripts/<x>.py …)`, same argument shapes, same tier. The convention: allow rules use the `uv run …` form; ask/deny rules must list every spelling |
| `AGENTS.md:22` | "Python 3.12 with `.venv`" | "Python 3.12 — `.venv` on the host, `.venv-sandbox` in the sandbox (selected by `UV_PROJECT_ENVIRONMENT`); run things with `uv run …`" |
| `macolima_wearables_setup.md` (~L87-135) | `uv venv .venv-linux`, `source .venv-linux/bin/activate`, "Always use `.venv-linux/` inside the container" | `uv sync` builds the container's venv; `uv run python …`; the Mac-wheels note collapses to "the host's `.venv` is not the container's" |
| `.gitignore:157` | `.venv-linux` (plus a no-slash `.venv`) | `.venv*/`, plus `*.local`, `*.local.*` and `!*.local.example*` |
| new `.python-version` | — | `3.12`, tracked |

`input_docs/` looks like source material, i.e. history. Change it only where it
instructs a reader to run something.

## 4. Ordered steps

1. §0 precondition.
2. The two scripts, the justfile and the settings rules. Prove the justfile:
   `just --evaluate python` → `.venv-sandbox/bin/python`.
3. **Build the venv:** `uv sync --frozen` (use the extras the setup doc
   names). It needs packages (crawl4ai, playwright, paperbridge …). If the
   cache is cold, **stop and ask the owner** for an egress window.
4. `bash scripts/preflight.sh`: it must pass on `.venv-sandbox`.
5. `AGENTS.md`, the setup doc, `.gitignore` and `.python-version`.
6. Re-run the §3 `git grep`. What's left should be history only.
7. Commit locally. Don't delete `.venv-linux/`.

## 5. What has to happen on the sandbox side (do not attempt)

Already done before you read this: the compose variable, the deletion-hook
exception, the notice section and the verify check. Still the owner's: the
egress window for step 3 if needed, re-commenting the planning-mode domains
afterwards, and later deleting `.venv-linux/`.

## 6. What to hand back

Via the owner, into `macolima/work/0008-venv-per-environment/notes.md`:
1. The commit hash(es) and the step-2 output.
2. Step 3: from the cache, or needed egress; and the step-4 preflight result.
3. Step 6: what the `git grep` still shows, and why each remaining hit is history.

macolima then re-runs `just workspace-scan --fail-on HARDCODED-VENV-LINUX,OS-VENV-SELECT`
host-side; this repo must no longer appear.
