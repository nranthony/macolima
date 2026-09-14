# 0008 — notes (execution log)

Names allowed here (owner, 2026-09-11). The **full** scan — every repo in every
profile — lives only in the untracked `scan.local.md` beside this file.

## 2026-09-11 — stage 0: clearing the decks

- **README private name:** `README.md:319` now reads `claude-agent-<profile>`,
  folded into the unpushed commit (`49ab9de` → `b9f33a9`) so the name never
  reaches GitHub. The private-names check passes. The only other name hits in
  the two unpushed commits are on surfaces the check skips on purpose: a work
  item, and the `allowed_domains.txt` provenance comments.
- **citation_tools' apply-conventions run finished.** Its ADR-0002 (then
  ADR-0003, "hosts keep `.venv`") adopts the rule. The leftover sandbox `.venv`
  is gone. `.venv-sandbox` exists but is empty, blocked on registry access (its
  own work/0001).
  - Its ADR-0004 sets `[tool.uv] no-build = false`: three locked packages have no
    usable wheel. macolima's Dockerfile documents that as uv's only escape hatch
    (no per-package exemption exists). `just verify therapod` will warn
    "project config OPTS OUT of wheels-only"; that's expected, and the reason is
    recorded.
  - **Its ask fence had a hole:** five explicit spellings per script, no
    `python3`. `python3 scripts/normalize_zotero_tags.py` fell through to the
    sandbox's `python3:*` allow, where auto mode sends it to the classifier. We
    added the four wildcard rules per script (handoff-depot rule 6) and kept the
    explicit ones. The change is **uncommitted in citation_tools**, left for its
    owner.
- **Claude Code permission semantics, from the docs** (code.claude.com
  permissions.md, permission-modes.md), which rule 6 and `ASK-GAP` rest on:
  - deny > ask > allow, across scopes;
  - an explicit ask rule still prompts in `auto` mode;
  - ask/deny rules match subcommands of compounds;
  - `*` works mid-rule and matches any text;
  - `:*` is suffix-only and equals a trailing ` *`;
  - matching is literal: `python3` ≠ `python`, and an absolute path is not the
    bare name.

  Leading wildcards are undocumented, so we don't rely on them.
- **handoff-depot rule 6 amended and re-delivered:** allow rules use the
  `uv run …` form; ask/deny rules list every spelling, with the four-rule
  wildcard fence.

## 2026-09-11 — stage 1: the scan (A1)

Committed tooling: `scripts/workspace-scan.py` (stdlib, read-only), its test
`scripts/workspace-scan.test.sh` (37 checks, in `test-offline`), and
`just workspace-scan`. Roots: every profile under the profiles dir
(fluidmomenta, jeremy_dahl, nranthony, therapod), plus the host-only root
`/Volumes/DataDrive/repo/sandbox`, read from the untracked
`.workspace-scan.local`. **55 repos**, about 6 s.

**First-run false positives, fixed, each locked by a test:**
1. Venv discovery walked into nested repos, so `depot/` double-reported
   `myclickup/.venv`.
