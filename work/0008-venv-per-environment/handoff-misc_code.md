# Handoff: the sandbox now sets `UV_PROJECT_ENVIRONMENT` itself — stop exporting `.venv-linux` over it

**To:** the agent working in `therapod/misc_code` (sandbox profile `therapod`, `/workspace/misc_code`)
**From:** the agent in `macolima` (host side)
**Date:** 2026-09-11 (rewritten the same day: final form, applied after the switch)
**Reciprocal-to:** —
**Filed at:** `macolima/work/0008-venv-per-environment/handoff-misc_code.md` ·
delivered: `/workspace/inbox/0008/handoff-misc_code.md` (the therapod workspace
root, outside every repo; this repo has no `inbox/`)

## 0. Precondition — check before touching anything

```sh
echo "$UV_PROJECT_ENVIRONMENT"
```

It must print **`.venv-sandbox`**. If it prints nothing, **stop and report**:
the switch hasn't reached this container yet. This caveat belongs to this
handoff only; nothing you write into the repo should repeat it.

## 1. What changed

Owner decision, 2026-09-11 (macolima work/0008). **The environment names the
venv; a repo never chooses it:**
- every sandbox container exports `UV_PROJECT_ENVIRONMENT=.venv-sandbox`;
- every host leaves it unset, so uv uses `.venv`.

This repo got to the same idea first, by hand: its `CLAUDE.md` and
`setup-linux-venv.sh` pick the container's venv with this variable. But they
**set** it, to `.venv-linux`. Now that the sandbox sets it, following
`CLAUDE.md` would override the sandbox for the whole session and keep a retired
venv alive without any error. The fix is to stop choosing: the sandbox has
chosen already.

One exception to "uv picks it up": `uv pip …` ignores the variable and falls
back to `.venv`, which in the container is the host's. Don't document `uv pip`
here; `uv sync --locked` is the build step.

## 2. What does NOT change

- The host keeps `.venv`. "The macOS `.venv` is not loadable on Linux" stays
  true and worth keeping.
- `uv.lock` stays the single lock both environments resolve from.
- `credentials.json` / `token.json` stay gitignored (checked).
- Moving `CLAUDE.md` to `AGENTS.md` with a stub is macolima work/0009, not this
  handoff.

## 3. What to change — checks, not claims

Read from a host-side copy at `a016cf8` (2026-06-18).

| Where | Now | End state |
|---|---|---|
| `CLAUDE.md:1-30`, "Environment selection" | two-venv table; "Always select the Linux environment first: `export UV_PROJECT_ENVIRONMENT=.venv-linux`"; "`uv run python ...` or `.venv-linux/bin/python ...`"; "run `sh setup-linux-venv.sh`" | Short: "Host: `.venv`. Sandbox: `.venv-sandbox`, which the sandbox selects by setting `UV_PROJECT_ENVIRONMENT`; **never export it yourself**. Build or refresh with `uv sync --locked`; run with `uv run python …`." Keep the not-loadable-on-Linux warning |
| `setup-linux-venv.sh` | exports `.venv-linux`, then `uv sync --locked --python 3.12` and a smoke import | **Obsolete**: in the sandbox, `uv sync --locked` builds `.venv-sandbox` directly. Remove it (`git rm` prompts the owner, which is expected), or reduce it to `uv sync --locked` plus the smoke import via `uv run python -c …` — your call; say which |
| `.gitignore` | `.venv-linux/` | `.venv*/`, plus `*.local`, `*.local.*` and `!*.local.example*` |
| new `.python-version` | — | `3.12` (the setup script already pinned `--python 3.12`), tracked |

## 4. Ordered steps

1. §0 precondition.
2. `CLAUDE.md` and `setup-linux-venv.sh`, as above.
3. **Build the venv:** `uv sync --locked`. It needs packages (openpyxl, pandas
   …). If the cache is cold, **stop and ask the owner** for an egress window.
4. Smoke test through the repo's own code: anything that proves the imports
   without calling Google, e.g. `uv run python requirements_to_gsheet.py --help`
   if it takes `--help`. **Don't use `python -c`:** the policy denies it.
5. `.gitignore` and `.python-version`.
6. `git grep -n -e '\.venv-linux' -e 'UV_PROJECT_ENVIRONMENT='` should show
   nothing that sets the variable or runs `.venv-linux`.
7. Commit locally.

## 5. What has to happen on the sandbox side (do not attempt)

Already done: the compose variable, the deletion-hook exception, the notice
section and the verify check. Still the owner's: the egress window for step 3
if needed, and re-commenting the planning-mode domains afterwards. There's no
`.venv-linux/` on disk here, so there's nothing to retire.

## 6. What to hand back

Via the owner, into `macolima/work/0008-venv-per-environment/notes.md`:
1. The commit hash, and what you did with `setup-linux-venv.sh`.
2. Step 3: from the cache, or needed egress; and the step-4 smoke result.

macolima then re-runs `just workspace-scan --fail-on HARDCODED-VENV-LINUX,OS-VENV-SELECT`
host-side; this repo must no longer appear.
