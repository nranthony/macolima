# 0008 — One venv per environment: `.venv-sandbox` in every sandbox, `.venv` on every host

**State:** spec + plan, not started. **Opened:** 2026-09-11.
**Plan:** [plan.md](plan.md). **Depot side:** [handoff-depot.md](handoff-depot.md).
**WSL / bare-Linux machines:** [replay-other-hosts.md](replay-other-hosts.md).

## 1. The problem

A checkout under `/Volumes/DataDrive/repo/<profile>/` is seen by two Python
environments at once: the host (macOS here; WSL or raw Ubuntu for the sibling)
and the profile's container. Both default to `<repo>/.venv`. A venv is not
portable — `.venv/bin/python` is a symlink to one interpreter on one machine — so
whichever side built `.venv` last owns it, and the other side finds it broken.

The failure is worse than "broken". **When uv finds a project environment whose
interpreter is unusable, it deletes and recreates it.** So a `uv run` in the
container silently replaces the host's working venv with a Linux one, and the
next `uv run` on the host does the reverse. That is what happened in
`depot/myclickup` (its `.venv` now points at the container's `/usr/bin` 3.12.3)
and why `depot/paperbridge`'s `.venv` (miniforge, macOS) is dead inside the
container.

Repos have been working around this one at a time, inconsistently:
`therapod/pipeline` picks `.venv` vs `.venv-linux` by `os()` in
`just/vars.just`; `therapod/wearable_data_testing` hard-codes
`.venv-linux/bin/python` in scripts and in its `.claude/settings.json` allow
rules; this repo's own `docs/local-wheels.md` and `docs/profile-seed-database.md`
tell the agent to use `.venv-linux`. Selecting by OS is exactly wrong for the
sibling: `windows-ai-sandbox` mounts `${HOME}/repo/${PROFILE}` from **inside
WSL**, so its host and its container are both Linux and both pick `.venv-linux`.

## 2. The rule (owner decision, 2026-09-11)

**The environment names the venv; repos never choose it.**

| Where it runs | `UV_PROJECT_ENVIRONMENT` | Venv |
|---|---|---|
| Any sandbox container — macolima (Colima, arm64) or windows-ai-sandbox (Docker on WSL, x86_64) | `.venv-sandbox`, exported by the sandbox's compose `environment:` | `<repo>/.venv-sandbox` |
| Any host — macOS, WSL, raw Ubuntu | **unset** | `<repo>/.venv` (uv's default) |

Consequences that make this the rule rather than a naming preference:

- Every `uv run` / `uv sync` / `uv venv` reads the variable, and a relative value
  resolves against the **project root**, not the CWD — so one value serves every
  repo, including `uv run --project <member>` from `depot/` (verified §4).
- The sandbox's uv can then never see, let alone recreate, the host's `.venv`,
  and the host's uv never sees `.venv-sandbox`. The recreate-on-mismatch
  behaviour stops being destructive.
- Hosts need no configuration. The only host obligation is **not** to export
  `UV_PROJECT_ENVIRONMENT` globally.

**The one exception:** two *hosts* sharing one checkout — Windows-native Python
and WSL both working in `/mnt/c/...`, or a folder synced between two machines.
Both are hosts, so both pick `.venv`. Only that pair needs per-host names
(`.venv-mac` / `.venv-wsl` / `.venv-linux`, set in that host's shell profile). No
such pair is known today; the rule's ADR records the exception so it is not
rediscovered.

## 3. Decisions and non-goals

- **No CPU-architecture suffix.** Colima is arm64, the sibling is x86_64, but each
  sandbox shares a checkout only with its own host; the two machines hold separate
  clones. A wrong-arch venv would be recreated by uv, not lost — noise, not damage.
- **Compose `environment:`, not Dockerfile `ENV`.** Same tier as `UV_LINK_MODE`,
  runtime-only, and a change costs a `recreate`, not a rebuild.
- **No `UV_PYTHON` in the image.** It is equivalent to `--python`, so it would
  override every repo's `.python-version`. Python version is pinned per repo with
  a tracked `.python-version`. Without a pin, uv in the container picks the newest
  baked managed interpreter (3.13) while the host may pick 3.12 — the two sides
  of one repo silently run different minors. The image bakes **only 3.12 and
  3.13**, and `python-downloads` needs closed egress at runtime, so a pin to any
  other version fails offline.
- **Hosts keep plain `.venv`.** Every existing macOS `.venv` stays valid; no host
  rebuilds.
- **Never delete by pattern.** A `.venv` may be a live host venv or a sandbox
  leftover; only `pyvenv.cfg`'s `home` tells them apart (§5). Deleting any venv
  directory is `rm -rf`, which is a human step here regardless (ADR-0008).

## 4. Verified facts (2026-09-11, host uv 0.12.9, scratch repo)

| Claim | Result |
|---|---|
| `uv venv` honours `UV_PROJECT_ENVIRONMENT` | yes — created `.venv-sandbox` |
| Relative value resolves against project root | yes — `uv sync` from `proj/sub/` and `uv run --project proj` from the parent both landed in `proj/.venv-sandbox` |
| An un-gitignored uv venv dirties `git status` | **no** — uv writes `.gitignore` = `*` inside every venv it creates (confirmed in all six existing venvs inventoried). `.gitignore` listing only `.venv/` left `git status --porcelain` clean |
| Same for a stdlib venv | **3.12: dirty** (`?? .venv-std312/`, no self-ignore). 3.13+ writes the self-ignore too |

So `.venv*/` in each repo's `.gitignore` is hygiene for stdlib/older-tool venvs,
**not** an ordering prerequisite. The depot agent's "fix the gitignores first or
the first publish is refused" does not hold for uv-built venvs.

**Still to verify in the container** (image uv, not host uv): the same three
rows, plan step B8.

## 5. Inventory snapshot (2026-09-11, host-side find, depth ≤ 4)

A snapshot to size the work, **superseded by the scan in plan step A1**.
Classified by `pyvenv.cfg` `home`:

| Venv | Built by | Status under the rule |
|---|---|---|
| `nranthony/depot/myclickup/.venv` | **sandbox** (`/usr/bin`, 3.12.3) | leftover in the host's slot — rebuild as `.venv-sandbox`, human deletes |
| `therapod/citation_tools/.venv` | **sandbox** (`/opt/uv/python/cpython-3.12-linux-aarch64-gnu`) | same |
| `therapod/pipeline/.venv-linux` | sandbox (`/usr/bin`) | rename → `.venv-sandbox` (rebuild) |
| `therapod/wearable_data_testing/.venv-linux` | sandbox (`/usr/bin`) | same |
| `jeremy_dahl/jeremy_dahl_analytics/.venv-linux` | sandbox (`/usr/bin`) | same |
| `nranthony/depot/paperbridge/.venv` | host (miniforge 3.12.12) | valid, stays |
| ~16 other `.venv` across nranthony / therapod / fluidmomenta / jeremy_dahl | host (miniforge / uv-managed macOS / Homebrew) | valid, stay |

Known **hard-coded** consumers (each needs a repo-side change before its
profile activates the variable — plan §C ordering):

| Repo | What pins a venv name |
|---|---|
| `therapod/pipeline` | `just/vars.just` `os()` switch; `.github/workflows/ci.yml` matrix `venv:`; `.claude/settings.json` `.venv-linux/bin/{alembic,ruff}` rules; `tests/conftest.py`; many docs |
| `therapod/wearable_data_testing` | `scripts/preflight.sh`, `scripts/preseed_sdk_cache.sh` (`PY=.venv-linux/bin/python`); five `.claude/settings.json` allow rules; `macolima_wearables_setup.md` |
| `jeremy_dahl/jeremy_dahl_analytics` | `docs/IN_TRANSIT.md`, run lines in `work/0002/…`, `file_parse/attachments/README.md` |
| `nranthony/depot/*` | prose only (README / downstream.md / ARCHITECTURE); paperbridge's gitignored `settings.local.json` → `.venv/bin/pytest` |
| **this repo** | `docs/local-wheels.md`, `docs/profile-seed-database.md` (`.venv-linux`); `docs/extending-a-profile.md` row; `deny-destructive.sh` carve-out; `agent-notice.md` disposable list |

## 6. Who owns what

| Tier | Owns | Carried by |
|---|---|---|
| **macolima (this item)** | compose variable, deletion-hook carve-out, agent notice, `verify-sandbox.sh` tripwire, docs, ADR, VS Code attached-container setting, the all-repo scan, activation per profile | plan.md |
| **agentic-conventions** (depot member) | the repo-side rule for every repo: ADR, `templates/.gitignore`, reference paragraph, apply-conventions audit check | [handoff-depot.md](handoff-depot.md) |
| **depot members** (myclickup, paperbridge) | their own gitignore / `.python-version` / prose | same handoff |
| **other profiles' repos** (therapod ×3, jeremy_dahl, anything the scan finds) | their own selectors, scripts, allow rules, CI | one final-form handoff per repo, applied **after** its profile has switched (plan Phase E; order revised 2026-09-11 so repo docs never carry transitional text). The three therapod repos the scan flagged have theirs; the rest follow the conventions release |
| **windows-ai-sandbox** | the same variable, hook, notice, VS Code setting on its side | human-ferried (plan D3) |
| **the owner, host-side** | host shell profiles, global `~/.claude/CLAUDE.md`, VS Code config file, deleting old venvs | plan §D, C3 |

## 7. Gotchas (keep in view while executing)

0. **Before the switch, `uv run` / `uv sync` in a container are the destructive
   commands** in any repo whose `.venv` is the host's. uv deletes and rebuilds
   it, and the sandbox policy allows `uv run:*` globally. The switch is the
   cure. The rollout is therefore ordered **switch first, repos after**, so no
   repo edit ever has to work in both states. The owner is holding repo use
   until the rollout completes (2026-09-11), which closes the window from the
   usage side. The one transitional instruction left lives in the handoffs,
   never in repo docs: a precondition check (`echo $UV_PROJECT_ENVIRONMENT`
   must print `.venv-sandbox`) and the depot warning about publishing paperbridge.
1. **Superseded 2026-09-11 — was "repos first, compose second".** The worry was
   a repo pinned to `.venv-linux` silently running a stale venv after the switch.
   With repo use on hold and the scan as the "finished" check
   (`--fail-on HARDCODED-VENV-LINUX,OS-VENV-SELECT`), that window has no users,
   and any miss shows up in the scan.
2. **Only uv's *project* commands read the variable** (`run`, `sync`, `venv`).
   **`uv pip` does not:** measured 2026-09-11, it picks a `.venv` in the CWD,
   which in the container is the host's, so it needs `--python .venv-sandbox`.
   VS Code, `python -m venv`, justfile paths, shell scripts and
   `.claude/settings.json` allow rules don't read it either. Allow rules
   cannot interpolate env vars at all: they move to `uv run …` forms or get
   rewritten for the new name.
3. **Rebuilding a venv needs packages.** The uv cache (named volume, per profile)
   held only myclickup's dev set on 2026-09-11; paperbridge failed offline at
   ruff 0.15.6. A rebuild is either offline-from-cache or a `with-egress.sh`
   window. **Re-comment the planning-mode domains and reconfigure Squid when the
   window closes** — an open window left behind is the standing hazard here.
4. **The hook carve-out must name the directories exactly.** The splitter appends
   `/` to every target, so `*/.venv*/*` would also carve out a *file* named
   `.venvrc` or `.venv.toml`. List `*/.venv/*|*/.venv-sandbox/*`.
5. **`verify-sandbox.sh` already skips `*/.venv-*/*`** in its Gate-3 project
   scan (line ~568) — no change needed there, only a new env assertion.
6. **The sibling runs as root with a baseline `/root/.venv`** that its VS Code
   default interpreter points at, and its host vendor script sets an absolute
   `UV_PROJECT_ENVIRONMENT` of its own (myclickup
   `work/archive/0016/handoff-sandbox-review-reply.md` ~L231). An explicit value
   wins over the compose default, so they don't conflict — but the ferried note
   must mention both.
7. **The owner's global `~/.claude/CLAUDE.md` says "If .venv exists, use it."**
   Correct on a host once this lands; wrong today in the two repos whose `.venv`
   is a sandbox leftover (§5). It does not load inside the sandbox (claude-home is
   per profile), so the sandbox side is covered by the agent notice.

## 8. Exit criteria

- Every macolima profile recreated with `UV_PROJECT_ENVIRONMENT=.venv-sandbox`,
  `just verify <p>` green including the new assertion.
- Every repo the A1 scan flags has either migrated or has an open handoff that
  names it.
- No sandbox-built venv left in a `.venv` slot; no `.venv-linux` left on disk.
- agentic-conventions release carrying the rule is published and re-vendored.
- [replay-other-hosts.md](replay-other-hosts.md) ferried to windows-ai-sandbox,
  and every WSL / bare-Linux machine has reported back (its §5).