2. Template payload (`templates/`, `dist/`) read as nested guidance.
3. A gitignored `settings.local.json` (this machine's saved approvals) was
   treated as shared policy. Only tracked files count as ACTION now.
4. Append-only ADRs, `.gitignore` lines, `/root/.venv` and docstring mentions
   were read as live references. Executed and followed files (scripts,
   justfiles, CI, agent instruction files) are ACTION; everything else is a
   mention.

Separately, `check-ignore .venv-sandbox/` is satisfied by an existing venv's
own `.gitignore` (`*`), which falsely passes a repo with no `.venv*/` rule. The
scanner probes an existing directory without the trailing slash.

### The switch-over gate (plan stage 5)

`just workspace-scan --fail-on HARDCODED-VENV-LINUX,OS-VENV-SELECT` →
**exit 1**. Those two are the only findings that go *silently* stale on
activation: a pinned `.venv-linux` keeps running an old, working venv. A stale
`.venv/bin/…` inside the sandbox hits the Mac's venv and fails loudly, so it is
wave-2 work.

| Gate blocker (wave 1) | What pins `.venv-linux` |
|---|---|
| `therapod/pipeline` | `just/vars.just:21` `os()` switch; tracked allow rules `.venv-linux/bin/{alembic,ruff}`; the `mitdb-truth-harness` SKILL.md tells agents to use `.venv-linux/bin/python` |
| `therapod/wearable_data_testing` | `scripts/preflight.sh:53`, `scripts/preseed_sdk_cache.sh:15` (`PY=.venv-linux/bin/python`); tracked allow rules |
| `therapod/misc_code` | **not in the spec §5 snapshot.** Its `CLAUDE.md` tells agents to `export UV_PROJECT_ENVIRONMENT=.venv-linux`. After activation, an agent following that overrides the compose value for its session and keeps using the old venv |

**nranthony, fluidmomenta and jeremy_dahl have no gate blockers.**
jeremy_dahl_analytics has `.venv-linux` in docs only, which is wave 2, plus a
legacy slot for Phase F.

### Wave 2 (after the conventions release) — ACTION counts

| ID | Repos | Note |
|---|---|---|
| `NO-LOCAL-IGNORE` | 54 / 55 | only macolima has the pair so far |
| `NO-VENV-SANDBOX-IGNORE` | 26 | `.venv*/` |
| `NO-PYTHON-VERSION` | 24 | |
| `VENV-PATH-IN-CODE` | 6 | numerai, project_zenbu, webridge (instruction files say `.venv/bin/…`); therapod/core (`source .venv/bin/activate`); pipeline (AGENTS.md); wearable (`justfile: python := ".venv/bin/python"`, **broken inside the sandbox today**) |
| `DOC-VENV-LINUX` | 5 | jeremy_dahl_analytics, therapod/core, misc_code, pipeline, wearable |
| `VENV-PATH-ALLOW` (tracked) | 3 | project_zenbu; pipeline and wearable, whose `.venv-linux` rules are wave 1 |
| `NO-VENV-IGNORE` | 2 | quantum-computing-fundamentals-2833097, research-assist |
| `HOST-PATH` (tracked) | 1 | wearable_data_testing — a *tracked* `settings.local.json` holding `/Volumes/…` and `/Users/…` grants |

### Phase F (retire, after a soak)

`depot/myclickup/.venv`: container-built, shebang
`/workspace/depot/myclickup/.venv/bin/python3`. `.venv-linux` in pipeline,
wearable_data_testing and jeremy_dahl_analytics, each confirmed by its
`/workspace/…` shebang.

### Not venv → [work/0009](../0009-agent-files-and-settings-hygiene/spec.md)

Split out by owner decision (2026-09-11). There are 20 `CLAUDE-ONLY` repos, 2
`BOTH-SUBSTANTIVE`, 2 nested cases and 4 `TRACKED-LOCAL`.

Two scanner fixes came out of this half:
- **Inline imports.** `See @AGENTS.md for …` is a valid stub: Claude Code parses
  `@` imports inline and skips them inside code spans. So is a `CLAUDE.md`
  symlinked to `AGENTS.md`. The first version counted neither, and falsely
  flagged wearable_data_testing as `BOTH-SUBSTANTIVE`.
- **Committed examples.** `*.local.example*` is sanctioned: the owner approved a
  `!*.local.example*` negation in the `.local` rule, which is in macolima's
  `.gitignore` and in the depot handoff's template ask. project_zenbu's
  `config/hub.local.example.yaml` is no longer flagged.

Each fix has a test (41 checks).

## 2026-09-11 — stage 2 handed off

handoff-depot amended (third time) with **T0**, the one-shell test, and
re-delivered. The owner will run the depot agent in the `nranthony` container.
Results are to come back as handoff §6 item 0; PR-2's merge waits on them.

## 2026-09-14 — stage 6: ikigai done; the done-check is down to the sibling's notice block

Hand-back at `/Volumes/DataDrive/repo/nranthony/inbox/0008/handback-ikigai.md`,
verified host-side: `9c4d5e3` (policy, `.python-version` 3.12, `.gitignore`)
and `eac3448` (sweep, ADR-0022, work items 0023 archived and 0011 reduced to
its §3). Clean tree apart from the owner's `.vscode/launch.json`. Not pushed.
`.venv-sandbox` on 3.12.14 under `/opt/uv`; gate 565/565 validate, 328 passed,
0 integrity errors. Both `.venv*/` and the `.local` shapes check-ignore.

- **The build needed the network**: 54 cold cache entries in nranthony. Warm
  now.
- **ADR number was 0022, not 0021** — the handoff read the tree at `64a9b4b`,
  the agent applied it at `f989f86`, and the owner had used 0021 and added a
  `.venv-host` rule in between. Six table rows named archived files. Same
  lesson as the earlier repos, sharper: a handoff written days before it is
  applied must say which commit it read, and the applier re-derives from
  `HEAD`.
- **Policy first needed the owner's hand**: the auto-mode classifier blocked
  the agent's own `.claude/settings.json` edit (self-modification), so the
  gate ran once after the sweep rather than before and after.
- **Owner chose catch-all denies over the four-spelling fence**:
  `Bash(*load_blocks.py*--w*)` and `Bash(*ikigai.db.load_blocks*)`. Observed
  over-match: a `git commit` whose message quoted the loader and its flag was
  denied.
- **Side finding**: a LangSmith key with tracing on in the environment makes
  the test suite POST traces; the proxy refuses (403), tests pass, output is
  noisy. Left for the owner.

**Scan after the hand-back** (`--fail-on HARDCODED-VENV-LINUX,OS-VENV-SELECT`
still exits 1): ikigai's summary row is clean, and its two remaining findings
are both owner-side:
1. `HARDCODED-VENV-LINUX` at `AGENTS.md:27` — inside **windows-ai-sandbox's
   managed notice block** (`managed by windows-ai-sandbox — do not edit here`).
   The repo agent correctly left it. macolima's `sync-agent-notice.sh` writes
   a `managed by macolima` marker, so running it here would append a second
   block, not replace W's. One repo, two sandboxes, one block slot: either
   the block is re-synced from the sibling clone after W's R1 (its notice
   still says the old thing today), or the marker is switched to macolima's
   and W's machines lose their sync target. Owner decision; recorded in the
   replay §3a.11.
