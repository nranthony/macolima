# Handoff: the sandbox names its own venv — ikigai's `.venv/bin/python` is the Mac's venv now, and there is no venv on this clone at all

**To:** the agent working in `nranthony/ikigai` (sandbox profile `nranthony`, `/workspace/ikigai`)
**From:** the agent in `macolima` (host side)
**Date:** 2026-09-13 (final form, written after the switch)
**Reciprocal-to:** your `work/0023-venv-sandbox-environment/proposal.md` — this
answers it, and supersedes it.
**Filed at:** `macolima/work/0008-venv-per-environment/handoff-ikigai.md` ·
delivered: `/workspace/inbox/0008/handoff-ikigai.md` (the `nranthony` workspace
root, outside every repo; neither this repo nor the workspace has an `inbox/`,
and ikigai gitignores `inbox/` so a copy inside the repo would be invisible)

## 0. Precondition — check before touching anything

```sh
echo "$UV_PROJECT_ENVIRONMENT"
```

It must print **`.venv-sandbox`**. If it prints nothing, **stop and report**:
the switch hasn't reached this container yet, and a `uv sync` here would build
into `.venv`, the host's slot. This caveat belongs to this handoff only;
nothing you write into the repo should repeat it.

## 1. What changed

Owner decision, 2026-09-11 (macolima `work/0008`, spec §2; recorded as macolima
**ADR-0013** "The environment names the venv, not the repo"). The repo-side half
of the same rule is `agentic-conventions` **ADR-0017**, shipped in **myconv
0.9.0** — that is the one to cite in this repo.

**The environment names the venv; a repo never chooses it:**

| Where it runs | `UV_PROJECT_ENVIRONMENT` | Venv |
|---|---|---|
| Any sandbox container | `.venv-sandbox`, exported by compose | `<repo>/.venv-sandbox` |
| Any host — macOS, WSL, bare Linux, CI | **unset** | `<repo>/.venv` |

uv reads the variable itself on every `uv run` / `uv sync` / `uv venv`, and a
**relative** value resolves against the project root, not the CWD. So the repo
needs no help: commands go through `uv run …`. Where a path is genuinely
unavoidable, derive it from `${UV_PROJECT_ENVIRONMENT:-.venv}`. **Never select a
venv by OS** — a Linux host and a Linux sandbox are both "linux", which is
exactly why the sibling sandbox (`windows-ai-sandbox`, Docker on WSL) cannot use
an `os()` switch either.

**One exception: `uv pip …` ignores the variable** (measured, uv 0.12.9) and
falls back to `VIRTUAL_ENV` or a `.venv` in the CWD — the host's, in here. If
this repo ever documents `uv pip`, it names its target: `--python .venv-sandbox`.
It doesn't today, so don't add one.

### Why this repo is a sharper case than the others

**There is no venv on this clone.** No `.venv`, no `.venv-sandbox`, no
`pyvenv.cfg` anywhere (host-side `find`, 2026-09-13). Every `.venv/bin/python …`
line in the tree — **154 of them across 52 tracked files** — names a directory
that does not exist. Inside the container they would fail loudly if it did
exist, because a `.venv` here is the Mac's; today they fail as "no such file".

That matters for two standing rules this repo wrote down and that are now
**false on this clone**:

- `AGENTS.md` / `ADR-0014` rule 5 / `work/0011`: "**`.venv/` is irreplaceable — do
  not delete it.** 733 MB, uv 0.11.25, Python 3.12.3." That venv belonged to the
  `windows-ai-sandbox` checkout. It was never on this one.
- `AGENTS.md` / `README.md`: "**`uv sync` is denied** by the sandbox permission
  layer (tested 2026-09-06)." That is the *sibling's* policy. **In macolima
  `uv sync` is not denied** — it is neither allowed nor denied, so it reaches a
  permission prompt. An environment rebuild from inside this container is
  possible, and step 3 below is exactly that.

