# 0008 — plan

`H` = host/human step (outside what the agent can or should do). Everything else
is agent work in this repo. Step IDs (A1, B3, …) are stable — `handoff-depot.md`
and `replay-other-hosts.md` cite them — so the rollout below reorders steps
without renumbering them.

**Public-repo rule for every edit outside `work/`:** this repo is public.
`scripts/private-names-check.sh` gates README, AGENTS/CLAUDE.md, justfile,
`scripts/`, `sandbox_templates/` (so the agent notice and the hook),
`docs/index.md`, compose and the Dockerfile — but **not** the rest of `docs/`,
and not `docs/adr/`. In B5's docs and ADR edits, placeholders — `<profile>`,
`<repo>` — are a discipline the gate will not enforce. Names stay in this work
item (out of the check's scope by design; owner confirmed 2026-09-11), except
the full A1 scan, which is local-only (A1 "Output").

---

## Rollout order (revised 2026-09-11: switch first, repos after)

**Two facts the order is built around:**
1. **Merging the compose variable (B1) is the switch for every profile at
   once.** The compose file is shared, so every profile picks it up on its next
   `recreate`, including one done for an unrelated reason.
2. **Until a profile has switched, `uv run` / `uv sync` in its container are
   destructive** in any repo whose `.venv` is the host's (spec §7.0).

So the switch goes **first**, and every profile is recreated in one sitting.
Repos are edited **after**, in final form (`uv run …`; a path derived from the
variable, falling back to `.venv`). No repo doc ever carries transitional
wording. The owner is holding repo use until the rollout is done, so there are
no users in between. The one caveat left lives in the handoffs: a precondition
check.

*Superseded the same day:* a "repos first" order with fallback wording, a
pre-switch notice warning (B3a), two PRs, and a merge gate on the three therapod
repos. Rationale in spec §7.0–7.1.

| Stage | What | Who | Done when |
|---|---|---|---|
| 0 | Clear the decks | — | **done 2026-09-11** ([notes](notes.md)) |
| 1 | **Discover:** the all-repo scan (A1) | me | **done 2026-09-11**: 55 repos; 3 therapod repos pin `.venv-linux` |
| 2 | **Prove in one shell:** the rule in the real image, no merge, no recreate (B8 = handoff-depot T0) | depot agent in `nranthony`, owner at the prompt | **done 2026-09-11**: all passed, no objection to the rule ([handback](handback-depot-T0.md)) |
| 3 | **Build the switch:** one PR, B1–B5, B7 | me, in parallel with stage 2 | **done 2026-09-11** on `dev/0008-venv-per-environment`, `test-offline` green, committed as the `feat(scan)` and `feat(venv)` commits ([notes](notes.md)) |
| 4 | **Merge the switch** | owner | **done 2026-09-11**: merged locally into `main` (`--no-ff`) on the owner's instruction, after T0 passed with no objection. **Not pushed.** From here, any profile's next recreate picks up the variable |
| 5 | **Recreate every profile, one sitting;** `just verify <p>` each; then B6 (VS Code) | owner | four verifies green; `echo $UV_PROJECT_ENVIRONMENT` → `.venv-sandbox` in each |
| 6 | **Repos, in final form, in one egress sitting:** the three therapod handoffs; depot T5; the other profiles' venvs build on first `uv sync` | repo agents; owner opens egress, then re-comments | the handoffs report back; `just workspace-scan --fail-on HARDCODED-VENV-LINUX,OS-VENV-SELECT` exits 0 |
| 7 | **Conventions release** (handoff-depot T1–T4), then the remaining repos' handoffs cite its ADR | depot agent; me | **released 2026-09-11**: ADR-0017, myconv 0.9.0 published and re-vendored here (uncommitted). Remaining: the other repos' handoffs, bundled with 0009 if the owner agrees |
| 8 | **Other machines:** ferry the replay | owner | replay §0 holds |
| 9 | **Retire** old venvs after a soak (F) | owner | a scan shows no `.venv-linux` and no sandbox venv in a `.venv` slot |

Host prep (D1 shell profiles, D2 global CLAUDE.md) can happen any time.

**Rollback** is cheap until stage 9: remove the compose line and recreate. Old
venvs are still on disk, and a stray `.venv-sandbox` is harmless. A repo already
edited to final form would then need a revert too, which is the price of "switch
first". It is small, and a rollback is not expected.

---

## Phase A — inventory and the conventions rule (no live change)

### A1. All-repo scan (host-side, read-only) — stage 1; re-run as the stage-6 done-check

**Decided 2026-09-11 and built:** a committed script, `scripts/workspace-scan.py`
(stdlib, read-only; `just workspace-scan`; `workspace-scan.test.sh` in
`test-offline`). **Scope:** every profile (fluidmomenta, jeremy_dahl, nranthony,
therapod — depot members included via nranthony), plus host-only roots listed in
the untracked `.workspace-scan.local` (today: `/Volumes/DataDrive/repo/sandbox`,
i.e. macolima and the Mac clone of windows-ai-sandbox — AGENTS/settings checks
apply fully there; venv-slot findings are informational since no profile mounts
them). The same script is what `replay-other-hosts.md` R3 runs on each Linux
machine (`--profiles-dir ~/.ai-sandbox/profiles --workspaces-root ~/repo`).

Host-side because each container sees only its own profile. Walks every
profile's workspace (`/Volumes/DataDrive/repo/<p>/` for each `<p>` under
`/Volumes/DataDrive/.claude-colima/profiles/`), one row per git repo (a dir
holding `.git`), depth 4, skipping hidden dirs, `node_modules` and any venv.