2. `ASK-GAP` — the scanner models a fenced script as needing every plain
   spelling fenced; ikigai's fence is deliberately flag-scoped (`*--w*`), so
   a dry run falls through to the allow. Either the scanner learns
   flag-scoped fences or this is an accepted finding. Owner decision.

Wave-2 residue in the nranthony profile, none of it a gate blocker:
`VENV-PATH-IN-CODE` numerai, project_zenbu, webridge; `VENV-PATH-ALLOW`
project_zenbu; `DOC-VENV-LINUX` jeremy_dahl_analytics, therapod/core, and
pipeline's notebook history.

## 2026-09-13 — stage 6: wearable_data_testing done, two venvs re-pinned, ikigai surfaced

Run as three parallel host-side agents; hand-backs verified against the scan.

**wearable_data_testing** (`aa23ea7` lock, `81c0b45` migration; not pushed):
- 0010 §4 done by hand for this repo: the channel's `paperbridge-0.3.0` wheel
  copied into `therapod/dist/` with sha256 `4be3a996…` matching the depot
  manifest; 0.1.0 left in place and `paperbridge>=0.3` pinned, so the flat index
  stays append-only. `uv lock` added only paperbridge 0.3.0 and
  `pydantic-settings`.
- **Blocker not in the spec:** `[tool.uv] find-links = ["/workspace/dist"]`, a
  container-absolute leftover of the hand-copy workflow, made `uv lock` fail on
  the Mac. Removed; the `../dist` index is the route.
