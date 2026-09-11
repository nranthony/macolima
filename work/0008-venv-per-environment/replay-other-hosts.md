# 0008 — replaying the venv rule on the WSL and bare-Linux hosts

**State:** waiting on macolima. **Written:** 2026-09-11.
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
section (root paths); a `verify-sandbox.sh` assertion; W's own copy of the ADR,
**numbered ADR-0013 like macolima's**, because the two repos share ADR numbers
(0003–0012 are the same decisions in both); if W has used 0013 since, record the
mapping in both ADR indexes. It cites the agentic-conventions ADR; `AGENTS.md`; the §3.4 doc rewrites; the `.local` pair
in `.gitignore` (and its dockerignore); `just test-offline`, which includes W's
private-names check. W is public too, so the same placeholder discipline
applies.

**R2 — VS Code (Windows host, human):** §3.7 decision; apply it in the Windows
user `settings.json`, then verify in an attached window.

**R3 — Scan, per machine (macolima plan A1, run there):** same checks, over
`${HOME}/repo/<p>/` for each profile under `~/.ai-sandbox/profiles/`, plus any
checkout under `/mnt/c` (§3.3). Classify venvs by shebang (§3.2), not `home`
alone. Output is **local only**, e.g. `scan.local.md` in W's work item, and the
check that it is ignored happens *after* R1 lands the `.local` pair; until then
write it outside the repo. Repos found only on that machine get their handoffs
from that machine, citing the agentic-conventions ADR.

**R4 — Activate, then pull (macolima plan C):** human `recreate` of every
profile → verify `echo $UV_PROJECT_ENVIRONMENT` prints `.venv-sandbox` inside
each → **then** pull the migrated repos (their edits assume the variable) →
`uv sync --frozen` per active repo, in an egress window where the cache is cold
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
