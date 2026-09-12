Hand-back for macolima/work/0008-venv-per-environment/notes.md:

1. Commits: c06ea66 (executed files, CI, settings.json, the mitdb skill, AGENTS.md, .python-version) and 7d9a8a2 (docs, script hints, src/ messages, notebooks, .gitignore, BACKLOG.md). The step-2 checks:
   - just --evaluate py gives /workspace/pipeline/.venv-sandbox/bin/python.
   - PIPELINE_VENV=.venv-x just --evaluate py gives /workspace/pipeline/.venv-x/bin/python.
   - An absolute path such as /abs/venv now resolves to /abs/venv/bin/python.
2. Build and gate: the build needed egress, because 118 of the packages weren't in the cache. It ran uv sync --frozen --extra dev --extra truth on Python 3.12.14, and uv.lock is unchanged. After the migration: ruff clean, mypy clean, 644 passed, 79 skipped, 2 xfailed.
3. What the step-6 grep still finds, all history: 26 recorded output lines in notebooks 02 and 03 (old warning paths), and work/0005's notes.md and plan.md.
4. Where §3 didn't match the tree:
   - scripts/backfill_h10.py:389 was an executed .venv-linux/bin/alembic call, not just a hint. It's now sys.executable -m alembic.
   - Four more CI steps used the venv path besides the version step.
   - These weren't listed but are rewritten the same way: tests/test_mitdb_e2e.py, just/sandbox.just, justfile:12, three script docstrings, validation/README.md, and scripts/mitdb_csv_export.py, which the grep misses because it hard-codes .venv/bin.
   - The AGENTS.md line numbers had drifted a little.
   - The sandbox notice at the top of AGENTS.md still calls anything inside a .venv disposable. Under the new rule, .venv is the host's. I left it, as agreed.

Things I noticed but left alone:
- The mitdb corpus isn't in the sandbox, so the mitdb tests skip here even with wfdb installed, and --check couldn't run. BACKLOG now says to run mitdb_beat_report.py --check on a host before the next tag. validation/mitdb/measured.json was generated in a venv that wasn't built from this lock, so the numbers may move.
- The AGENTS.md gotcha about a stale sandbox venv was no longer true, so I reworded it: the venv is now built from the same lock, but it still isn't CI.
- The Dockerfile keeps uv pip install --system. Itn Python, not a repo venv, so the variable doesn'tmatter there.
- docs/release_plan.md lines 100 and 178 still dese remaining install-path gap. That was already outof date before this pass.
- An exported but empty UV_PROJECT_ENVIRONMENT makoot>/bin/python. Nothing sets it that way today, soI didn't guard against it.