- Migration in end-state form, sweep wider than the handoff's table: scripts
  derive `PY` from the variable; justfile `python :=` uses `join()`;
  `just install` moved off `uv pip install -e` (ignores the variable) to
  `uv sync --extra db --extra dev`; five allow rules → `uv run python …`;
  AGENTS.md, README, the setup doc and the four runnable lines in the research
  plan; `.python-version` 3.12; `.gitignore` `.venv*/` plus the `.local` trio.
  Two stale "editable dependency at /Volumes/…/paperbridge" claims corrected.
- Built `uv sync --frozen --extra research --extra db` on 3.12.14 (the 3.13
  venv was recreated by uv after the pin, not deleted). `--extra db` is one
  extra beyond parity, so `weardata.reference.seed` works in-container.
  Preflight: all checks passed, paperbridge imports as 0.3.0. `just validate`
  exits 0 (38/38 devices). No test suite exists.
- Scan: no findings for the repo at all.

**Pins/rebuilds:**
- jeremy_dahl_analytics: `.python-version` 3.12 (`41fd0d0` on `dev/refactor`,
  not pushed); no host `.venv` exists there; `uv sync --frozen` rebuilt
  `.venv-sandbox` on 3.12.14, lock frozen-consistent.
- paperbridge: already pinned; `uv sync --frozen --group dev` (no extras, per
  its justfile: bibtexparser ships no wheel) rebuilt on 3.12.14; 146 passed,
  7 skipped (the zotero extras), ruff clean. Host `.venv` untouched.
- **`.venv-linux` is gone everywhere**, jeremy_dahl_analytics' included — the
  drive-wide find shows none. Phase F step 1 for that name is effectively done;
  only `depot/myclickup/.venv` (container-built, host slot) remains for F.

