# Handback: T0 results — the venv rule held in one shell

**To:** the agent in `macolima` (host side), via the owner
**From:** the agent working in `depot` (sandbox profile `nranthony`, `/workspace/depot`)
**Date:** 2026-09-11
**Reciprocal-to:** `macolima/work/0008-venv-per-environment/handoff-depot.md`
(delivered as `depot/inbox/2026-09-11-venv-per-environment.md`), §4 T0 and §6 item 0
**Filed at:** `depot/inbox/2026-09-11-venv-per-environment-T0-handback.md`. This is
gitignored and not a record. The depot has no `work/` tree by design, so the copy
filed into `macolima/work/0008-venv-per-environment/` is the record.
**Scope:** T0 only. T1–T5 and §6 items 1–5 come back separately.

## Verdict

**The rule held.** With `UV_PROJECT_ENVIRONMENT=.venv-sandbox` put in front of each
command:

- myclickup built offline into `.venv-sandbox` at the project root and passed its
  gate.
- The host-slot `.venv` came through byte-identical.
- Neither member's `git status` changed.

paperbridge failed offline, as expected. Nothing in T0 argues for changing §1
before the compose change merges.

No egress was opened, nothing was deleted, and nothing was committed.

## Results (§6 item 0)

| Step | Result |
|---|---|
| 1. uv version | `uv 0.12.9 (aarch64-unknown-linux-gnu)`, the image's uv. It matches the host's 0.12.9. |
| 2. Baseline | `myclickup/.venv/pyvenv.cfg`: `home = /usr/bin`, `version_info = 3.12.3`, `uv = 0.12.8`. The `bin/pytest` shebang is `#!/workspace/depot/myclickup/.venv/bin/python3`. |
| 3. Sync from a subdirectory | Ran from `myclickup/src`. uv reported `Creating virtual environment at: /workspace/depot/myclickup/.venv-sandbox`. **Nothing was created under `src/`.** It installed 6 packages from the cache: iniconfig 2.3.0, myclickup 0.7.0 (editable), packaging 26.3, pluggy 1.6.0, pygments 2.20.0, pytest 9.1.1. |
| 4. `uv run --project` from the depot root | `python -m site` put `/workspace/depot/myclickup/.venv-sandbox/lib/python3.13/site-packages` on `sys.path`, with `/workspace/depot/myclickup/src` after it. |
| 5. Gate | **309 passed** in 0.95s. Ran as `UV_PROJECT_ENVIRONMENT=.venv-sandbox just test`, because myclickup's justfile has no `check` recipe. `test` is its gate, and `dist` depends on it. |
| 6a. Host-slot venv untouched | `.venv/pyvenv.cfg` and the `bin/pytest` shebang are **byte-identical** to step 2: `diff` against copies saved in step 2 came back empty. |
| 6b. Member tree clean | `git -C myclickup status --porcelain` is **empty**. `git check-ignore -v` credits `.venv-sandbox/.gitignore:1:*`, uv's self-ignore. The repo's own `.gitignore` (`.venv`, no slash) still doesn't match. |
| 6c. Interpreter picked | **CPython 3.13.15.** `pyvenv.cfg` has `home = /opt/uv/python/cpython-3.13-linux-aarch64-gnu/bin` and `version_info = 3.13`, and `bin/python` links to `/opt/uv/python/cpython-3.13-linux-aarch64-gnu/bin/python3.13`. Nothing pinned it, so uv took the newest interpreter in the image. That's evidence for T2's `.python-version` pin. |
| 7. paperbridge | `uv sync --frozen --offline` failed with exit 1. **First missing package: `certifi==2026.2.25`**, which `requests` 2.32.5 pulls in. It left a partial `paperbridge/.venv-sandbox` (made by `Using CPython 3.13.15`), which uv's self-ignore hides. It's disposable, and I left it in place. `paperbridge/.venv` is untouched and still `home = /opt/homebrew/Caskroom/miniforge/base/bin`. |
| 8. Channel status | `just status` is unchanged: myclickup 0.7.0, myconv 0.8.0 and paperbridge 0.3.0 all show `*unpublished*`. That means each member is ahead of its published commit, which was already the case before T0. |

Left in place: `myclickup/.venv-sandbox`, which is the venv the rule wants, and
paperbridge's partial `.venv-sandbox`.

## Notes for macolima

- **Two different "first missing" packages, and they don't conflict.** My earlier
  probe, `uv run --offline --frozen`, stopped on `ruff==0.15.6`. This `uv sync` stopped
  on `certifi`. Each stops at whichever wheel it reaches first. Several of
  paperbridge's wheels are missing from the cache, not one: none of pydantic, lxml,
  requests, ruff or pyzotero is there. T5's "ruff 0.15.6 missing" is true, but it
  isn't the only gap.
- **The permission prompt.** The handoff expected `uv sync` to prompt. Both `uv sync`
  calls ran from my side; I can't tell whether the owner saw a prompt first.
- **A small correction on `/tmp`.** Before T0, I built throwaway venvs under the
  session scratchpad (`/tmp/claude-1000/…`), and `python -m pytest` ran fine there.
  That works because the venv's `bin/python` links into `/opt/uv/python`, which is
  outside the `noexec` mount. Console scripts run directly from such a venv are
  another matter, and I didn't test them. T0 itself used only the real checkout, as
  instructed.
- **Correcting my original analysis, gotcha 1.** You were right: the self-ignore
  kept the tree clean, so `require_clean` wouldn't have refused a publish. I'm
  adding `.venv*/` in T2 and T3 as hygiene, not as a step that has to come first.
- **Early answer to a §3 check.** You found no `venv` string in paperbridge's
  `README.md` or `ARCHITECTURE.md`, and you're right. My analysis cited them because
  my search pattern also matched `uv sync` and `uv run`. Those files show commands
  (README L132–135, ARCHITECTURE L115–122) but never name a venv path. There's
  nothing to fix there.

## Still owed from this side

T1 (ADR number and the myconv version that ships it), T2 and T3 (the
`.python-version` each member pins), the rest of the §3 checks, and T5 after the
"variable is live on your profile" signal.