Both claims live inside a managed notice block whose header says
`managed by windows-ai-sandbox — do not edit here` (`AGENTS.md:3–225`). **Do not
hand-edit inside those markers** — see §5.

**Write everything for the end state.** Docs and skills describe `.venv` (host)
and `.venv-sandbox` (sandbox, selected by the variable), and spell commands
`uv run …`. No transitional wording, no "if the variable is unset…", no "for now".

## 2. What does NOT change

- **The host keeps `.venv`.** `README.md`'s install path (`uv sync --frozen`
  creating `.venv` with the package editable) is correct on a host and stays.
- **`uv.lock` is the single lock both environments resolve from.** It is current
  (`dc640fd`, "deps: split extras from core, add the dev group, re-lock"). Do not
  touch `pyproject.toml` dependencies; that rule survives this handoff intact,
  for the reason it was written — a manifest edit invalidates the lock and
  strands the host's `uv sync --frozen` too.
- **Nothing is deleted.** There is nothing to retire here; that is the one part
  of `work/0023` phase 4 that is already free.
- The gate, the schemas, the block model, the ADR discipline and the capture
  protocol are untouched. Only *which interpreter* runs them.
- `.env`, `capture/people_map.json`, `capture/style/`, `applications/`, `inbox/`
  stay gitignored. Re-confirm with `git check-ignore` after the `.gitignore` edit.
- **`capture/connectors/scholarly_ids.py:167`** calls
  `subprocess.run(["paperbridge", …])` — a bare console-script name off `PATH`,
  no venv in it. Leave it. Worth knowing: under `uv run`, `.venv-sandbox/bin` is
  prepended to `PATH`, so a `paperbridge` installed into the venv would win over
  one on the system path. It isn't a dependency here, so nothing changes today.

## 3. What to change — checks, not claims

Read host-side at **`64a9b4b`** (2026-09-13); yours should match. The sweep is:

```sh
git grep -n -E '\.venv(-linux|-sandbox)?/bin|UV_PROJECT_ENVIRONMENT|os\(\)'
```

162 hits, 52 files for `.venv/bin` alone. **Treat the table below as a starting
point, not the set** — two earlier repos in this wave each had a live file the
table had missed. Re-run the grep at the end (step 8) and account for every
remaining hit.

### A. Policy — do this first, it is the only one that fails *silently*

| Where | Now | End state |
|---|---|---|
| `.claude/settings.json` `allow` (6 rules) | `Bash(.venv/bin/python dev_plans/content_schemas/validate_all.py*)`, `… capture/rebuild_index.py*`, `… capture/bullet_mix_report.py*`, `… dev_plans/visual_wiki/build.py*`, `… dev_plans/visual_wiki/build_taxonomy.py*`, `Bash(.venv/bin/python -m pytest*)` | the same six, in the `uv run …` form: `Bash(uv run python dev_plans/content_schemas/validate_all.py*)`, `Bash(uv run python capture/rebuild_index.py*)`, `Bash(uv run python capture/bullet_mix_report.py*)`, `Bash(uv run python dev_plans/visual_wiki/build.py*)`, `Bash(uv run python dev_plans/visual_wiki/build_taxonomy.py*)`, `Bash(uv run python -m pytest*)` |
| `.claude/settings.json` `deny` (1 rule) | `Bash(.venv/bin/python ikigai/db/load_blocks.py*--write*)` | the four-rule fence, below |

**The allow rules: one spelling, not many.** An allow rule grants permission, so
fewer spellings is safer — `uv run …` is the one form that works in every
environment. Resist the temptation to write `Bash(uv run *validate_all.py*)` to
cover `--frozen` and friends in one rule: a mid-rule `*` there would also allow
`uv run --with <anything> … validate_all.py`, which fetches and runs a package.
Keep the allow rules literal, and spell the commands in the skills and docs the
same way (`uv run python <script>`) so one rule matches each.