Per repo, report:

**Agent instruction files — "AGENTS.md is the source, CLAUDE.md is the stub"**
- `AGENTS.md` present?
- `CLAUDE.md` state: absent / generated stub (`@AGENTS.md` import only) /
  **substantive** (has its own content).
- Flags:
  - `CLAUDE-ONLY` — substantive `CLAUDE.md`, no `AGENTS.md` (agy reads nothing).
  - `BOTH-SUBSTANTIVE` — two sources of truth that will diverge.
  - `AGENTS-NO-STUB` — `AGENTS.md` without a `CLAUDE.md` importing it (Claude
    Code does not read `AGENTS.md` natively).
  - Same checks for nested `AGENTS.md`/`CLAUDE.md` pairs below the repo root.

**Claude Code settings** — `.claude/settings.json` (tracked) and
`.claude/settings.local.json` (usually gitignored — note which)
- Allow/ask/deny rules naming a venv path (`.venv/bin/`, `.venv-linux/bin/`, …).
- **Ask-fence coverage (`ASK-GAP`):** for every script named in ask/deny rules,
  generate each plausible spelling (`python`/`python3`, `uv run` forms, both
  venvs, `./` forms, direct and `-m` where applicable) and report any that no
  rule matches — the check behind the owner's "asks in place for every scenario"
  (handoff-depot rule 6).
- Rules or hooks naming an absolute host path (`/Volumes/…`, `/Users/…`, `/home/<host-user>/…`)
  — dead inside a container.
