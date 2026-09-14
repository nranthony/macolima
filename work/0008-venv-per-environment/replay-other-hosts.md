# 0008 — replaying the venv rule on the WSL and bare-Linux hosts

**State:** ready to ferry 2026-09-14 — the Mac rollout is done (done-check exits 0), corrections folded in (§3a), and the notice steps are superseded by [0011's replay](../0011-sandbox-notice-global-homes/replay-sibling.md), which travels with this file. **Written:** 2026-09-11.
**Carrier:** human-ferried. Every non-Mac machine runs **windows-ai-sandbox**
(W), and no macolima container or host session can reach them. The executing
tier is W: it opens its own work item from this file (numbering continues from
its own `work/`) and runs it once per machine.

Why a file inside 0008 rather than a separate macolima work item: macolima
executes none of this, and the rule, the scan and the per-profile procedure are
the same ones in [spec.md](spec.md) and [plan.md](plan.md). A second work item
would copy them and then drift. This file records only **what differs** on those
machines and the order to do it in.

## 0. Start conditions — replay what is proven, not what is planned

1. macolima 0008 has finished its own rollout (plan "Rollout order"): B8 passed
   in a single shell, the switch merged, every Mac profile recreated, and the
   repo handoffs done. The in-container uv behaviour (spec §4) is then
   measured, not assumed.
2. The agentic-conventions release carrying the rule is published
   ([handoff-depot.md](handoff-depot.md) T1–T4). W consumes it by re-vendoring,
   exactly as it takes any myconv release.
3. Any correction macolima found while executing is folded back into this file
   first. A replay of a plan that was changed mid-flight is the failure this
   file exists to prevent.

## 1. What travels by git and what each machine must redo

| Thing | Travels | So on each WSL / Linux machine… |
|---|---|---|
| Repo-side changes (`.gitignore` pairs, `.python-version`, justfile selectors, docs) | **git** — made once, pulled everywhere | pull; nothing to redo. **Pull only AFTER that machine's switch (R4):** the edits are final-form, meaning they assume the container sets the variable. Used inside a container that doesn't set it yet, their `uv run …` would treat the host's `.venv` as its target |
| agentic-conventions rule | depot channel → re-vendor | W's normal re-vendor |
| Sandbox tier (compose var, hook, notice, verify, VS Code) | **not at all** — W's own files | R1, R2 |
| Venvs | **never** — machine-, arch- and path-specific | rebuilt per repo per machine (R4) |
| Host shell profile, global `~/.claude/CLAUDE.md` | never — per host | R6 |
| Repos that exist only on that machine | invisible from the Mac | found by that machine's own scan (R3) |

## 2. What differs from macolima

| | macolima (Mac) | W on WSL | W on bare Linux |
|---|---|---|---|
| Host OS / arch | macOS arm64 | Ubuntu 24.04 in WSL2, x86_64 | Ubuntu 24.04, x86_64 |
| Container user | `agent` (UID 1000) | root (rootless Docker → host user) | same |
| Workspace | `/Volumes/DataDrive/repo/<p>` | `${HOME}/repo/<p>` in the WSL filesystem | `${HOME}/repo/<p>` |
| Per-profile state | `/Volumes/DataDrive/.claude-colima/profiles/<p>` | `~/.ai-sandbox/profiles/<p>` | same |
| uv cache | named volume | **bind mount** `…/profiles/<p>/cache` → `/root/.cache` | same |
| `UV_LINK_MODE` lives in | compose `environment:` | **Dockerfile `ENV`** | same |
| Baked CPython | 3.12 + 3.13 | 3.12 + 3.13 — same set, so one `.python-version` pin resolves in both sandboxes | same |
| Host interpreter | miniforge / uv-managed macOS | `/usr/bin/python3` 3.12.3 or uv-managed under `~/.local/share/uv` | same |
| VS Code interpreter setting | host attached-container config (`imageConfigs/`) | **Windows** user `settings.json` → `python.defaultInterpreterPath` = `/root/.venv/bin/python` (W README ~L295) | — (no VS Code assumed; check) |
| `.local` gitignore | `*.local` + `*.local.*` (2026-09-11) | W's `.gitignore` has `.local*` (a different thing: names *starting* with `.local`) plus named entries — neither shape of the pair | same repo |

## 3. Linux-host gotchas (the ones the Mac never shows)

1. **A shared venv can look healthy on Linux, so the damage has been silent.**
   The W image is Ubuntu 24.04, and so is the host. Both have `/usr/bin/python3`
   3.12.3 at the same path, so a `.venv` built on either side often *runs* on the
   other. On the Mac the collision is loud; here it goes unnoticed until one side
   switches interpreter (e.g. the container's `/opt/uv/python` 3.13, which the
   host doesn't have) and uv silently recreates the venv for the other side.
2. **`pyvenv.cfg` `home` can't tell you whose a venv is here — use the
   shebangs.** When both sides use `/usr/bin`, `home` is identical. Console
   scripts are not: a container-built venv's scripts start
   `#!/workspace/<repo>/.venv/bin/python`, a host-built one's
   `#!/home/<user>/repo/<p>/<repo>/.venv/bin/python`. Classify with
   `head -1 <venv>/bin/pip` (or any console script) before any retirement.
3. **The two-hosts exception is most likely here.** Windows-native Python and WSL
   are both hosts. If any repo is worked on from `/mnt/c/...` by both, both pick
   `.venv`, and that pair needs per-host names (spec §2). Check for checkouts
   under `/mnt/c` that have a `.venv`, and for Windows-side Python tooling (a
   Windows VS Code interpreter, a Windows `uv`) pointed at them.
4. **W's docs currently tell readers the opposite.** `docs/extending-a-profile.md`
   ~L212 and `.agents/skills/profile-lifecycle.md` ~L219 say not to rebuild "the
   shared `.venv`", because that breaks the container's copy. After activation
   there is no shared `.venv`: it is the host's, and the container's is
   `.venv-sandbox`. Rewrite both. The vendor script's own **absolute**
   `UV_PROJECT_ENVIRONMENT` outside the checkout stays, and an explicit value
   there wins over anything the environment sets. Say that, so nobody "fixes"
   it.
5. **Rootless Docker is what makes host-side deletion work.** Container root maps
   to the host user, so `.venv-sandbox` files are host-owned. On any machine where
   Docker is *rootful*, they would be root-owned, and retiring a venv would need
   `sudo`. Confirm `docker info` says rootless on each machine before planning
   deletions.
6. **The uv cache is a host directory here, not a volume.** It survives
   `docker volume prune` and is easier to inspect, but is **per profile and per
   machine**. The Mac's warm cache helps no Linux machine: plan an egress window
   per profile for the rebuilds, and **re-comment the planning-mode domains
   afterwards, every time**.
7. **VS Code on Windows points at a baseline root venv**, `/root/.venv`, which is
   not a project venv. Decide whether repos in the container should get
   `${workspaceFolder}/.venv-sandbox/bin/python` instead. That is a Windows user
   setting, not a W repo file.
8. **The pre-switch hazard is quieter here** (macolima spec §7.0, found
   2026-09-11). Before a profile exports the variable, a container `uv run` /
   `uv sync` in a repo with a host `.venv` rebuilds it on the Mac. On Linux the
   host's interpreter often exists in the container too (same `/usr/bin`
   path), so uv may instead **sync into the host's venv as it is**: container
   installs, and console scripts whose `/home/…` shebangs don't resolve inside
   the container. Same cure as on the Mac: **switch first**, and don't use a
   repo in a container until that machine's switch is live (R4 order).
9. **Only the paths differ in the deletion hook**: W uses `/root/.cache` where
   macolima uses `/home/agent/.cache` (L724 carve-out, L732 message). The new
   `*/.venv-sandbox/*` entry and its three test cases are identical.

## 3a. What the Mac rollout learned (folded in 2026-09-13, per §0.3)

Everything below was measured while executing stages 2–6 on the Mac (notes.md,
2026-09-11 → 13). None of it is Mac-specific; each item names the R-step it
changes.

1. **Pin `.python-version` before the first build** (R4). Unpinned, the image's
   uv takes the newest baked interpreter, 3.13. Three repos were built on 3.13
   and had to be rebuilt after their pins landed. The rebuild needs no deletion:
   once the pin says 3.12, the next `uv sync` recreates `.venv-sandbox` itself.
2. **`--frozen`, with like-for-like extras** (R4). `uv sync` removes every extra
   you don't name, dev tools included, so a gate run against the new venv is
   only comparable if it names the extras the old venv had. CI sets
   `UV_FROZEN: '1'` at job level, because a plain `uv run` re-locks when
   `pyproject.toml` and `uv.lock` disagree and would quietly test a different
   tree.
3. **The lock is the record; the venv is disposable** (R4, R5). One "start over"
   deleted `uv.lock` along with the venv; it was restored from git before any
   sync ran. Syncing without the lock re-resolves everything against today's
   index through a hand-opened egress window, with no age gate and no audit
   line.
4. **`uv pip` ignores the variable** (R1 docs, R4). It targets a `.venv` in the
   CWD, the host's. So `uv pip …` needs `--python .venv-sandbox`, and any
   `just install` or doc line built on `uv pip install -e .` moves to
   `uv sync --extra …`. Runtime error messages in `src/` that print a
   `uv pip` hint are in scope too.
5. **Container-absolute paths in `pyproject.toml` break the host** (R3, R4).
   One repo carried `[tool.uv] find-links = ["/workspace/dist"]` from a
   hand-copy workflow; `uv lock` on the host failed outright. A relative flat
   index (`../dist`, `format = "flat"`) resolves identically on both sides.
   On W the workspace is `${HOME}/repo/<p>`, so the same leftover fails the
   same way. Add `find-links|/workspace/` to the R3 grep.
6. **The handoff table is a starting point, never the set** (R3, R4). Every
   repo so far had references the table missed: a README the table skipped,
   a `subprocess.run([".venv-linux/bin/alembic", …])` call (→
   `[sys.executable, "-m", "alembic", …]`, no venv name at all), docstrings and
   runtime-printed run hints, notebooks, skill files. The sweep is
   `git grep -n -E '\.venv(-linux|-sandbox)?/bin|\.venv-linux|UV_PROJECT_ENVIRONMENT|os\(\)|find-links'`
   in the repo, and the hand-back re-runs the scan.
7. **`just` paths: `join()`, not `/`** (R4). `root / venv` doubles an absolute
   venv. The working shape is
   `python := join(env_var_or_default("UV_PROJECT_ENVIRONMENT", ".venv"), "bin/python")`,
   which evaluates to `.venv/bin/python` on the host and
   `.venv-sandbox/bin/python` in the container.
8. **Allow rules move to `uv run …`; ask/deny fences list every spelling** (R1,
   R4). Rules cannot interpolate the variable, and matching is literal, so a
   `.venv/bin/python scripts/x.py` allow rule is dead in the container and a
   fence that names only that spelling lets `python3 scripts/x.py` fall
   through to the sandbox's broad allow. Also **argparse prefix matching**:
   `--w`, `--wr`, `--writ` all reach `--write`, and `*--write*` matches none of
   them. Fence on the shortest unambiguous prefix (`*--w*`).
9. **VS Code remembers each workspace's interpreter; the default never
   overrides it** (R2). A workspace that had `.venv-linux` selected kept
   auto-activating it in new terminals after the switch, so `python` and
   `pytest` ran the retired venv while uv, correctly, ignored `VIRTUAL_ENV`
   and targeted `.venv-sandbox`. Once per workspace: `deactivate`, then
   *Python: Select Interpreter* → `.venv-sandbox`. Never `uv sync --active`.
   Repos with only a host `.venv` show "could not resolve `.venv-sandbox`"
   until built; that is expected. For W this is the §3.7 decision, plus a
   re-pick pass per workspace.
10. **`just` shebang recipes fail under a `noexec` `/tmp`** (R1). Fixed on the
    Mac with `JUST_TEMPDIR=/home/agent/.cache` in compose (just ≥1.51 honours
    it; `verify-sandbox.sh` now runs a shebang recipe to prove it). Check
    whether W's `/tmp` is `noexec`; if so the equivalent is
    `JUST_TEMPDIR=/root/.cache`, and the depot AGENTS.md `TMPDIR=` workaround
    becomes unnecessary.
11. **W's managed notice block is where the wrong instruction lives** (R1).
    One nranthony repo's `AGENTS.md` carries W's block verbatim, and inside the
    markers it says `UV_PROJECT_ENVIRONMENT=.venv-linux uv sync`, "`uv sync` is
    denied" and "`.venv/` is irreplaceable" — all false after the switch, and
    echoed into that repo's own ADR, README and a skill. Repo agents are told
    not to edit inside the markers, so **R1's re-sync of the block is what
    fixes those repos**, and it must happen before their handoffs are applied,
    not after. Name those three claims in W's notice rewrite.
    **Superseded 2026-09-14 by work/0011 (ADR-0015):** the blocks are not
    re-synced, they are STRIPPED — the notice now lives only in the agent
    homes. What fixes those repos is 0011's replay, R2, run before the
    handoffs.
12. **Repos have competing drafts of the same change** (R3). Found so far: an
    `os()` selector, an `export UV_PROJECT_ENVIRONMENT=.venv-linux` in a
    CLAUDE.md plus a setup script, and a four-phase in-repo proposal with open
    questions. A handoff that does not name the draft and mark it superseded
    leaves two instructions standing. The scan's `HARDCODED-VENV-LINUX` hit is
    the pointer; read the file it lands in.
13. **Re-run the scan on the day, not from the snapshot** (R3, R4). A profile
    that had "no gate blockers" on 2026-09-11 had one on 09-13 (ikigai's block
    was under `work/` on the first pass, or the repo had changed). The
    done-check is `--fail-on HARDCODED-VENV-LINUX,OS-VENV-SELECT` run *after*
    the handoffs land, and it exits 0 or the stage is not done.
14. **Delivery for profiles without an `inbox/`** (R4). A handoff goes to the
    workspace root, outside every repo: `${HOME}/repo/<p>/inbox/0008/`, seen in
    the container as `/workspace/inbox/0008/`. Confirm the directory is inside
    no git repo before writing.
15. **What T0 established for the image side** (§0.1): the image's uv (0.12.9)
    matched the host's; a relative value resolves against the project root
    from a subdirectory and via `uv run --project` from a parent; the host-slot
    `.venv` was byte-identical after a container sync; `python -m …` works from
    a venv even where `/tmp` is `noexec`, because `bin/python` links into the
    managed interpreter tree. Running that venv's console scripts directly is
    untested.
16. **Egress windows opened by hand leave no record** (R4, §3.6). The Mac's
    sittings opened `[pypi]` by uncommenting lines rather than through the
    egress script, so no sentinel, no age gate, no dependency-gate line; one
    sync pulled ~120 packages through it. Use W's scripted window where it
    exists; either way the close is explicit, and the open state is the
    standing hazard until then.
17. **Hosts confirmed clean on the Mac, with one near-miss**: the shell profile
    exports `UV_PYTHON_INSTALL_DIR`, which is harmless, but it is the kind of
    `UV_*` line R6's grep must read rather than count.
18. **A handoff names the commit it read; the applier re-derives from `HEAD`**
    (R4). ikigai's handoff was written at one commit and applied three days
    later at another: the ADR number it reserved was taken, a rule it did not
    know about had been added, and six table rows named files since archived.
    Nothing broke, because the agent checked, but only because it checked.
19. **The repo agent cannot apply its own policy** (R4). The auto-mode
    classifier blocks an agent editing `.claude/settings.json` in the repo it
    runs in, so step "policy first" waits on the owner. Sequence the handoff so
    the sweep proceeds meanwhile and the gate runs after both.
20. **Catch-all denies over-match on prose** (R1, R4). `Bash(*load_blocks.py*--w*)`
    is airtight for the loader and also denied a `git commit` whose message
    quoted it. Acceptable, but say so in the fence's comment so the next
    denial is not read as a bug. And the scanner's `ASK-GAP` reads a
    flag-scoped fence as a gap for the flagless spellings; decide per repo
    whether that is a real hole (dry runs allowed) or a scanner limit.
21. **One repo, two sandboxes, one notice slot** (R1). A repo worked in both a
    macolima profile and a W profile carries whichever sandbox wrote its
    notice block last, and the other sandbox's sync script writes a different
    marker, so it appends rather than replaces. Decide who owns the block in
    such repos before R1's re-sync, or the two syncs will stack two blocks.
    **Superseded 2026-09-14 by work/0011 (ADR-0015):** nobody owns a block in
    a repo any more; the sync script writes one neutral marker and recognises
    both old ones, and repos carry none. See 0011's replay.

## 4. Steps (for W's own work item)

**Use macolima's rollout order, not just its steps** (plan "Rollout order"),
**switch first, repos after**. Per machine:
1. scan (R3);
2. a one-shell test inside a running container (the plan's B8, with the
   variable prefixed on each command);
3. W's change, one PR: variable, hook, notice, verify, docs and ADR;
4. recreate every profile in one sitting;
5. pull the already-migrated repos and build their `.venv-sandbox`
   (R4, egress window if the cache is cold);
6. retire old venvs last (R5), after a soak.

W's compose file is shared across profiles too, so merging the variable
switches on every profile's next recreate. Recreating them all at once closes
the window. Until R5, the rollback is one compose line and a recreate.

**R1 — W repo, once (mirrors macolima plan B1–B5, B7):**
compose `UV_PROJECT_ENVIRONMENT=.venv-sandbox`. Compose rather than Dockerfile
`ENV`, for the same recreate-not-rebuild reason, even though W's `UV_LINK_MODE`
sits in the Dockerfile; if W prefers `ENV`, record why. Then: the hook carve-out
and tests; the notice's disposable list plus the new "Python environments"
section (the text is sandbox-neutral now — `~`, never `/root` — and comes
verbatim from macolima, see 0011's replay R1). The repo blocks are **not
re-synced, they are stripped** (0011's replay R2, ADR-0015): they say
"anything inside a `.venv` is disposable", which now describes the host's
venv, and the fix is that no repo carries the block at all. The pipeline
agent reported the wrong claim, 2026-09-11. Then a `verify-sandbox.sh` assertion; W's own copy of the ADR,
**numbered ADR-0013 like macolima's**, because the two repos share ADR numbers
(0003–0012 are the same decisions in both); if W has used 0013 since, record the
mapping in both ADR indexes. It cites the agentic-conventions ADR; `AGENTS.md`; the §3.4 doc rewrites; the `.local` pair
in `.gitignore` (and its dockerignore); `just test-offline`, which includes W's
private-names check. W is public too, so the same placeholder discipline
applies.

**R2 — VS Code (Windows host, human):** §3.7 decision; apply it in the Windows
user `settings.json`, then verify in an attached window.

**R3 — Scan, per machine (macolima plan A1, run there; re-run on activation day, §3a.13):** same checks, over
`${HOME}/repo/<p>/` for each profile under `~/.ai-sandbox/profiles/`, plus any
checkout under `/mnt/c` (§3.3). Classify venvs by shebang (§3.2), not `home`
alone. Output is **local only**, e.g. `scan.local.md` in W's work item, and the
check that it is ignored happens *after* R1 lands the `.local` pair; until then
write it outside the repo. Repos found only on that machine get their handoffs
from that machine, citing the agentic-conventions ADR.

**R4 — Activate, then pull (macolima plan C):** human `recreate` of every
profile → verify `echo $UV_PROJECT_ENVIRONMENT` prints `.venv-sandbox` inside
each → **then** pull the migrated repos (their edits assume the variable) →
pin `.python-version` (§3a.1) → `uv sync --frozen` with like-for-like extras (§3a.2) per active repo, in an egress window where the cache is cold
→ each repo's gate → re-comment the planning-mode domains. A repo that exists
only on this machine gets its handoff from this machine's scan, in the same
final form.

**R5 — Retire venvs (human, per machine; macolima plan Phase F):** only after
that machine's profiles have run clean for a while. Covers container-built venvs
in `.venv` slots and any `.venv-linux`, classified by shebang, never deleted by
glob.

**R6 — Hosts (human):** on each WSL and Ubuntu host: nothing exports
`UV_PROJECT_ENVIRONMENT` (`~/.bashrc`, `~/.zshrc`, `~/.profile`, any direnv
`.envrc`; W's `host_setup/ohmyzsh-host-setup.sh` exports no `UV_*` today, so
re-check after any re-run). Apply the global `~/.claude/CLAUDE.md` text from
macolima plan D2 to that host's copy, which is a separate file per host.

## 5. What to send back to macolima (ferried)

Per machine, into macolima `work/0008-venv-per-environment/notes.md`:
- the machine label (WSL / bare Linux); whether Docker is rootless; W's commit;
- the profiles activated, and the repos whose venvs were rebuilt;
- counts per scan flag, **names only for repos that needed action** (the full
  scan stays on that machine);
- any two-hosts pair found (§3.3) and what was decided;
- anything in spec/plan that turned out wrong on Linux, so the rule's ADR can
  be corrected.

macolima 0008 exits only when every machine has reported (spec §8).
