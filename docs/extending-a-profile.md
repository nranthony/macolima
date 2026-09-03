# Extending a profile — where a capability has to live

How a tool, skill, plugin, library, credential or API reaches an agent inside a
profile. This is the *deployment* question, distinct from the *permission*
question ([permissions-model.md](permissions-model.md)) and the *egress*
question ([squid-internals.md](squid-internals.md)): those say whether the agent
may use a thing; this says how the bytes get there and what erases them.

Read this before designing anything whose install story is "run the vendor's
one-liner". Most of those assume a normal host: a writable `$HOME`, an open
network, and a per-user install prefix. This sandbox breaks all three in
specific, discoverable ways, and the failure mode is usually **silent
disappearance on recreate** rather than an error.

## The model in one screen

Three places bytes can live, two gates they must pass.

| Layer | Path | Shared by | Erased by |
|---|---|---|---|
| **Image** | anything not listed below | every profile | nothing (a rebuild replaces it) |
| **Container writable layer** | `/usr`, `/opt`, `/etc`, and any `/home/agent/*` not bind-mounted | one container | `docker rm` — i.e. `recreate`, `rebuild`, `down`+`up` |
| **tmpfs** | `/tmp`, `/run`, `/home/agent/.local`, `/home/agent/.npm-global` | one container | container *stop*; also `noexec` |
| **Per-profile state** | `/Volumes/DataDrive/.claude-colima/profiles/<p>/…` → `/home/agent/.claude`, `.config`, `.gemini`, `.claude.json` | one profile | only `profile.sh <p> wipe` |
| **Named volume** | `/home/agent/.cache`, `/home/agent/.vscode-server`, DB data dirs | one profile | `db-reset`, `wipe --all-volumes` |
| **Workspace** | `/Volumes/DataDrive/repo/<p>/` → `/workspace` | one profile | nothing (it's your git tree) |

`.cache` and `.vscode-server` are named volumes **by necessity**, not
preference — see [virtiofs-gotchas.md](virtiofs-gotchas.md). Do not convert them
to bind mounts.

The two gates:

- **Egress** — the Squid allowlist ([ADR-0003](adr/0003-strict-egress-default.md)).
  Registries are closed by default, and DNS is sinkholed, so a host not in the
  allowlist does not resolve, let alone connect. A dependency enters through a
  `scripts/with-egress.sh` window.
- **Agent tool policy** — `claude-home/settings.json` plus the
  `deny-destructive` PreToolUse hook, and the `agy` twin
  ([ADR-0006](adr/0006-antigravity-is-two-layer-like-claude.md)). This binds the
  **agents' Bash tools only**. A human's attached shell (`profile.sh <p>
  attach`) is unrestricted by it — but still subject to egress. **That asymmetry
  is the deployment lever:** installs are a human step in an attached shell or a
  `with-egress.sh` window, never an agent step.

**The rule that catches people:** a bind mount *shadows* whatever the image put
at that path. `COPY`ing a skill to `/home/agent/.claude/skills/` in the
`Dockerfile` produces a file no container will ever see, with no error at build
or run time.

## Decision table — where does it go?

| You want to add | Layer | Mechanism | Survives `recreate`? |
|---|---|---|---|
| A system package / CLI for every profile | image | `Dockerfile` + `profile.sh build` | yes |
| A CLI for one profile, one session | writable layer | attached shell inside a `with-egress.sh` window | **no** — redo, or promote to the image |
| An agent skill | per-profile | `sandbox_templates/skills/<name>/` → converged to `claude-home/skills/` | yes |
| A Claude Code plugin / marketplace | per-profile | `claude-home/plugins/` | yes |
| Agent tool policy (allow/deny/hooks) | per-profile | `sandbox_templates/claude/` **and** `sandbox_templates/antigravity/` → converged | yes |
| Standing instructions for every repo in a profile | per-profile | `claude-home/CLAUDE.md` via `scripts/sync-agent-notice.sh` | yes |
| Standing instructions for one repo | workspace | that repo's `AGENTS.md` / `.claude/` | yes |
| A Python dependency of a project | workspace | the project's `.venv` + manifest, in a `with-egress.sh` window | yes (`.venv` is in the bind mount) |
| A Python lib not on PyPI | workspace | `/Volumes/DataDrive/repo/<p>/dist/*.whl` — [local-wheels.md](local-wheels.md) | yes |
| A private CLI the whole fleet needs | image | a vendored wheel — [ADR-0004](adr/0004-python-wheels-only.md) | yes |
| An API key | per-profile | `profiles/<p>/secrets.env` | yes, but read at container **create** only |
| Reachability of a new host | egress | a tagged `[name]` block in `proxy/allowed_domains.txt` | yes (repo-level, all profiles) |
| A database | sibling container | `COMPOSE_PROFILES=db-postgres profile.sh <p> up` | data in a named volume |
| A published port | compose overlay | `docker-compose.<profile>.expose-dev.yml` | yes |
| An MCP server | per-profile | `claude.json` config + an allowlist entry for its host | yes |

## Seam notes — the non-obvious parts

### Image layer (`Dockerfile`)

One image, all profiles: adding here is a fleet-wide change and costs a build.
`build` takes **no profile argument**.

- **Install order is load-bearing**, and locked by
  `scripts/dockerfile-order.test.sh`. A quarantine written above a `@latest` CLI
  install makes that install intermittently unresolvable, because the
  `min-release-age` gate applies at *build* time too.
- **Install prefixes are deliberate, not incidental.** `/home/agent/.local` and
  `/home/agent/.npm-global` are `noexec` tmpfs at runtime, recreated empty at
  container start, and `.local/bin` is **first on `PATH`**. Anything installed
  there is both wiped and unrunnable. The image therefore pins
  `UV_TOOL_DIR=/opt/uv/tools` and `UV_TOOL_BIN_DIR=/usr/local/bin`. A vendor
  installer defaulting to `~/.local/bin` will report success and then fail with
  `EACCES` on first run.
- **Verify as `agent`, not only as root.** A build-time `--version` run as root
  proves the wrong thing here: root is not who runs it.

`profile.sh build --refresh-ai` rebuilds only the AI-CLI tail layer (~21s
against ~100s) — right for a CLI version bump, wrong for new tooling.

### Per-profile agent state

Both **skills** ([ADR-0005](adr/0005-skill-templates-are-source-of-truth.md))
and **policy** ([ADR-0007](adr/0007-policy-templates-are-source-of-truth-for-every-agent.md))
converge from `sandbox_templates/` on every `up`. Consequences:

- a new or edited template lands on the next `up`; something removed from the
  template is pruned from every profile;
- a locally edited copy is replaced **with a WARN** — reported, never silent;
- **no backups are kept** inside `~/.claude/skills/`, because a `.bak` sibling
  is a second live copy and for a plugin-shaped skill it wins the name race;
- an in-session permission grant does **not** survive a converge — what it
  displaced is captured to `claude-home/settings.discarded.json`;
- `scripts/profile.sh <p> converge` does all of it without touching the
  container. **Restart `claude` (and `agy`) inside the container** to pick it up.

Intentional per-profile variation therefore has a different home: a per-repo
`.claude/` in the workspace, or the template itself. Personal scope is not a
customisation surface, and a repo-local file can only ever **tighten**
permissions.

`sandbox_templates/skills/` mixes sandbox-native skills with copies vendored
from the depot channel — [`UPSTREAM.md`](../sandbox_templates/skills/UPSTREAM.md)
says which. Editing a vendored one here is reverted silently by the next
`just vendor-tools`.

### Secrets and env

`secrets.env` and `db.env` are injected as optional `env_file`s — **read at
container create only.** Editing either and running `up` changes nothing for a
running agent; `profile.sh <p> recreate` is required. This is the single most
common cause of "the key is set but reads as unset".

A key is also useless without its host in the allowlist, and variable **names**
are dictated by the consuming code, not by taste — a plausible synonym reads as
unset and fails as "no key".

### Egress additions

Prefer a `scripts/with-egress.sh --with <tag>` window over a permanent
allowlist entry: it opens the tagged block, hot-reloads Squid, runs one command,
restores the file verbatim, and writes an audit record. Permanent entries are
pinned subdomains with a one-line justification above them.

Grepping the allowlist inside the container tells you what it **says**, not what
Squid **enforces** — an edit needs `squid -k reconfigure` before it is real.

### Ephemeral by design

`scripts/run-ephemeral.sh <p>` gives a `--rm` container on the profile's network
with the same hardening — right for a one-shot tool trial, wrong for anything
you want tomorrow.

## Worked patterns

**A new agent capability (skill).** Author under
`sandbox_templates/skills/<name>/SKILL.md` → `profile.sh <p> converge` →
restart `claude`. Never `COPY` it into the image (the bind mount shadows it). A
directory carrying `.claude-plugin/plugin.json` goes through the same path and
loads as `<name>@skills-dir`.

**A new external service the agent must call.** Allowlist its pinned host →
reload the proxy → add the key to `secrets.env` under the exact variable name
its consumer reads → **`recreate`** → probe from inside the container before
wiring any logic. Four steps; skipping the recreate is the usual failure.

**A private CLI the whole fleet needs.** The pattern `myclickup` establishes,
and the one to copy — see [ADR-0004](adr/0004-python-wheels-only.md) for why
each half is load-bearing. Two things bite in practice:

- **Zero runtime dependencies is an invariant, not a starting point.** The agent
  cannot repair a broken dependency; every installer is denied to it.
- If the tool's source repo is bind-mounted into a profile, its `.venv` may have
  been created **in-container**, where console scripts carry an absolute
  `#!/workspace/...` shebang. A host-side build then fails with "Failed to spawn:
  pytest", which reads as a missing dev dependency rather than a path mismatch.
  Point `UV_PROJECT_ENVIRONMENT` outside the checkout.

**A vendored artifact must not widen the sandbox.** The channel manifest ships a
*proposed* permission set. `just check-permissions` reports it against the
template and never edits anything; adopting any line is a human decision, goes
in the **template**, and needs its `command()` twin for `agy` or the offline
suite fails.

**A per-project toolchain (node/python/rust versions).** Belongs in the project
in `/workspace`, pinned by its own manifest and lockfile. The image is the
floor, not the toolchain manager.

## Verify what you added

```bash
scripts/profile.sh <p> verify        # tier 1 tripwire — mounts, gates, identity
scripts/profile.sh <p> audit         # tier 2 structured probes
scripts/profile.sh <p> deps          # dependency posture
just test-offline                    # no docker, no network, no profile state
```

Security-sensitive files (`Dockerfile`, compose, `seccomp.json`, `proxy/`,
`sandbox_templates/claude/`, `sandbox_templates/antigravity/`) carry the
verification protocol in [`AGENTS.md`](../AGENTS.md) — state the security impact
in the commit and run at least tier 1.

## Portable brief — for an agent outside this repo

Self-contained; paste it into another repo's planning context when that repo's
work has to run inside a profile. It assumes no access to this tree.

> **Deploying into `macolima` — what you can assume**
>
> 1. **Three durability classes.** The repo tree (`/workspace`) and the agent
>    home (`/home/agent/.claude`, `.config`, `.cache`) are host bind mounts and
>    persist. Everything else — `/usr`, `/opt`, a globally installed CLI — lives
>    in the container layer and is destroyed on the next recreate. `/tmp`,
>    `/home/agent/.local` and `/home/agent/.npm-global` are additionally
>    `noexec` tmpfs: things "install" there and then cannot run. **Design so the
>    durable artifact is a file in a git-tracked tree or the agent home, never
>    an installed binary.**
> 2. **Network is allowlist-only and registries are closed.** No arbitrary HTTP;
>    no `pip`/`npm`/`cargo` install. Anything needing a fetch at install time is
>    a human step, so **prefer designs where material arrives as files over
>    designs that install at first use.**
> 3. **Remote git is denied to the agent.** Commit locally; a human pushes. Any
>    scheme whose first step is "push a repo" has a human in it.
> 4. **The agent home is per-profile and pre-seedable.** Skills at
>    `~/.claude/skills/<name>/SKILL.md`, plugins at `~/.claude/plugins/`,
>    standing instructions at `~/.claude/CLAUDE.md` — all inside the persistent
>    mount and placeable from the host **before** the container starts. That is
>    the supported way into a closed-egress profile.
> 5. **The agent is not root** (UID 1000, `cap_drop: ALL`, `no_new_privs`).
>    Anything assuming root inside the container is wrong here — which is the
>    opposite of the sibling `windows-ai-sandbox`, so do not carry an assumption
>    across.
> 6. **There is no GPU**, and that is the correct answer rather than a
>    misconfiguration: it is a Colima VM on macOS with no device passthrough.
> 7. **Ask, don't route around.** A permission denial or a connection error on
>    an unlisted host is the boundary working. Surface it as a human step with
>    the exact host or command needed; retries, shell escapes and alternate
>    fetch paths are separately blocked and logged.

## See also

- [README.md](../README.md) — onboarding and the lifecycle commands
- [AGENTS.md](../AGENTS.md) — invariants and the editing checklist
- [permissions-model.md](permissions-model.md) — what the agent may do once the bytes are there
- [local-wheels.md](local-wheels.md), [web-read-broker.md](web-read-broker.md)
- [virtiofs-gotchas.md](virtiofs-gotchas.md) — why two mounts are named volumes
- [ADR-0003](adr/0003-strict-egress-default.md), [ADR-0004](adr/0004-python-wheels-only.md), [ADR-0005](adr/0005-skill-templates-are-source-of-truth.md)