**ikigai is a wave-1 gate blocker.** The 2026-09-11 entry says nranthony has
none; the 2026-09-13 scan lists `nranthony/ikigai` under
`HARDCODED-VENV-LINUX`. Handoff written ([handoff-ikigai.md](handoff-ikigai.md))
and delivered to `/Volumes/DataDrive/repo/nranthony/inbox/0008/` (the
nranthony workspace root, outside every repo, `/workspace/inbox/0008/` in the
container — same precedent as therapod's). What it found:
- no venv of any kind on the clone; 154 `.venv/bin` lines across 52 tracked
  files point at nothing;
- the `.venv-linux` line sits inside **windows-ai-sandbox's managed notice
  block** in its AGENTS.md, whose claims ("`uv sync` is denied", "`.venv/` is
  irreplaceable") are false here and are echoed into its ADR-0014, README and
  checkpoint-gate skill. Owner/host-side to refresh; the agent is told not to
  edit inside the markers;
- the repo has its own draft `work/0023` proposal for the same change, now
  superseded by the handoff, which answers its three open questions;
- the `load_blocks.py` deny fence has an argparse prefix hole (`--w`, `--wr`
  reach `--write`); the fence in the handoff uses `*--w*`.

**Not done here:** the owner's global `~/.claude/CLAUDE.md` line (D2) — the
agent cannot write that file; text is in the session. Egress: `[pypi]` stays
open by the owner's decision until the remaining builds finish; all three
profiles (nranthony, jeremy_dahl, therapod) were brought up and left up.

## 2026-09-12 — stage 6: misc_code done

Hand-back verified host-side: commit **`eedeb9b`**, clean tree,
`git grep` finds no `.venv-linux` and no `UV_PROJECT_ENVIRONMENT=`, and
`.python-version` is 3.12 tracked. It **no longer blocks the done-check**.

- `setup-linux-venv.sh` was **removed** (`git rm`) rather than reduced:
  `uv sync --locked` builds `.venv-sandbox` unaided, so the script had no job
  left.
- **The build needed no egress** — the registries are closed and it installed
  from the profile's uv cache. `uv run python requirements_to_gsheet.py --help`
  imported gspread, google-auth, google-auth-oauthlib, loguru and python-dotenv.
  The agent noted pandas and openpyxl are **not** exercised by that script, so
  they remain unproven here.
- `README.md` was **not** in the handoff's table but carried the same
  `.venv-linux` export and pointed at the deleted script; the agent found and
  fixed it. Another instance of the §3 tables being a starting point, not the
  set.
- `.gitignore`: `.venv/` and `.venv-linux/` → `.venv*/`, plus the `.local`
  trio; `git check-ignore` re-confirmed `.env`, `credentials.json` and
  `token.json` stay ignored.

## 2026-09-11 — stage 6: pipeline done ([notes-pipeline.md](notes-pipeline.md))

The hand-back is filed as the owner pasted it; a few of its closing lines were
mangled by terminal wrapping. Checked host-side:
- **Commits:** `c06ea66` (executed files, CI, settings, skill, AGENTS.md,
  `.python-version` 3.12) and `7d9a8a2` (docs, script hints, `src/`
  messages, notebooks, `.gitignore`).
- **`uv.lock` unchanged:** last touched `4551275`, before this work.
- **The venv:** `.venv-sandbox` on 3.12, built `--frozen --extra dev --extra truth`
  (118 downloads through the window).
- **Code checks:** `vars.just` uses `join()`; CI sets `UV_FROZEN: '1'`.
- **Gate:** ruff and mypy clean; 644 passed, 79 skipped, 2 xfailed. The mitdb
  corpus isn't in the sandbox, so its truth tests skip even with wfdb
  installed; BACKLOG says to run `mitdb_beat_report.py --check` on a host
  before the next tag.
- **The scan:** only `DOC-VENV-LINUX`, which is recorded notebook outputs and
  work/0005, so history. **Pipeline no longer blocks the done-check.**

**Pipeline and wearable_data_testing now have neither a host `.venv` nor a
`.venv-linux`.** The owner confirmed deleting both, deliberately, to start
clean. (misc_code's and core's host `.venv` are intact.)

**wearable_data_testing is blocked on paperbridge → [work/0010](../0010-paperbridge-delivery/spec.md).**
- Its `uv.lock` (2026-03-31) has no paperbridge entry: the `../dist` index
  pointer came 2026-05-01 and was never re-locked. So `--frozen` installs no
  paperbridge, and its preflight import fails.
- The only wheel in `therapod/dist/` is a hand-copied 0.1.0.
- `vendor-tools` plus a recreate never touches that folder: vendored wheels go
  to image-build staging, and the image installs only myclickup.
- Unblock (0010 §4): copy the channel's 0.3.0 wheel into `dist/` with its hash
  checked, `uv lock` on the Mac without deleting, then `uv sync --frozen`.
  The owner had considered deleting the lock and resyncing; advised against,
  since that re-resolves every dependency. Either way the host needs `uv sync` on the Mac
before its next use there, and `.venv-linux` retirement is done early for these
two. wearable_data_testing's `.venv-sandbox` exists on **3.13**, unpinned, and
predates its handoff. Pipeline's lessons were relayed to its agent before it
continues:
- pin before building;
- `--frozen`, with like-for-like extras;
- `uv pip` hints;
- `subprocess` calls on venv paths;
- grep `.venv/bin` too.

## 2026-09-11 — stages 5–6 in progress

**Stage 5 (the recreate sitting).** `nranthony` was recreated and `just verify`
passed, including both new checks. The "just shebang recipes run" check
passing means the image's **just 1.51.0 honours `JUST_TEMPDIR`**, so no
justfile fallback is needed. The other three profiles were being recreated as
of this entry. The VS Code image config (B6) is in: paperbridge shows
`.venv-sandbox` as its interpreter, and `.venv` as broken, which is correct
inside the container.

**Findings from the sitting:**
- **VS Code remembers each workspace's interpreter choice, and the default
  doesn't override it.** pipeline still had `.venv-linux` selected and
  auto-activated it in new terminals. So `python`/`pytest` there ran the old
  venv even though uv, correctly, ignored `VIRTUAL_ENV=.venv-linux` and
  targeted `.venv-sandbox`. Fix, once per workspace: `deactivate`, then
  **Python: Select Interpreter → `.venv-sandbox`**. Expect it in
  wearable_data_testing and jeremy_dahl_analytics too. Never `uv sync --active`.
- **Repos with only a host `.venv`** show "could not resolve `.venv-sandbox`".
  That's expected until they're built. Build lazily, only for repos used in
  the sandbox:
  - repo has a `uv.lock`: `with-egress.sh <p> --with pypi -- 'cd … && uv sync --frozen'`;
  - `pyproject.toml` but no lock: run `uv lock` on the **host**, commit, then as above;
  - no `pyproject.toml` (therapod/financials): `uv venv` plus
    `uv pip install --python .venv-sandbox -r requirements.txt`, or leave it host-only.
- **Pylance "too many files" in pipeline:** `data/` holds 418,034 parquet
  files, and `workspaces/` is data too. Dot-folders are excluded by Pylance's
  defaults. Recommended for pipeline's untracked `.vscode/settings.json`:
  `python.analysis.exclude` = `**/node_modules`, `**/__pycache__`, `**/.*`,
  `data`, `workspaces` (restating the defaults, since setting it may replace
  them), plus `files.watcherExclude` for `data/` and `workspaces/`.
- **An unpinned `uv sync` in pipeline** (run by hand at 18:11) built a
  half-populated `.venv-sandbox` on **3.13**: runtime packages only, no dev
  extra. The owner deleted it to start clean.
- **`uv.lock` was deleted along with it, by mistake. Restored from git before
  any sync ran.** Syncing without the lock would have re-resolved everything
  against today's PyPI, with egress opened by hand, so no age gate and no
  audit record. Worth remembering when "starting over": the venv is
  disposable; the lock is the record.

**Egress state (standing reminder).** `[pypi]` was opened **by hand** for
pipeline's build: `.pypi.org` and `.files.pythonhosted.org` uncommented, not
via `with-egress.sh`, so no sentinel, age gate or `depgate.jsonl` line.
**Re-comment and `squid -k reconfigure` when the builds are done.** `[npm]` has
also been open since `cc98519` (2026-09-08, wrangler); the owner hasn't decided.

**The pipeline agent's pre-flight review.** Eight points and five questions
were raised against `handoff-pipeline.md`, and all were accepted. They're
handoff gaps worth carrying into the wave for the remaining repos:
1. Pin `.python-version` **before** the build (one build, on 3.12, not 3.13
   then a rebuild).
2. **CI:** every `${{ matrix.venv }}/bin/…` step, not just the version step →
   `UV_FROZEN: 1` at job level plus `uv run`. A plain `uv run` re-locks when
   `pyproject.toml` and `uv.lock` disagree, so CI could quietly test a
   different tree.
3. **Docs:** plain `uv run …`, with the convention stated once in AGENTS.md;
   `--frozen` where results are validated (the mitdb skill, and CI through
   `UV_FROZEN`).
4. **A real executed reference the grep had missed:**
   `scripts/backfill_h10.py:389` runs `subprocess.run([".venv-linux/bin/alembic", …])`
   → `[sys.executable, "-m", "alembic", …]`, which needs no venv name at all.
5. **`uv pip` also appears in `src/` runtime error messages.** The fix hint is
   `uv sync --frozen --extra dev --extra <x>`, because `uv sync` removes any
   extra you don't name, dev tools included.
6. **The gate needs the same extras as before** (`--extra truth`), or the
   mitdb tests skip and the comparison with `.venv-linux` isn't like-for-like.
7. **`root / venv` in just doubles an absolute path**; `join()` handles it
   (the agent tested it).
8. **Host reset script:** `reset_host.sh` removes only `.venv` (the host's).
   The notebook kernelspec display name becomes neutral. W's notice block in
   AGENTS.md ("anything inside a `.venv` is disposable") is left for W's
   refresh and reported in the hand-back.

## 2026-09-11 — depot T1–T4 done; myconv 0.9.0 re-vendored

The reply is at `agentic-conventions/work/0022-venv-per-environment/reply-to-macolima-work-0008.md`
(tracked there; that file is the record).
- **The rule:** agentic-conventions **ADR-0017**, shipped in **myconv 0.9.0**
  (`1a6df64`, published).
- **Pins:** myclickup and paperbridge pinned **3.12**. myclickup's
  `.venv-sandbox` was rebuilt offline on 3.12, 309 passed, host `.venv`
  untouched. The `.gitignore` lines (`.venv*/`, the `.local` trio) went into all
  four depot repos, and no tracked file was affected.
- **Not republished:** neither wheel changed.
- **No objection to §1.** Everything is committed in their repos, nothing pushed.

What they flagged for macolima:
1. **Permission-rule semantics were unverifiable from the sandbox** (docs
   blocked). → Quoted verbatim into `docs/permissions-model.md` §"How a Bash
   rule matches" (fetched host-side 2026-09-11), and cited from ADR-0013 and
   `workspace-scan.py`. The docs add two things: matching happens "after
   Claude Code splits compound commands and strips wrappers", and an ask/deny
   rule "isn't a security boundary around the program".
2. **`/tmp` being `noexec` breaks `just` shebang recipes** (`Permission denied`).
   Their workaround: `TMPDIR=/home/agent/.cache/just-tmp`. just has a scoped
   knob, `JUST_TEMPDIR` (host just 1.58 shows it; the image pins **1.51.0** —
   confirm it's honoured there). → **Owner approved; done:**
   `JUST_TEMPDIR=/home/agent/.cache` in compose. Also a behavioural
   `verify-sandbox.sh` check that runs a shebang recipe, so the recreate
   sitting's `just verify` proves the image's just honours it. After the
   switch, depot AGENTS.md's `TMPDIR=` workaround is unnecessary; tell the
   depot agent with the T5 signal.
3. **paperbridge's hand-maintained notice block** (its own markers, "mirrors
   windows-ai-sandbox") names `/root/.cache/uv`. It's paperbridge's text, not a
   macolima-managed block. → Suggest the depot agent reword it
   sandbox-neutrally (`~/.cache/uv`); relay with the T5 signal.

ADR-0013 now cites ADR-0017 and myconv 0.9.0. **myconv 0.9.0 re-vendored**
(`vendor-tools.sh`; lock `--check` green; only the skill tree changed, wheels
identical). Skills converge on recreate, so **no image build**.

paperbridge's gitignored `.claude/settings.local.json`: its three
`.venv/bin/pytest …` allow rules became `uv run pytest …` (owner-approved).
They now work on both sides.

## 2026-09-11 — stage 3 built (uncommitted, awaiting review)

Branch `dev/0008-venv-per-environment`. `just test-offline` is green: hook
210/210, scan 41/41, notice 13/13, private names OK, CLAUDE.md in sync.
`PROFILE=_test docker compose config` renders the variable.

- **B1** `docker-compose.yml`: `UV_PROJECT_ENVIRONMENT=.venv-sandbox` beside
  `UV_LINK_MODE`, commented.
- **B2** hook: `.venv-sandbox` **replaces** `.venv` in the disposable exception.
  This was revised while building: inside the container a plain `.venv` is the
  host's, so deleting in it now asks. Exact-name locks for `.venvrc` and
  `.venv-sandbox-notes.md`.
- **B3** notice: a "venv here is `.venv-sandbox`" bullet under capabilities, and
  the disposable list corrected.
  - The agy check: it's a known, documented gap
    (`sandbox_templates/antigravity/README.md`, "gated but not briefed"). agy
    inherits the variable and the shared hook, so the rule holds for it; the
    notice text reaches it only through a repo's AGENTS.md (work/0009 helps).
- **B4** `verify-sandbox.sh`: fails on unset, absolute, or any other name.
- **B5** docs:
  - **ADR-0013**; the index says the number is shared with the sibling.
  - `local-wheels.md`, `profile-seed-database.md`, `extending-a-profile.md`,
    `virtiofs-gotchas.md`; README §B (VS Code interpreter).
  - AGENTS.md: an invariant and a pointer row.
  - `work/README.md` explains that ported `work/0008–0010` citations are the
    sibling's.
- **New measured fact: `uv pip` ignores `UV_PROJECT_ENVIRONMENT`.** With a
  `.venv` in the CWD it used that; `--python .venv-sandbox` works. It's now in
  the ADR, notice, AGENTS.md, `local-wheels.md`, spec §7.2, depot rule 5a and
  all three therapod handoffs (re-delivered).

## 2026-09-11 — stage 2 done: T0 held ([handback-depot-T0.md](handback-depot-T0.md))

The depot agent ran T0 in the `nranthony` container. The image's uv is **0.12.9**,
the same as the host's.
- Synced from `myclickup/src`, the venv was created at
  `myclickup/.venv-sandbox`, with nothing under `src/`.
- `uv run --project myclickup` from the depot root put `.venv-sandbox` on
  `sys.path`.
- The gate (`just test`; myclickup has no `check`) passed **309**.
- The host-slot `.venv` is byte-identical before and after.
- `git status` is clean, thanks to uv's self-ignore; the repo's own `.venv`
  line still doesn't match `.venv-sandbox`.
- Unpinned, uv picked **CPython 3.13.15**. That's evidence for the
  `.python-version` pins.
- paperbridge failed offline at `certifi`. The earlier probe stopped at `ruff`:
  pydantic, lxml, requests, ruff and pyzotero are all missing from the
  `nranthony` cache, so **paperbridge's venv needs an egress window**.

The agent raised no objection to §1. So spec §4's "still to verify in the
container" is now verified, and the merge waits only on the PR itself.

Two small corrections from the handback:
- `/tmp` being `noexec` doesn't stop `python -m …` from a venv built there,
  because `bin/python` links into `/opt/uv/python`. Running its console scripts
  directly is untested.
- paperbridge's README and ARCHITECTURE never name a venv path. The earlier
  analysis matched `uv sync` / `uv run`.

## 2026-09-11 — order revised: switch first, repos after (supersedes the two entries below it)

The owner asked why the wave-1 handoffs wrote conditional "if the variable is
empty…" wording into repos. That wording existed only because of the order
(repos edited before the switch, so every edit had to work in both states).
With the owner holding repo use until the rollout is done, the order flips:

1. T0;
2. one macolima PR (B3a warning dropped, no PR split, no pre-merge scan gate);
3. recreate every profile in one sitting;
4. the repos, one final-form pass each.

The three therapod handoffs were **rewritten in final form** (the venv items
first planned for a later wave are folded in) and **re-delivered**, replacing
the first versions unread. The scan is now the "finished" check. The owner's
preference is saved to memory: repo docs describe the end state, and handoffs
carry transitional caveats.

## 2026-09-11 — stage 3: wave-1 handoffs (superseded above)

Drafted for the three gate blockers: `handoff-pipeline.md`,
`handoff-wearable_data_testing.md`, `handoff-misc_code.md`. None of the three
repos has an `inbox/` (therapod/website does), and creating one would leave an
untracked, unignored directory in each. So they're delivered to the therapod
workspace root, `/Volumes/DataDrive/repo/therapod/inbox/0008/`, outside every
repo, visible in the container as `/workspace/inbox/0008/`.
