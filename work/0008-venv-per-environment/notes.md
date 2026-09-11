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