- Bare `WebFetch` (no `domain:`) — forbidden by `docs/permissions-model.md`.
- `hooks` blocks (list them; a repo hook stacks on the sandbox's).

**Python environment**
- Every venv dir and its `pyvenv.cfg` `home`, classified `host` / `sandbox`
  (`/usr/bin`, `/opt/uv/…`) / `dead` (home missing on this machine), and the
  **slot** it sits in (`.venv`, `.venv-linux`, …). Flag sandbox-in-`.venv` and
  any `.venv-linux`.
- `.gitignore` coverage of `.venv*/` (test with `git check-ignore -q .venv-sandbox/x`).
- Tracked `.python-version`? Its value within {3.12, 3.13}?
- Hard-coded venv references in tracked files: `.venv-linux`, `.venv/bin/`,
  `os() == "macos"`-style venv selection in justfiles, `PY=.venv…` in scripts,
  CI `UV_PROJECT_ENVIRONMENT` / matrix `venv:`. Exclude `work/archive/`,
  `docs/_archive/` (history). **This subset picks the repos that get a handoff at
  the switch (Phase E) and, re-run, is the stage-6 done-check**: `--fail-on
  HARDCODED-VENV-LINUX,OS-VENV-SELECT` exits 0 once every handoff has landed in
  final form.

**Machine-local files**
- `.gitignore` covers both `.local` shapes — test
  `git check-ignore -q x.local` **and** `git check-ignore -q x.local.md`
  (pointer files end in `.local`; documents keep their extension after it, e.g.
  `AGENTS.local.md`). Flag `NO-LOCAL-IGNORE` for either miss.
- Tracked files that match either shape (`git ls-files | grep -E '\.local($|\.)'`)
  — a machine-local file already committed; adding the ignore will not untrack
  it, so each needs an owner decision.

**Output — the full scan is local, never committed.** Every-repo, every-profile
table → `work/0008-venv-per-environment/scan.local.md`, ignored by this repo's
`*.local.*` rule (verify with `git check-ignore` before writing a row). The owner
decided to keep names in this work item (2026-09-11), so the tracked `notes.md`
may name repos — but it carries only the **actionable subset**: the repos that
need a Phase E handoff and why, plus counts per flag. The complete repo list of
every profile stays out of the public repo. **Decide at the end of A1**
whether the scan is worth keeping as a script (re-runnable drift check — stage 5
re-runs it at least once, which argues for it) or was a one-off; if kept, it is
host-side and read-only, and any `justfile` recipe for it is a thin pass-through
per AGENTS.md.

### A2. Deliver the depot handoff

[handoff-depot.md](handoff-depot.md) → doorbell copy in `depot/inbox/`
(gitignored there). It covers:
- T0, the one-shell test (stage 2);
- the agentic-conventions ADR, template, reference and audit (T1);
- the depot members' local fixes (T2–T3) and the publish (T4);
- T5, after the switch.

**Delivered 2026-09-11 and re-delivered with each amendment** (the `.local`
rule, rule 6, T0 and the paperbridge warning).

---

## Phase B — the macolima change, one PR (stage 3)

B1–B5 and B7, plus what's already in the working tree: the `.gitignore` /
`.dockerignore` `.local` lines and the workspace scanner. **One PR, merged at
stage 4, never split:**
- a notice saying "your venv is `.venv-sandbox`" before the variable exists
  would be false;
- a verify assertion without the variable would fail every profile;
- doc run-lines that say `uv run …` are only safe once the variable is set
  (spec §7.0).

The ADR goes in as *Accepted*.

### B1. Compose variable

`docker-compose.yml`, `claude-agent.environment`, directly under `UV_LINK_MODE`:

```yaml
      - UV_PROJECT_ENVIRONMENT=.venv-sandbox
```

Comment above it (match the `UV_LINK_MODE` comment's density): uv deletes and
recreates a project env whose interpreter is unusable, so with the default
`.venv` the container and the host destroy each other's venv on every alternate
`uv run`; relative value resolves against the project root; hosts leave it unset;
not `UV_PYTHON` (overrides `.python-version`); runtime-only, recreate not
rebuild; cite ADR (B5). Then `PROFILE=_test docker compose config`.

### B2. Deletion-hook carve-out

`sandbox_templates/claude/hooks/deny-destructive.sh:729`: **replace**
`*/.venv/*` with `*/.venv-sandbox/*`. It is not added beside `.venv`. That was
revised while building, 2026-09-11: after the switch, a repo's plain `.venv`
inside the container is the *host's* venv, so deleting in it must reach the
prompt, not pass as disposable. **Not** `*/.venv*/*` either (spec §7.4). The
comment block and the `emit_ask` message name `.venv-sandbox`. `.venv-linux`
stays out: removing one is `rm -rf`, denied regardless.

`deny-destructive.test.sh`: the old "rm inside .venv passes" became an **ask**
lock, plus pass for `.venv-sandbox/…` and ask for the files `.venvrc` and
`.venv-sandbox-notes.md`. 210/210.

One hook serves both agents (`guardrails.sh` symlink) — confirm, don't copy.

### B3. Agent notice

`sandbox_templates/common/agent-notice.md`:
- L68 disposable list: `.venv` → `.venv` or `.venv-sandbox`.
- New short section **"Python environments"**, in the notice's voice:
  - This container's project venv is `$UV_PROJECT_ENVIRONMENT` (`.venv-sandbox`)
    in each repo; `uv run` / `uv sync` use it automatically.
  - A repo's `.venv` belongs to the **host**. Never run it, `uv sync` into it,
    `source` it, or delete it — even if it looks broken; it is broken *here*
    because it is not yours.
  - Don't hard-code a venv path in anything you write (scripts, justfiles,
    settings allow rules, docs); use `uv run`. If a path is unavoidable, derive it
    from `UV_PROJECT_ENVIRONMENT` with `.venv` as the fallback. Never pick a venv
    by OS.
  - Which environment built a venv is in its `pyvenv.cfg` `home` line.
- Run `scripts/agent-notice.test.sh` (it bans host-side command names in the
  notice — keep `profile.sh`/`docker` out of the new text).
- Check whether agy receives this notice at all (`profile.sh` L897/L1810 sync
  it only into `claude-home/CLAUDE.md`). If not, record it here as a gap; agy
  still inherits the env var, which is the part that matters.

*(B3a, a pre-switch warning in the notice, was dropped 2026-09-11: with the
switch first and repo use on hold, the condition it warned about never meets
a user.)*

### B4. `verify-sandbox.sh` tripwire

New assertion: `UV_PROJECT_ENVIRONMENT` equals exactly `.venv-sandbox` (relative,
not absolute — an absolute value would put every repo in one venv). `fail` on
unset or different. The Gate-3 `find` already excludes `*/.venv-*/*` (L568) —
no change there.

### B5. Docs + ADR

- New ADR at the next free number (`0013` at time of writing): *"The environment
  names the venv"* — context (recreate-on-mismatch, the sibling's WSL sharing,
  `os()` failing), decision (spec §2), consequences, the two-hosts exception,
  the rollout order above (switch first, all profiles at once, repos after, and
  why), and the rejected alternatives (per-OS names; arch suffix; `UV_PYTHON`;
  Dockerfile `ENV`; a per-profile opt-in variable; "repos first" with fallback
  wording in repo docs). Link it from the ADR index. Cite the
  agentic-conventions ADR once it has a number.