**The deny rule has a hole, and it is the one that matters.** `ADR-0014` /
"Golden rules" say *capture never writes Postgres*: `load_blocks.py --write` is a
pending decision (work item 0009), not a command to run. One literal spelling
enforces that today. Every other spelling falls straight through to the sandbox's
broad `python:*` / `python3:*` / `uv run:*` allows, and in `auto` mode that goes
to the classifier instead of to a person. `deny` beats `allow` across scopes, and
deny rules match subcommands of `cd … && …` compounds — but only the spellings
you list. The fence (macolima `docs/permissions-model.md` §"How a Bash rule
matches"; handoff-depot rule 6):

```
Bash(python*ikigai/db/load_blocks.py*--w*)
Bash(uv run *ikigai/db/load_blocks.py*--w*)
Bash(.venv*/bin/python*ikigai/db/load_blocks.py*--w*)
Bash(./.venv*/bin/python*ikigai/db/load_blocks.py*--w*)
```

Four points on that shape, each load-bearing:

1. `python*` catches `python`, `python3`, `python3.12`. Matching is **literal**:
   `python3` is not `python`, and the current rule catches neither.
2. `uv run *X*` catches `uv run X`, `uv run python X`, `uv run --frozen python3 X`.
3. `.venv*/bin/python*` catches both `.venv` (host) **and** `.venv-sandbox`, and
   both `python` and `python3`. Keep it even though the path form is retired
   everywhere else — a fence is not a style rule, and the old spellings persist
   in transcripts and in the owner's head.
4. `--w`, not `--write`. **argparse accepts unambiguous prefixes**, and
   `load_blocks.py`'s options are `--blocks-dir`, `--write`, `--dry-run`,
   `--only`, so `--w`, `--wr`, `--writ` all reach `--write` and none of them
   matches a `*--write*` rule. This is a real hole in the rule as it stands.

Also add, because the module is importable (`ikigai/__init__.py` and
`ikigai/db/__init__.py` both exist):

```
Bash(python* -m ikigai.db.load_blocks*)
Bash(uv run *-m ikigai.db.load_blocks*)
```

`load_blocks.py` is not executable and carries no shebang, so no `Bash(X*)` /
`Bash(./X*)` pair is needed.

**`.claude/settings.local.json` is gitignored — report it, don't edit it.** It
holds `Bash(.venv/bin/python:*)` (matches nothing once the venv is
`.venv-sandbox`; `Bash(uv run python:*)` is the form that works on both sides)
and six rules naming `/Volumes/DataDrive/repo/nranthony/ikigai/...`, which are
host paths and dead inside the container. It is the owner's file. Say what's in
it in the hand-back and let the owner decide.

### B. Agent instruction files — followed, so they must change

| Where | Now | End state |
|---|---|---|
| `AGENTS.md:286` ("Running things") | "Use the venv's interpreter directly: `.venv/bin/python`, `.venv/bin/alembic`." + the "`uv sync --frozen` … inside the sandbox it is denied, `.venv/` is irreplaceable" sentence | one sentence: "Run everything through `uv run …`; the environment picks the venv — host `.venv`, sandbox `.venv-sandbox`, selected by `UV_PROJECT_ENVIRONMENT`, which you never set yourself. Build or refresh with `uv sync --frozen`." Drop "irreplaceable" and "denied" — both are false here |
| `AGENTS.md:290` | `cd ikigai_app && ../.venv/bin/python main.py` | `uv run python ikigai_app/main.py` (or `cd ikigai_app && uv run python main.py` — `uv run` resolves the project root from the CWD, so the `../` is not needed; check which the app's relative paths want) |
| `AGENTS.md:294` | `.venv/bin/alembic upgrade head` | `uv run alembic upgrade head` |
| `AGENTS.md:299` | `.venv/bin/python -m pytest tests/ -q`; "If `pytest` is missing from the venv the host has not re-locked yet" | `uv run python -m pytest tests/ -q`. **pytest is in the lock now** (`[dependency-groups] dev = ["pytest>=8"]`, locked at `dc640fd`) and `uv sync --frozen` installs it, so delete the missing-pytest caveat |
| `AGENTS.md:152–153` | `.venv/bin/alembic current`, `.venv/bin/python tests/test_agents_quick.py` | `uv run alembic current`, `uv run python tests/test_agents_quick.py` |
| `AGENTS.md:3–225` (the managed notice block) | `windows-ai-sandbox`'s block, including L27's `UV_PROJECT_ENVIRONMENT=.venv-linux uv sync --frozen` | **don't touch it** — §5 |
| `capture/AGENTS.md:68–78` (10 lines) | `.venv/bin/python <script>` | `uv run python <script>` |

### C. Skills — 13 lines, 3 files

| Where | Lines | End state |
|---|---|---|
| `.claude/skills/checkpoint-gate/SKILL.md` | 13, 18 (×2), 22, 26, 38, 47, 48 | `uv run python …`. The prose "run from the repo root with the venv interpreter" becomes "run from the repo root with `uv run`". Check 3's `-m pytest` keeps that shape. The "Check 3 failing with `No module named pytest`" branch is stale — pytest is locked; replace it with "re-run `uv sync --frozen`" |
| `.claude/skills/application-tailoring/SKILL.md` | 61, 97, 170, 171 | `uv run python …`, including the `$S` script-variable lines and the `> …_raw.txt` redirect |
| `.claude/skills/capture-cycle-close/SKILL.md` | 14, 29 | `uv run python …` |

### D. Executed code — docstrings **and** the run hints printed at runtime

Every one of these is a line a human or an agent copy-pastes. The
`print(f"next: …")` ones are the easy miss: they are **generated output**, not
comments, so a stale one keeps handing out a dead path long after the docstrings
are fixed. Grep for the print sites specifically, don't rely on eyeballing:

```sh
git grep -n '\.venv/bin' -- '*.py' | grep -vE ':[0-9]+: *(#|""")'
```

| File | Lines | Kind |
|---|---|---|
| `capture/connectors/cv_import.py` | 10–14; **642, 643, 751, 752, 846** | docstring; **f-string run hints written into the generated proposal and printed** |
| `capture/materialize_profile.py` | 9, 10; **296, 297** | docstring; **generated hints** |
| `capture/connectors/scholarly_ids.py` | 16, 17; **316, 317** | docstring; **generated hints** |
| `capture/apply_annotation_proposal.py` | 4–6; **164** | docstring; **printed "next:" hint** |
| `capture/connectors/style_ingest.py` | 7–11 | docstring |
| `capture/connectors/style_card.py` | 8–11 | docstring |
| `capture/rebuild_index.py` | 4–6 | docstring |
| `capture/bullet_mix_report.py` | 4, 5 | docstring |
| `capture/materialize_taxonomy.py` | 3, 4 | docstring |
| `dev_plans/content_schemas/validate_all.py` | 4, 5 (+2) | docstring |
| `dev_plans/visual_wiki/build.py`, `build_taxonomy.py` | 1 each | docstring |
| `ikigai/db/profile_correspondence.py` | 8–10 | docstring |
| `tests/*.py` — 14 files, **23 lines** | `test_style_*.py` (6 files), `test_cv_import.py`, `test_block_integrity.py`, `test_marks.py`, `test_roundtrip.py`, `test_disclosure_integrity.py`, `test_enum_copies.py`, `test_materialize_profile.py`, `test_materialize_taxonomy.py`, `test_profile_correspondence.py`, `test_scholarly_ids.py` | docstring run hints |

All become `uv run python …`.

**`capture/proposals/*.md` (8 lines across 4 files) are generated output** — the
apply commands in them came from the connectors above. Fix the generators; then
leave the existing proposal files alone **unless one is still open and waiting to
be applied**, in which case fix that file's command block too. Say which in the
hand-back.

### E. Live docs

| Where | Now | End state |
|---|---|---|
| `README.md:10–11` | "> Inside the agent sandbox `uv sync` is denied and `.venv/` is pre-built; see the notice at the top of `AGENTS.md`." | replace with the rule: "On a host this creates `.venv`; inside a sandbox container it creates `.venv-sandbox`, because the container sets `UV_PROJECT_ENVIRONMENT`. Either way the command is the same." |
| `README.md:18–24` | `uv sync --frozen` / "This creates `.venv/` …" / "run things with the venv, e.g. `uv run alembic upgrade head`" | keep the commands; make the `.venv` sentence say "creates the project environment (`.venv` on a host)" |
| `dev_plans/visual_wiki/README.md:7, 8` | `.venv/bin/python dev_plans/visual_wiki/build{,_taxonomy}.py` | `uv run python …` |
| `capture/coverage.md:7` | `.venv/bin/python capture/rebuild_index.py` | `uv run python …` |
| `capture/queue.md:35` | `.venv/bin/python ikigai/db/block_integrity.py --people-map …` | `uv run python …` |
| `capture/SESSION_CLOSE_2026-09-08.md` | 2 lines | **history — leave it** |
| `work/0005`, `work/0004`, `work/0001`, `work/0010`, `work/0021`, `work/archive/0003` | 28 lines | **history — leave them** |

### F. ADRs — append-only, so this arrives as a new record

`docs/adr/0014-environment-and-data-layer.md` rule 5 says "`.venv/` is
irreplaceable", rule 6 and the Consequences repeat the denied-`uv sync` premise,
and L47–48 say everything runs through `.venv/bin/python`. `docs/adr/0008:55`
says pytest is not in the venv. ADRs are append-only here (your own `work/0023`
says so), so:

- **Write a new ADR — next free number is `0021`** — "The environment names the
  venv". It supersedes ADR-0014 rules 5–6 and amends its Consequences, and
  records that pytest is now locked (superseding ADR-0008's L55 note). Cite
  `agentic-conventions` **ADR-0017**, shipped in **myconv 0.9.0**, as the rule
  this repo is adopting, and macolima **ADR-0013** / `work/0008` as the sandbox
  side of it. State the `uv pip` exception and the never-select-by-OS clause.
- Give ADR-0014 a one-line "Superseded in part by ADR-0021" pointer if this
  repo's ADR convention allows that; otherwise leave it and let the index carry it.

### G. Your own work items — reconcile them, don't leave two instructions

This is the part that must not be skipped. Right now the repo holds **two live
plans for this exact change**, and after your commit they would both still be
telling a future agent something the tree no longer does.

- **`work/0023-venv-sandbox-environment/proposal.md`** — Draft, "the container's
  Python environment becomes `.venv-sandbox`". It is the same idea, reached
  independently, and its analysis is good. It is now **decided upstream**, so
  close it rather than execute it. Its three open questions are answered:
  1. *"Should the host's environment stay `.venv`, or become `.venv-host`?"* —
     stays `.venv`. Hosts are never configured; the only host obligation is not
     to export `UV_PROJECT_ENVIRONMENT`.
  2. *"Should docs and skills stop naming the path at all?"* — **yes**, that is
     the rule. `uv run …`, plain. You do not need `--frozen --no-sync`: `uv run`
     only re-locks when `pyproject.toml` and `uv.lock` disagree, and this repo
     forbids editing `pyproject.toml` in-sandbox, so they cannot. Use
     `uv run --frozen` where a result is being *validated* if you want it
     belt-and-braces; if you do, keep the spelling consistent so the allow rules
     still match.
  3. *"Does the macOS sandbox lineage need the same change?"* — it **is** the
     change; macolima is where the decision was made. Both lineages export the
     same value.
  Its phase 1 ("a human runs the sync via `docker exec`") is no longer needed —
  `uv sync` is not denied here, you run it yourself (step 4). Its phase 3 warning
  that the deny rule would **fail open, silently** after a rename was exactly
  right, and §3A above is that warning honoured. Mark the proposal
  **Superseded by ADR-0021** with a pointer, and `git mv` the folder to
  `work/archive/` per this repo's own convention (items are archived, never
  deleted) — or keep it open as the implementation record for this commit, your
  call. Say which.
- **`work/0011-env-and-host-followups/plan.md`** — Status "In progress,
  host-blocked". Most of it is now stale and it is the file `AGENTS.md` and
  `ADR-0014` point at:
  - its one-line blocker ("`uv sync` is denied") is the sibling's policy, not
    macolima's;
  - "**`.venv/` is irreplaceable — do not delete it.** 733 MB" — there is no
    `.venv` on this clone;
  - §2 (split the extras, add `include = ["ikigai*"]`) **landed** at `dc640fd`:
    `pyproject.toml` now has `analysis` / `scraping` / `notebooks` extras and the
    `include` filter;
  - §4 (add pytest as a dev dependency) **landed** in the same commit;
  - §1's acceptance test is already in the `uv run` form and stays;
  - L64 ("if you rebuild into `.venv-linux` …") is retired by the rule;
  - §3 (push the archive tag, delete the dev branches) is genuinely still open
    and still a host step — keep it.
  Rewrite the item down to what is actually left, or close it and open a small
  successor for §3. Don't leave the two standing rules in place.

### H. Hygiene

| Where | Now | End state |
|---|---|---|
| new `.python-version` | — | **`3.12`**, tracked. `requires-python = ">=3.12"`; the retired sandbox venv was 3.12.3; the macolima image bakes **only 3.12 and 3.13** and `python-downloads` needs egress the allowlist won't give, so a pin to anything else fails offline. Unpinned, uv takes the newest baked (3.13) in here while a host may take 3.12 — the two sides of one repo silently on different minors. **Create it before step 4**, or you build twice |
| `.gitignore:131–135` | `.venv`, then a comment explaining `.venv-linux` / `.venv-win`, then `.venv*/` | `.venv*/` already covers everything and **stays** — this repo got that right first. Reword the comment to the end state: the host's venv is `.venv`, a sandbox container's is `.venv-sandbox`, and the bare `.venv` line above does not match a suffixed directory. Drop `.venv-linux` / `.venv-win` from the prose |
| `.gitignore` (end) | no `.local` rules | add the trio, exactly: <br>`*.local`<br>`*.local.*`<br>`!*.local.example*` <br>with a line saying the negation keeps a committed **example** of a local file visible |
| `.gitignore:~88` | `# .python-version` (commented, from the pyenv template) | leave it commented — the file must be **tracked** |

## 4. Ordered steps

1. §0 precondition.
2. **`.claude/settings.json` first** (§3A), then `.python-version` = `3.12` and
   the `.gitignore` edits (§3H). Policy and the pin both have to be right
   *before* anything runs.
3. Confirm the ignores still hold:
   `git check-ignore -v .env capture/people_map.json capture/style/x applications/x`
   — all four must still be ignored.
4. **Build the venv:**

   ```sh
   uv sync --frozen
   ```

   **No `--extra`.** Nothing tracked in this repo imports numpy, pandas,
   matplotlib, itables, rich, tqdm, selenium, bs4 or requests (checked
   host-side), so the three extras stay out; uv installs the **`dev`
   dependency-group by default**, which is where `pytest>=8` lives, and that is
   all the gate needs. If you ever do add an extra later, remember `uv sync`
   *removes* every extra you don't name on that invocation — name them all or
   none.

   Expect a permission prompt: `uv sync` is neither allowed nor denied in the
   macolima policy. That prompt is the expected behaviour, not the sibling's
   flat denial. **The container's `[pypi]` egress is open right now**
   (`.pypi.org` and `.files.pythonhosted.org` are live in the shared allowlist),
   so if the profile's uv cache is cold the download will work. That is a
   temporary, hand-opened state the owner will close again — **record in the
   hand-back whether the build came from the cache or needed the network**, so
   the owner knows whether this repo is reproducible offline.

5. Prove the venv before the sweep:

   ```sh
   uv run python -m site          # sys.path names .venv-sandbox/lib/…
   cat .venv-sandbox/pyvenv.cfg   # 3.12, and home = the image's interpreter
   ```

   **Don't use `python -c`** — the policy denies it.
6. **Run the gate** — the `checkpoint-gate` skill, all five checks, through
   `uv run`: `validate_all.py`, the `profile_to_blocks.py | validate_all.py -`
   dry run, `python -m pytest tests/ -q`, `block_integrity.py`, and the `rg`
   delimiter sweep. Report the numbers in the skill's one-line format. Checks
   needing Postgres use the sibling `postgres` service exactly as before
   (`uv run alembic current` → `c3a91f5d20e7`).
7. The sweep: §3B (agent files), §3C (skills), §3D (code, docstrings **and** the
   printed hints), §3E (live docs). Then §3F (the new ADR) and §3G (your two
   work items).
8. Re-run the sweep from §3 and account for **every** remaining hit. What's left
   should be history only: `capture/SESSION_CLOSE_2026-09-08.md`, the six
   `work/…` plans, `work/archive/`, the applied `capture/proposals/*.md`, and
   `AGENTS.md`'s managed notice block (which is §5, not yours). Also:

   ```sh
   git grep -n 'UV_PROJECT_ENVIRONMENT='
   ```

   Nothing outside history and the notice block may **set** the variable.
9. Re-run the gate (step 6) so the numbers bracket the sweep.
10. Commit locally — one commit, or a small series with policy first. Don't push.

## 5. What has to happen on the sandbox side (do not attempt)

Already done before you read this: the compose variable, the deletion hook's
`.venv-sandbox` exception, the sandbox notice's "Python environments" section,
and a `verify-sandbox.sh` check that fails on unset, absolute, or any other name.

Still the owner's, and **not yours to do**:

- **The `AGENTS.md` notice block is stale and belongs to the wrong sandbox.**
  `AGENTS.md:3` reads `managed by windows-ai-sandbox — do not edit here`, and its
  222 lines describe that container: `/root/.local`, `/usr/lib/wsl/lib/nvidia-smi`,
  "`uv sync` is DENIED", the `.venv-linux` export at L27. This clone lives in
  macolima's `nranthony` profile. macolima has its own canonical block
  (`sandbox_templates/common/agent-notice.md`) and a script that swaps it in
  (`scripts/sync-agent-notice.sh <repo>`), and that block already carries the
  venv rule. **Refreshing it is a host-side step the owner runs**; don't edit
  inside the markers, and don't delete them. Flag in your hand-back that until it
  is refreshed, the notice at the top of `AGENTS.md` contradicts the rest of the
  repo — and that the sibling's checkout of ikigai, if it still exists, keeps the
  sibling's block and needs its own pass.
- Re-commenting the `[pypi]` planning-mode domains once the builds are done.
- Deciding what to do about `.claude/settings.local.json` (§3A).

## 6. What to hand back

Via the owner, into `macolima/work/0008-venv-per-environment/notes.md`:

1. The commit hash(es).
2. Step 4: **from the cache, or needed the network** — and the `pyvenv.cfg`
   interpreter and version from step 5.
3. Step 6 and step 9: the gate's one-line report, before and after the sweep.
4. Step 8: what the sweep still shows, and why each remaining hit is history.
5. §3A: what you settled on for the `load_blocks.py` fence, and what
   `.claude/settings.local.json` contains (report, not edit).
6. §3G: what you did with `work/0023` and `work/0011`, and the new ADR's number.
7. §3D: whether any `capture/proposals/*.md` was still open and got its command
   block fixed.
8. Anything in §3 that no longer matched your tree.

macolima then re-runs
`just workspace-scan --fail-on HARDCODED-VENV-LINUX,OS-VENV-SELECT` host-side,
and checks the repo's `VENV-PATH-ALLOW`, `VENV-PATH-IN-CODE`, `ASK-GAP`,
`NO-PYTHON-VERSION` and `NO-LOCAL-IGNORE` findings are gone. This repo must no
longer appear.