- `docs/local-wheels.md` L13, `docs/profile-seed-database.md` L15/42/61/76/97:
  `.venv-linux` → `uv run …`. Generic names only. This ships in the same PR as
  the variable, which is the only reason `uv run …` is safe to write there.
- `docs/extending-a-profile.md` L62 and L167: `.venv` → `.venv-sandbox`, and say
  the host's `.venv` is a separate environment.
- `docs/virtiofs-gotchas.md`: one line beside the `UV_LINK_MODE` paragraph
  pointing to the ADR.
- `AGENTS.md`: one invariant bullet ("`UV_PROJECT_ENVIRONMENT=.venv-sandbox` in
  compose; never make it absolute; never set `UV_PYTHON`") and a gotcha-pointer
  row for the ADR. Then `just sync-agent-files`.
- README §B (attached-container config): add the interpreter setting from B6.

### B6. VS Code in the container (H — host user file) — stage 5, after the recreates

Not before: until a `.venv-sandbox` exists, the setting points at nothing.

`~/Library/Application Support/Code/User/globalStorage/ms-vscode-remote.remote-containers/imageConfigs/macolima%3alatest.json`
currently holds `extensions` + `workspaceFolder` only. Add:

```json
"settings": {
  "python.defaultInterpreterPath": "${workspaceFolder}/.venv-sandbox/bin/python"
}
```

Verify in an attached window on a repo with a built `.venv-sandbox`: the status
bar interpreter is `.venv-sandbox`, not the host `.venv`. `defaultInterpreterPath`
only applies before a user picks an interpreter per workspace — a workspace
that already remembers `.venv` has to be re-picked once. Note that in README §B.

### B7. Offline gate

`just test-offline` (includes the hook suite, agent-notice test,
sync-agent-files `--check`, private-names check).

### B8. Prove the rule in one shell — stage 2, before the merge

No compose change, no recreate. It runs inside the `nranthony` container, by
the depot agent with the owner at the prompt. **The steps are
[handoff-depot.md](handoff-depot.md) §4 T0**, which is the source of truth:
- the variable is prefixed on each command (the agent's shell keeps no state,
  and `env` is denied);
- `--offline` on every call;
- no scratch venv in `/tmp`, which is `noexec`; everything runs against the
  real myclickup checkout;
- steps from a subdirectory and from the parent;
- myclickup's gate;
- the host-slot `.venv` checked byte-identical afterwards;
- paperbridge expected to fail offline.

Results come back as handoff §6 item 0 and go into `notes.md`. A failure here
reshapes the rule before anything depends on it, which is the point of doing
it first.

---

## Phase C — activation: every profile, one sitting (stages 5–6)

Right after the merge, before anyone uses a repo:

1. **H** `scripts/profile.sh <p> recreate` for **all four** profiles, then
   `just verify <p>` for each (the B4 assertion must pass).
2. **H** B6, the VS Code interpreter setting.
3. **H** open one egress window, only if a cache is cold (therapod's will be).
   Then run the repo work: the three therapod handoffs (Phase E) and depot T5.
   Other repos build their `.venv-sandbox` on first `uv sync`, whenever they're
   next used. **When the window closes, re-comment the planning-mode domains and
   reconfigure Squid. Confirm it explicitly; don't leave it implied.**
4. `just workspace-scan --fail-on HARDCODED-VENV-LINUX,OS-VENV-SELECT` exits 0.

Old venvs are **not** deleted here. That is Phase F, after a soak.

---

## Phase D — hosts and the sibling

- **D1 (H, any time)** Each host: confirm nothing exports `UV_PROJECT_ENVIRONMENT`
  (macOS `~/.zshrc`/`~/.zprofile`; WSL and Ubuntu `~/.bashrc`/`~/.profile`/`~/.zshrc`;
  plus any direnv `.envrc` A1 finds). `env | grep UV_` in a fresh shell.
- **D2 (H, any time)** Global `~/.claude/CLAUDE.md` (the agent cannot
  write it). True before and after the switch. Suggested replacement for the
  venv line:
  > If `.venv` exists, use it. Never use or modify `.venv-sandbox` — it belongs to
  > a sandbox container. If `.venv`'s `pyvenv.cfg` `home` is a Linux path
  > (`/usr/bin`, `/opt/uv/…`), it is a leftover sandbox venv: say so rather than
  > using or rebuilding it. Otherwise, ask which conda env to use before
  > installing anything.
- **D3 (H, ferried, stage 7)** windows-ai-sandbox, on every WSL and bare-Linux machine:
  [replay-other-hosts.md](replay-other-hosts.md) is the ferried payload. It covers
  what differs there (root user, bind-mounted cache, shebang-based venv
  classification, the `/mnt/c` two-hosts case, W's docs that currently say the
  opposite) and the R1–R6 order. Ferry it only after its §0 start conditions
  hold. Record it in `docs/sibling-repo-relationship.md`'s live backlog ("what W
  is owed").

---

## Phase E — repo handoffs: one per repo, final form, after the switch

One handoff per repo, filed here as `handoff-<repo>.md`, applied **after** that
profile has switched. Each opens with a precondition: `echo
$UV_PROJECT_ENVIRONMENT` must print `.venv-sandbox`, otherwise stop. That is
the only transitional line, and it lives in the disposable handoff, never in the
repo. Everything the repo gets is end state:
- `uv run …` in commands;
- `${UV_PROJECT_ENVIRONMENT:-.venv}` / `env_var_or_default("UV_PROJECT_ENVIRONMENT", ".venv")`
  where a path is unavoidable;
- allow rules in the `uv run …` form;
- `.gitignore` gets `.venv*/` plus the `.local` lines;
- a tracked `.python-version`;
- CI treats runners as hosts.

It's **one pass per repo**: the venv items first planned for a later wave are
folded in, so nothing waits for the conventions ADR. The handoffs cite spec §2.

**The three repos the scan flagged: drafted, rewritten to final form and
re-delivered 2026-09-11** to `/Volumes/DataDrive/repo/therapod/inbox/0008/`.
That's the therapod workspace root, outside every repo; none of the three has an
`inbox/`. The container sees it as `/workspace/inbox/0008/`. The first versions
(fallback wording, to be applied before the switch) were replaced unread.

**Every other repo** (the 0008 counts in [notes](notes.md): `.venv*/` ignores,
`.python-version`, the `.local` lines, `.venv/bin/…` mentions) waits for the
conventions release. Its handoff then cites the ADR, and bundles 0009's items if
the owner takes that recommendation.

| Repo | Handoff (final form, after the switch) | Later |
|---|---|---|
| `therapod/pipeline` | `vars.just`: the `os()` switch → `env_var_or_default("PIPELINE_VENV", env_var_or_default("UV_PROJECT_ENVIRONMENT", ".venv"))`; `bootstrap_host.sh` OS switch → `${UV_PROJECT_ENVIRONMENT:-.venv}`; CI drops the matrix `venv:` and its step `UV_PROJECT_ENVIRONMENT`; allow rules → `uv run`; skill, AGENTS.md, conftest, scripts and docs → `uv run …`; `.gitignore`; `.python-version` 3.12 | F: `.venv-linux/` |
| `therapod/wearable_data_testing` | scripts `PY="${UV_PROJECT_ENVIRONMENT:-.venv}/bin/python"`; justfile `python :=` from the variable (fixes a recipe broken in the container today); allow rules → `uv run`; AGENTS.md and the setup doc; `.gitignore`; `.python-version` 3.12 | F: `.venv-linux/`. 0009: the tracked `settings.local.json` |
| `therapod/misc_code` | `CLAUDE.md` stops exporting the variable ("the sandbox sets it; never export it"); `setup-linux-venv.sh` removed or reduced to `uv sync --locked`; `.gitignore`; `.python-version` 3.12 | 0009: CLAUDE.md → AGENTS.md |
| `therapod/citation_tools` | none needed — A1 clean apart from `.local` ignores. Its apply-conventions run finished 2026-09-11 **note, I've manually instructed the agent in citation_tools to use .venv-sandbox as part of a apply conventions underway** — confirmed: its docs say the sandbox sets `UV_PROJECT_ENVIRONMENT`, and no executed or followed file hard-codes a venv path; the four-rule wildcard ask fence was added per script (uncommitted, for its owner) | its `.venv-sandbox` is built but empty, blocked on registry access (its work/0001): fill it in the stage-6 egress sitting. Its old sandbox `.venv` is already gone. Source builds are opted in by its ADR-0004 (verify will warn; the reason is recorded) |
| `jeremy_dahl/jeremy_dahl_analytics` | after the conventions release: `docs/IN_TRANSIT.md` run lines → `uv run`; `.gitignore`; `.python-version` | F: `.venv-linux/` |
| anything else A1 flags | after the conventions release | per the notes' table |

---

## Phase F — retire (stage 9, after a soak)

Per profile, once it has run clean on `.venv-sandbox` for a while (the owner
calls when):

1. **H** delete the retired venvs on the host: that profile's list from A1
   (sandbox-built `.venv` leftovers such as `depot/myclickup/.venv`, and every
   `.venv-linux`), each checked by its console-script shebang first. Never by
   glob. After this step a rollback means rebuilding venvs, which is why it is
   last.
2. Re-run A1: no `.venv-linux` on disk, no sandbox venv in a `.venv` slot.

(There's no "drop the transition fallbacks" step any more: the handoffs wrote
final form from the start.)

---

## Exit

Spec §8. Then archive this folder per `work/README.md`, distilling the ADR (B5)
as the durable record.
