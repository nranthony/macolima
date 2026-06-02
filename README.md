<p align="center">
  <img src="images/macolima_silly_logo.png" alt="macolima" width="520">
</p>

# macolima

Hardened multi-profile sandbox for running Claude Code in auto mode on macOS. Colima-based Linux VM on an external drive. Each profile is a fully isolated stack (own containers, own networks, own persistent state) built from a single shared image.

**Target host:** Mac (Apple Silicon), external drive at `/Volumes/DataDrive`.

## Quickstart (TL;DR)

First time on a fresh machine, or coming back up after `colima delete` / a full reset:

```bash
scripts/bootstrap.sh                                            # 1. host setup (brew, dirs, ~/.zshrc env)
source ~/.zshrc                                                 #    so $COLIMA_HOME / PATH are live
scripts/colima-up.sh                                            # 2. start Colima VM with the right flags
PROFILE=_build docker compose build claude-agent                # 3. build the shared image
mkdir -p /Volumes/DataDrive/repo/<profile>                      # 4. profile workspace must exist before setup
scripts/setup.sh <profile> --name "Your Name" --email "you@x"   # 5. up + claude/gh login + git identity
scripts/profile.sh <profile> attach                             # 6. zsh inside the agent container
```

`<profile>` is whatever you call this slice — `work`, `personal`, `nranthony`, etc. Default git auth is GitHub; pass `--gitlab` or `--both` to change. The base image digest pin in `Dockerfile` is fine to leave as-is for first-time setup; refresh it once-a-month per the "Updating" section.

For a one-line restart-existing-profile after compose / squid / seccomp changes:

```bash
scripts/profile.sh <profile> recreate
```

Add `COMPOSE_PROFILES=db-postgres` (or `db-mongo` / `db-all`) to also recreate DB siblings. **If the compose change touches the `sandbox-internal` network's IPAM** (subnet, `ipv4_address`, `dns:`, `extra_hosts`), recreate is not enough — see the IPAM callout in "Updating" below for the `down`+`rebuild` recipe.

## Common operations

Goal-first cheat sheet for the day-to-day. `<p>` is the profile name. The
detailed, per-script tables are further down (`setup.sh` flags and `profile.sh`
commands under "Using profiles").

| Goal | Command |
|---|---|
| **Start the Colima VM after a host reboot** (idempotent) | `scripts/start.sh` (or `just colima-up`) |
| Start the VM **and** a profile in one go | `scripts/start.sh <p>` (or `just colima-up <p>`) |
| Stop all profiles + the VM (reclaims RAM) | `scripts/stop.sh` (or `just colima-down`) |
| **Start / bring back the stack** (starts whatever's down) | `scripts/profile.sh <p> up` |
| Restart already-running containers (no recreate) | `scripts/setup.sh <p> --restart` |
| Apply a compose / seccomp / squid / mount change | `scripts/profile.sh <p> recreate` |
| Apply a **Dockerfile** change (rebuild image + recreate) | `scripts/profile.sh <p> rebuild` |
| Stop + remove containers (state preserved) | `scripts/profile.sh <p> down` |
| Shell into the agent container | `scripts/profile.sh <p> attach` |
| See profile container state (running + stopped) | `scripts/profile.sh <p> status` |
| List all profiles + up/down state | `scripts/profile.sh list` |
| Verify auth / mounts / git identity | `scripts/setup.sh <p> --verify` |
| Blank-slate a profile but **keep** auth | `scripts/profile.sh <p> wipe` |
| Rebuild the shared image only | `scripts/profile.sh build` |

> Stack partly down (e.g. only `postgres` survived a Colima restart)? Use `up`,
> not `--restart` — `restart` only bounces containers that already exist, so it
> won't recreate the missing agent/proxy.

### Optional: `just` front door

A root `justfile` provides a discoverable, terser alias for the same commands —
it is a **thin pass-through to `scripts/profile.sh` / `scripts/setup.sh`**, not a
reimplementation (the scripts stay canonical). Run `just` (or `just --list`) to
see every recipe. The profile is the first arg, mirroring the scripts:

```bash
just up <p>              # = scripts/profile.sh <p> up
just attach <p>          # = scripts/profile.sh <p> attach
just recreate <p>        # = scripts/profile.sh <p> recreate
just rebuild <p>         # = scripts/profile.sh <p> rebuild
just verify <p>          # = scripts/setup.sh   <p> --verify
just setup <p> --name "Your Name" --email you@x   # = scripts/setup.sh <p> ...
just list                # = scripts/profile.sh list
```

The `colima-*` recipes are the exception to the profile-first rule — they take
no profile (Colima is shared across all profiles) and front the VM scripts:

```bash
just colima-up           # = scripts/start.sh   (start the VM after a host reboot; idempotent)
just colima-up <p>       # = scripts/start.sh <p>  (also brings profile <p> up)
just colima-down         # = scripts/stop.sh    (stop all profiles, then the VM)
just colima-status       # = colima status
```

> `just colima-up` is for everyday restarts (the VM's `--cpu`/mount flags are
> already persisted in `colima.yaml`). For **first-time** setup or after a
> `colima delete`, use `scripts/colima-up.sh` instead — only it re-bakes those
> flags. See "Updating" / troubleshooting below.

Requires `just` on the host (`brew install just`). Skip it entirely if you
prefer the scripts — the recipes add nothing the scripts don't already do.

## Concept: profiles

A *profile* is a named sandbox instance — e.g. `work`, `personal`, `sideproject`. Each profile:

- Has its own agent container (`claude-agent-<profile>`) and proxy (`egress-proxy-<profile>`).
- Runs on its own isolated Docker networks (no cross-profile traffic).
- Has its own Claude auth, session history, MCP config, git identity, and gh/glab tokens.
- Mounts one subfolder of `/Volumes/DataDrive/repo/<profile>/` as `/workspace`. By convention, drop locally-built wheels for that profile into `/Volumes/DataDrive/repo/<profile>/dist/` — they appear at `/workspace/dist/` inside the container for `uv pip install`. See `CLAUDE.md` → "Per-profile `dist/` for local wheels".
- Can run concurrently with other profiles, or be brought up/down independently.

All profiles share the same `macolima:latest` image. Rebuild once, all profiles benefit.

## Layout

```
macolima/
├── Dockerfile                     # hardened image: non-root agent, zsh+p10k, gh, glab
├── docker-compose.yml             # parameterized by $PROFILE
├── seccomp.json                   # syscall filter
├── config/
│   ├── claude-settings.json       # template seeded into each profile's ~/.claude/settings.json
│   ├── zshrc-snippet.sh           # COLIMA_HOME / LIMA_HOME vars for host ~/.zshrc
│   ├── .zshrc                     # in-container zsh config
│   └── .p10k.zsh                  # powerlevel10k prompt
├── proxy/
│   ├── squid.conf
│   └── allowed_domains.txt        # outbound allowlist (shared across profiles)
├── scripts/
│   ├── bootstrap.sh               # one-time host setup
│   ├── colima-up.sh               # first-time / post-delete colima start (bakes flags)
│   ├── start.sh                   # everyday VM start after a reboot (+ optional profiles)
│   ├── stop.sh                    # stop all profiles, then the VM
│   ├── setup.sh                   # one-shot onboarding + lifecycle wrapper
│   ├── profile.sh                 # granular multi-profile driver (underneath setup.sh)
│   ├── run-ephemeral.sh           # one-off hardened run, --rm on exit
│   └── verify-sandbox.sh          # inside-container hardening check
└── devcontainer-template/
    └── devcontainer.json          # per-repo VS Code Dev Container config
```

## Drive layout

```
/Volumes/DataDrive/
├── .colima/                                # Colima VM state
├── repo/
│   ├── work/                               # repos for the "work" profile
│   ├── personal/                           # repos for "personal"
│   └── sideproject/                        # ...
└── .claude-colima/                        # historic name — actually the macolima
    └── profiles/                          # state root for ALL per-profile state,
        ├── work/                          # not just Claude's. Renaming would touch
        │   ├── claude-home/                # → /home/agent/.claude
        │   ├── claude.json                 # → /home/agent/.claude.json (chmod 644)
        │   ├── config/                     # → /home/agent/.config
        │   │   ├── gh/                     #     GitHub CLI tokens
        │   │   ├── glab-cli/               #     GitLab CLI tokens
        │   │   └── git/config              #     git global config (via GIT_CONFIG_GLOBAL)
        │   ├── gemini-home/                # → /home/agent/.gemini  (Gemini CLI state)
        │   └── db.env                      #     postgres/mongo creds (chmod 600)
        ├── personal/ ...
        └── sideproject/ ...
```

> **`.claude-colima/` is a historic misnomer.** Every script (`profile.sh`, `setup.sh`), audit probe, and dashboard hardcodes this path; the rename to something like `.macolima/` would be a sweeping change for cosmetic gain. Treat it as "macolima profile state root."

Two paths under `/home/agent/` are **named Docker volumes**, not host dirs — `.cache` (`macolima-<p>_cache`) and `.vscode-server` (`macolima-<p>_vscode-server`). Both live in the Colima VM's ext4 to avoid virtiofs `chmod()`/`utime()` errors during wheel and tar extraction. Loss on `--recreate` is cheap (caches are content-addressable). See `CLAUDE.md` → "`.vscode-server` and `.cache` must be named volumes".

## First-time setup

The Quickstart above is the condensed version. Long form with the rationale per step:

```bash
# 1. Host setup — brew installs colima/docker, creates the dir layout on
#    /Volumes/DataDrive/ (just `.colima/`, `.claude-colima/profiles/`, and
#    `repo/` — per-profile state is seeded on demand by profile.sh), and
#    appends two blocks to ~/.zshrc (Homebrew shellenv + COLIMA_HOME /
#    LIMA_HOME). Idempotent.
scripts/bootstrap.sh
source ~/.zshrc

# 2. Start Colima — MUST use this wrapper. A bare `colima start` after a
#    previous `colima delete` will come up with 2 CPU / 2 GB / no mounts
#    and break stack bring-up. The wrapper encodes 6 CPU / 10 GB / 80 GB
#    + virtiofs mounts of /Volumes/DataDrive/repo and .claude-colima.
scripts/colima-up.sh

# 3. (Optional) Refresh the base image digest pin in Dockerfile. The
#    existing pin works fine for first-time setup; do this monthly to
#    pick up upstream security fixes. Requires the daemon to be up,
#    so it goes here, AFTER step 2 — earlier versions of this doc had
#    these swapped, which fails with "failed to connect to the docker
#    API".
docker pull ubuntu:24.04
DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' ubuntu:24.04 | sed 's/.*@//')
sed -i '' "s|ubuntu:24.04@sha256:[a-f0-9]*|ubuntu:24.04@$DIGEST|" Dockerfile

# 4. Build the shared image (all profiles share macolima:latest)
PROFILE=_build docker compose build claude-agent
```

> **After a `colima delete`, always re-run `scripts/colima-up.sh`** — mount paths (`/Volumes/DataDrive/repo`, `/Volumes/DataDrive/.claude-colima`) and resource flags (`--cpu 6 --memory 10 --disk 80 --mount-type virtiofs`) are **not** persisted across a delete. Symptoms of a bare restart: `range of CPUs is from 0.01 to 2.00` on `up`, or `not a directory: Are you trying to mount a directory onto a file` on `rebuild`. See `CLAUDE.md` → "Colima VM delete wipes mount + resource config".

## Using profiles

There are two scripts:

- **`scripts/setup.sh`** — one-shot wrapper for common flows (onboard a new profile, restart, recreate, remove, reset, verify). Use this for 90% of operations.
- **`scripts/profile.sh`** — granular commands (`up`, `down`, `attach`, per-service `auth`, `exec`, `logs`, `build`). Useful for one-off operations or when scripting.

### First-time onboarding (the easy way)

```bash
# Create the repo folder for the profile
mkdir -p /Volumes/DataDrive/repo/work
git clone git@github.com:acme/project.git /Volumes/DataDrive/repo/work/project

# One command: brings stack up, runs `claude login` + `gh auth login`,
# sets git user.name/email, verifies.
scripts/setup.sh work --name "Your Work Name" --email "you@work.example"

# For GitLab instead of GitHub:
scripts/setup.sh work --name "..." --email "..." --gitlab
# For both:
scripts/setup.sh work --name "..." --email "..." --both

# Shell in
scripts/profile.sh work attach
```

### `setup.sh` flags

| Flag | Purpose |
|---|---|
| `--name "..."` + `--email "..."` | git identity (required for first-time setup) |
| `--github` (default) / `--gitlab` / `--both` | which platform(s) to auth |
| `--no-git-auth` / `--no-git-config` / `--no-claude-auth` | skip individual steps |
| `--restart` | `docker compose restart` (preserves container IDs) |
| `--recreate` | force-recreate containers (picks up compose/seccomp/mount changes) |
| `--remove` | `docker compose down` — stops containers, keeps persistent state |
| `--reset --yes` | **nuke** the profile's state dir + drop the `vscode-server`/`cache` volumes, then fresh setup if `--name`/`--email` given. **DB volumes (postgres-data / mongo-data) are preserved by default** — re-up brings the same data back. |
| `--verify` | print compose ps, auth status (claude/gh/glab), git config, egress sentinel state, and `db.env` perms |
| `--yes` | skip confirmation prompts (required for `--reset`) |

`--reset` vs `profile.sh wipe`: both clear rotating state, but they differ on auth:
- **`setup.sh --reset`** deletes Claude/gh/glab tokens with the profile dir, intended for "I want to re-login from scratch" workflows.
- **`profile.sh wipe`** preserves Claude / Gemini / gh / glab / git auth and `db.env`, intended for "I want everything else fresh but don't want to redo OAuth or DB passwords" workflows. `wipe --all-volumes` if you also want DB data dropped (creds in `db.env` still preserved — `rm` it yourself for fresh creds).

Idempotent: `setup.sh` detects if Claude, gh, or glab are already authenticated and skips those prompts. Safe to re-run.

### `profile.sh` commands (granular)

`profile.sh` uses **subcommand** style (no leading `--`). `setup.sh` uses **flag** style. Mixing them up (e.g. `scripts/profile.sh <p> --recreate`) trips the unknown-command branch — the script now prints a "did you mean" hint pointing at the right form.

| Command | Does |
|---|---|
| `scripts/profile.sh list` | List all profiles and up/down status |
| `scripts/profile.sh <p> up` | Start the stack |
| `scripts/profile.sh <p> down` | Stop + remove containers AND networks (state preserved; needed before subnet/IPAM changes) |
| `scripts/profile.sh <p> attach` | `zsh` into the agent container |
| `scripts/profile.sh <p> auth` / `auth-github` / `auth-gitlab` | interactive auth |
| `scripts/profile.sh <p> status` / `logs` | `docker compose ps` / logs |
| `scripts/profile.sh <p> recreate` | force-recreate containers without rebuilding the image (picks up compose / seccomp / squid / mount changes). Same effect as `setup.sh <p> --recreate`. |
| `scripts/profile.sh <p> rebuild` | build image + recreate `<p>` (use after Dockerfile changes) |
| `scripts/profile.sh <p> wipe` | blank-slate the profile, **preserve** Claude / Gemini / gh / glab / git auth + `db.env` (use `--all-volumes` to also drop DB data) |
| `scripts/profile.sh <p> exec <cmd>` | run arbitrary command in the container |
| `scripts/profile.sh build` | rebuild the shared image only |

### Running multiple profiles at once

```bash
scripts/profile.sh work up
scripts/profile.sh personal up
scripts/profile.sh list
#   personal            up     /Volumes/DataDrive/repo/personal
#   work                up     /Volumes/DataDrive/repo/work
```

Each profile gets its own 8g memory / 4 CPU envelope and its own Squid proxy. Three concurrent profiles ≈ 24g of headroom needed in Colima's VM.

## Databases (optional)

Postgres 18 and Mongo 8 sibling containers ship in `docker-compose.yml` but are gated behind compose `profiles:` — they stay dormant unless you opt in per-profile. Both sit on `sandbox-internal` (no external reachability) and use named volumes (`macolima-<p>_postgres-data` / `_mongo-data`) inside the VM's ext4 to avoid virtiofs permission issues.

```bash
# Bring up a profile with Postgres, Mongo, or both
COMPOSE_PROFILES=db-postgres          scripts/profile.sh <p> up
COMPOSE_PROFILES=db-mongo             scripts/profile.sh <p> up
COMPOSE_PROFILES=db-all               scripts/profile.sh <p> up
```

On first `up`, `profiles/<p>/db.env.example` is seeded from `config/db.env.template`. Copy to `db.env`, replace every `__SET_ME__`, re-up:

```bash
cp /Volumes/DataDrive/.claude-colima/profiles/<p>/db.env.example \
   /Volumes/DataDrive/.claude-colima/profiles/<p>/db.env
# edit passwords (suggested: `openssl rand -hex 24` for URL-safe values), then:
COMPOSE_PROFILES=db-all scripts/profile.sh <p> up
```

`scripts/profile.sh ... up` re-asserts `chmod 600` on `db.env` automatically — you don't need to chmod it yourself. `setup.sh --verify` will warn if perms drift.

**Heads-up:** `POSTGRES_USER` / `POSTGRES_PASSWORD` and `MONGO_INITDB_ROOT_*` are only consumed on the postgres/mongo container's *first* boot. Editing `db.env` after that does **not** change creds inside the DB — see CLAUDE.md → "First-init lock-in" for the fix (ALTER USER, or wipe the volume).

**Project DSN vars** (e.g. `WEARDATA_PG_DSN`, `DATABASE_URL`) go in `db.env` alongside `POSTGRES_*` — agent code reads them as env. Adding/editing one after first `up` requires a force-recreate of the agent (compose reads `env_file` at create time only): `COMPOSE_PROFILES=db-postgres PROFILE=<p> docker compose -p macolima-<p> up -d --force-recreate claude-agent`, then re-attach VS Code.

**Multiple projects in one profile:** one Postgres server hosts many databases. The default `postgres` database is created automatically; create project databases explicitly with `CREATE DATABASE <name> OWNER agent;` (run via `psql -U agent -d postgres`) and add one DSN per project in `db.env` — same host/user/password, just different database name at the end. See `config/db.env.template` for examples.

Inside the agent the DBs are reachable as `postgres:5432` and `mongo:27017`; `psql` and `mongosh` are preinstalled, and the creds come in via env. For host GUI access (TablePlus, Compass), uncomment the `ports:` block on the relevant service — loopback-only, never `0.0.0.0`.

Backups: `pg_dump` / `mongodump` into `/workspace`, which is the one bind mount on the external drive and survives a VM rebuild. Current caveat: the agent holds DB **admin** creds — see `CLAUDE.md` for the planned least-privilege split. The DB containers themselves run with `cap_drop: ALL` and only the four caps their entrypoints actually need (`CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID`); `CAP_NET_RAW` and the rest of Docker's default cap set are dropped, so a worst-case in-DB compromise has fewer kernel surfaces to push on.

## Web UIs (Streamlit, Dash, Jupyter, dashboards)

Default path is **VS Code Dev Containers port forwarding** — when attached, any port a process binds inside the container is auto-forwarded to `localhost:<same-port>` on your Mac via the `docker exec` channel. No compose changes, no open host ports. Bind to `0.0.0.0` inside the container so VS Code sees the listener:

```bash
streamlit run app.py --server.address 0.0.0.0
# dash / flask: app.run(host="0.0.0.0")
# jupyter:       jupyter lab --ip 0.0.0.0 --no-browser
```

For non-VS Code use, add a loopback port to the `claude-agent` service: `ports: ["127.0.0.1:8501:8501"]`. This is inbound from your Mac only; it does not grant the agent any new outbound capability.

## Authentication inside a profile

### Claude Code
`scripts/profile.sh <p> auth` runs `claude login`. Use the URL/code flow on your Mac browser — the token lands in the profile's mounted `.claude/.credentials.json` and survives container recreates.

### GitHub (`gh`) / GitLab (`glab`)

Run `scripts/profile.sh <p> auth-github` or `auth-gitlab`. At the prompts, pick **HTTPS** and **"Paste an authentication token"** (not browser).

**Why not browser flow?** The OAuth callback goes to `http://localhost:<port>` on the *container's* loopback, which your Mac browser can't reach — the sandbox network is `internal: true` by design. You'll see "this site can't be reached" on the redirect. Token flow sidesteps this entirely.

Generate the token in the web UI:
- **GitHub:** Settings → Developer settings → Personal access tokens → Fine-grained or classic. Scopes: `repo`, `read:org`, `workflow` (or the fine-grained equivalents).
- **GitLab:** User settings → Access Tokens. Scopes: `api` + `write_repository` (skip `read_repository`/`read_user` — redundant).

Tokens are stored under the profile's `config/gh/` or `config/glab-cli/` and survive recreates. After login, `git push`/`pull` works transparently — both CLIs install themselves as git credential helpers.

For **self-hosted GitLab**, add the host to `proxy/allowed_domains.txt` before `glab auth login`.

### Per-profile git identity
Git's global config file is redirected via `GIT_CONFIG_GLOBAL=/home/agent/.config/git/config` — a regular file inside the mounted `.config/` directory. (Bind-mounting `~/.gitconfig` directly fails with `Device or resource busy` because `git config` writes atomically via `rename()`, which can't cross a single-file bind-mount boundary.)

`setup.sh` sets `user.name` / `user.email` automatically. To change them later:

```bash
scripts/profile.sh work exec git config --global user.name  "Work Name"
scripts/profile.sh work exec git config --global user.email "work@example"
```

### SSH (if you prefer it over HTTPS)
Not wired up by default. The proxy would need to allow CONNECT on port 22 (`squid.conf` changes) and you'd want per-profile key storage. Open an issue-style note in `CLAUDE.md` if you need this.

## VS Code integration

Two paths — pick based on how you work.

**A. Attach to a running profile:** `scripts/profile.sh work up`, then `Cmd-Shift-P → Dev Containers: Attach to Running Container → claude-agent-work`. This is the recommended path.

**B. Per-repo attach config:** copy `devcontainer-template/devcontainer.json` into `<repo>/.devcontainer/`. The template is *attach-only* — it has no `image`/`runArgs`/`mounts`/`network` fields. It exists so VS Code picks up the right `remoteUser: agent`, `updateRemoteUserUID: false`, and `overrideCommand: false` settings on attach, and nothing more. Compose owns the container's hardening; a devcontainer.json that tried to re-declare `runArgs` would either fight compose or spin up a parallel container with weaker settings.

### Required host settings — Dev Containers leakage hardening

VS Code injects three host→container bridges by default that **bypass the sandbox network identity**. Disable all three in your host `settings.json` (`~/Library/Application Support/Code/User/settings.json` on macOS):

```jsonc
"dev.containers.copyGitConfig": false,
"dev.containers.gitCredentialHelperConfigLocation": "none",
"remote.SSH.enableAgentForwarding": false
```

- `copyGitConfig` copies your host `~/.gitconfig` into the rootfs overlay (includes `osxkeychain` / `git-credential-manager` references).
- `gitCredentialHelperConfigLocation` injects an IPC-backed helper shim into `~/.config/git/config` that forwards git auth to the host credential manager — **separate setting from `copyGitConfig`**.
- `enableAgentForwarding` injects `SSH_AUTH_SOCK=/tmp/vscode-ssh-auth-*.sock` so the agent can reach any host your SSH keys authenticate to.

Plus a per-repo `.devcontainer/devcontainer.json` with `"updateRemoteUserUID": false` — without it, VS Code runs `usermod` as root during attach, which can leave a stray UID-0 shell orphaned in the container. A ready template is at `devcontainer-template/devcontainer.json`.

The inside-container tripwire (`scripts/verify-sandbox.sh`) checks all three leakage paths plus the UID-0 orphan; if anything comes back from a reattach, it will FAIL loudly. The SSH-socket check is gated on the *combination* of mitigations — an accumulating `/tmp/vscode-ssh-auth-*.sock` file is treated as cosmetic so long as `SSH_AUTH_SOCK` stays unset and `openssh-client` stays purged; FAIL only fires when one of those layers is also broken.

Install MesloLGS NF on the Mac for p10k icons:
```bash
brew install --cask font-meslo-lg-nerd-font
```
Then in VS Code: `"terminal.integrated.fontFamily": "MesloLGS NF"`.

## Security model

Each profile is a separate sandbox. Within one profile:

| Layer | Where | Enforcement |
|-------|-------|------|
| Host → VM isolation | Colima (vz) | Apple Virtualization.framework |
| Non-root container user | `Dockerfile` | UID 1000, no sudo, no suid |
| All capabilities dropped (agent) | `docker-compose.yml` | kernel (`cap_drop: ALL`) |
| Minimal caps on DB siblings | `docker-compose.yml` | postgres/mongo run with only `CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID` |
| `no-new-privileges` | `docker-compose.yml` | kernel |
| Seccomp syscall filter | `seccomp.json` | kernel (allowlist; `clone3` → ENOSYS for glibc fallback) |
| Resource limits | `docker-compose.yml` | cgroups + ulimits |
| No direct internet | `docker-compose.yml` | Docker network isolation (`internal: true`) |
| No DNS forwarding | `docker-compose.yml` | `dns: [127.0.0.1]` sinkhole + `extra_hosts` for siblings |
| Egress HTTP allowlist | `proxy/allowed_domains.txt` | Squid sidecar (domain + port + CONNECT-only-on-443) |
| Destructive-command deny | `config/hooks/deny-destructive.sh` | Claude Code `PreToolUse` hook — content-aware regex on the full envelope; catches shapes the matcher prefix can't see (`find -delete`, `dd of=`, `git clean`, hook/settings tamper). Hook is root-owned in the image; agent has no tool path that bypasses kernel write-protect. |
| Auth token isolation | per-profile bind mount | filesystem |
| `db.env` perms enforced | `profile.sh ensure_state` | `chmod 600` re-asserted on every `up` |

Claude Code's in-process bwrap sandbox is **disabled** (`sandbox.enabled: false` in the settings template) and `bubblewrap` + `socat` are not installed in the image. bwrap needs unprivileged user namespaces, which our seccomp filter correctly blocks, and `socat` was a raw-TCP exfil channel bypassing the HTTP-only Squid egress. The container is the boundary; see `CLAUDE.md` for the full rationale.

The profile layer adds **cross-profile** isolation:
- Separate networks → no IP-level cross-talk between profiles.
- Separate state dirs → no credential, session, or MCP leakage.
- Separate containers → `docker exec` into the wrong profile returns "no such container".

### Egress channels and what they trust

Three distinct egress paths from the agent, each with a different trust model — operators should know which is which:

| Channel | Path | What constrains it |
|---|---|---|
| `Bash` HTTP/HTTPS | container → Squid → internet | `proxy/allowed_domains.txt` + Squid port restriction (CONNECT only on 443) |
| DNS | container `getaddrinfo` | `/etc/hosts` only — Docker DNS sinkholed (audit H2) |
| `WebFetch` (Claude tool) | Anthropic's server → arbitrary URL | **Anthropic infra; bypasses the local proxy entirely.** The destination logs every URL fetched — treat it as an exfil channel and only allow per-project `WebFetch(domain:…)` patterns in `.claude/settings.local.json`, never bare `WebFetch` in the template. |

`WebSearch` is allowed by default because it returns summarized search results rather than fetching a chosen URL — the agent doesn't get to pick the destination.

### Self-audit from inside the sandbox

Each profile ships with the `audit-sandbox` skill at `~/.claude/skills/audit-sandbox/` (seeded by `ensure_state()` from `config/skills/audit-sandbox/SKILL.md`). To run:

```bash
# host: stage the audit package into this profile's workspace
scripts/stage-audit-package.sh <profile>

# attach and invoke the skill
scripts/profile.sh <profile> attach
# inside the container's claude prompt:
/audit-sandbox
```

The skill follows `claude_internal_audit.md` — runs the `verify-sandbox.sh` tripwire first (all PASS expected; the suite covers ~25 checks across egress, DNS, seccomp, SUID inventory, VS Code leakage, the `PreToolUse` hook, and more), then deeper invariant checks (caps, seccomp, mounts, proxy egress, VS Code leakage, etc.), and writes two artifacts to `~/.claude/audits/` inside the container (host path: `/Volumes/DataDrive/.claude-colima/profiles/<profile>/claude-home/audits/`):

- `<YYYY-MM-DD>-<profile>-report.md` — markdown report, invariants tagged OK/DRIFT/WEAK/UNKNOWN
- `<YYYY-MM-DD>-<profile>-commands.sh` — replayable command log

If you edit `claude_internal_audit.md`, just re-run `stage-audit-package.sh` — the skill reads the staged file rather than duplicating its content. If you edit `config/skills/audit-sandbox/SKILL.md` itself, run `scripts/profile.sh <profile> reset-skills` to refresh existing profiles (new profiles pick it up automatically on first `up`).

## Updating

```bash
# Rebuild shared image (all profiles pick it up on their next `rebuild`)
scripts/profile.sh build

# Apply the new image to a running profile (image only, no compose changes)
scripts/profile.sh work recreate
# or equivalently: scripts/setup.sh work --recreate

# Proxy allowlist change (hot reload, per profile — no recreate needed)
vim proxy/allowed_domains.txt
COMPOSE_PROJECT_NAME=macolima-work PROFILE=work docker compose restart egress-proxy

# Bump base image (monthly)
docker pull ubuntu:24.04
DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' ubuntu:24.04 | sed 's/.*@//')
sed -i '' "s|ubuntu:24.04@sha256:[a-f0-9]*|ubuntu:24.04@$DIGEST|" Dockerfile
scripts/profile.sh build
scripts/profile.sh work rebuild  # build + recreate the running profile
```

> **Compose network changes need `down`+`up`, not just `recreate`.** If a change touches the `sandbox-internal` network's `ipam.config.subnet`, any service's `ipv4_address`, the agent's `dns:` / `extra_hosts`, or the network's `internal:` flag, `--force-recreate` won't update the existing network — it only recreates containers. The fix:
> ```bash
> COMPOSE_PROFILES=db-postgres scripts/profile.sh <p> down       # remove containers + networks (keeps named volumes / DB data)
> COMPOSE_PROFILES=db-postgres scripts/profile.sh <p> rebuild    # bring everything back on the new network config
> ```
> Include `COMPOSE_PROFILES=db-postgres` (or `db-mongo` / `db-all`) if you have DB siblings, otherwise their containers stay on the old network and the agent's `extra_hosts` resolves to a stale IP. Symptom: `container ... is not connected to the network macolima-<p>_sandbox-internal`.

## Resetting and starting fresh

Three tiers, ordered by destructiveness. Pick the smallest one that does what you need.

### What you can't get back

Every tier below tells you what it *drops* — but most dropped state is regenerable (settings/skills re-seed from `config/`, caches re-download, auth comes back with a re-login). **Only three things are truly irrecoverable — no script can regenerate them:**

1. **Unpushed / uncommitted code in `/workspace`** (`/Volumes/DataDrive/repo/<profile>/`). No reset path touches this — but Tier 3 *invites* you to wipe it by hand, and once it's gone with unpushed commits, it's gone. **This is the #1 risk.**
2. **Claude session / conversation history** — `profiles/<p>/claude-home/` `projects/`, `sessions/`, `todos/`, `shell-snapshots/`. Dropped by `wipe` and `--reset`. There is no template to rebuild it.
3. **Database rows** in `postgres-data` / `mongo-data`. The *schema* is recreatable (`alembic upgrade head` / your seed scripts); the *data* is not, unless it came from a seed. Dropped by `db-reset`, `wipe --all-volumes`, and Tier 3.

Run this pre-flight per profile before any reset, and stop if anything looks unsaved:

```bash
git -C /Volumes/DataDrive/repo/<p> status --short                            # uncommitted changes?
git -C /Volumes/DataDrive/repo/<p> log --branches --not --remotes --oneline  # commits not pushed?
ls /Volumes/DataDrive/.claude-colima/profiles/<p>/claude-home/projects        # history you care about?
```

> **DB gotcha:** `db.env` holds the *generated* DB superuser password, baked into `postgres-data` at first initdb. Never regenerate `db.env` while keeping the old data volume — the new password won't authenticate against the old volume (see "First-init lock-in" below). Drop both together or keep both.

### Tier 1 — Single profile, **keep auth**

For "I want to clear settings/sessions/MCP debug logs but not redo OAuth":

```bash
scripts/profile.sh <profile> wipe              # interactive — type the profile name to confirm
scripts/profile.sh <profile> wipe --yes        # non-interactive
scripts/profile.sh <profile> wipe --all-volumes  # also drop postgres-data / mongo-data
```

Drops: containers + `vscode-server` / `cache` named volumes, `profiles/<p>/` (settings, sessions, audits, MCP config, paste-cache).
Keeps: `.credentials.json` (Claude), `claude.json`, `config/gh/`, `config/glab-cli/`, `config/git/`, `gemini-home/oauth_creds.json`, `db.env`, DB volumes (unless `--all-volumes`).

### Tier 2 — Single profile, **also re-do auth**

For "I want a clean profile from scratch including a new Claude/gh login":

```bash
scripts/setup.sh <profile> --reset --yes --name "Your Name" --email "you@x"
```

Drops everything from Tier 1 plus all auth tokens. After tearing down, falls through into the normal first-time-setup flow if `--name`/`--email` are provided. DB volumes preserved by default; pass `--all-volumes` (manually after the prompt) to drop those too.

### Tier 3 — Total nuke (back to "just cloned" state)

For "I want this machine to look like I just cloned the repo and haven't run anything yet". **Wipes the Colima VM and every profile.**

```bash
# 1. Stop and delete Colima — drops images, containers, networks, AND every named
#    volume including postgres-data / mongo-data on every profile.
colima stop -f
colima delete -f
rm -rf /Volumes/DataDrive/.colima      # also clears persisted Colima config + lingering disks

# 2. Wipe per-profile state for ALL profiles (auth, settings, sessions, audits, db.env)
rm -rf /Volumes/DataDrive/.claude-colima

# 3. Strip the two ~/.zshrc blocks that bootstrap.sh appended.
sed -i '' '/^# >>> homebrew shellenv >>>/,/^# <<< homebrew shellenv <<<$/d' ~/.zshrc
sed -i '' '/^# >>> macolima env >>>/,/^# <<< macolima env <<<$/d' ~/.zshrc
# Open a fresh terminal so $COLIMA_HOME / $LIMA_HOME unset.

# 4. (Optional) Restore VS Code host settings to defaults — only if you really want
#    clone-state. See "Required host settings" above; removing these re-opens the
#    Dev Containers leakage paths the audit closed, so leave them set unless you
#    have a reason.
#
# 5. (Optional) Uninstall the Homebrew packages bootstrap.sh installed:
#       brew uninstall colima docker docker-compose docker-buildx flock
#       brew uninstall --cask font-meslo-lg-nerd-font
```

What Tier 3 **does not touch** (deliberately):
- `/Volumes/DataDrive/repo/<profile>/` — your actual code stays put. Wipe these by hand if you want to.
- `~/Library/Application Support/Code/User/settings.json` (the three Dev Containers hardening keys).
- Homebrew packages and Rosetta.
- The `macolima` repo itself.
- Personal access tokens you generated on github.com / gitlab.com — those are upstream. Revoke in the respective web UI if you want clean state there.

After Tier 3, return to **Quickstart** at the top of this README — same six commands.

## Troubleshooting

See `CLAUDE.md` for root-caused gotchas. Common ones:

- **`PROFILE env var required`** → you ran `docker compose` directly instead of `scripts/profile.sh`.
- **`Repo dir does not exist`** → make `/Volumes/DataDrive/repo/<profile>/` first.
- **`failed to connect to the docker API at unix:///Volumes/DataDrive/.colima/default/docker.sock`** → Colima isn't running. Run `scripts/colima-up.sh`. If `echo $COLIMA_HOME` is empty, your shell lost the macolima env block — re-source `~/.zshrc`, or open a fresh terminal, or re-run `scripts/bootstrap.sh` if you stripped the block.
- **`range of CPUs is from 0.01 to 2.00`** or **`not a directory: Are you trying to mount a directory onto a file`** on `up`/`rebuild` → Colima VM was created with defaults after a `colima delete` + bare `colima start`. Fix: re-run `scripts/colima-up.sh`. Root cause in `CLAUDE.md` → "Colima VM delete wipes mount + resource config".
- **`container <id> is not connected to the network macolima-<p>_sandbox-internal`** → compose network IPAM changed (subnet, `ipv4_address`, `dns:`, `extra_hosts`) but the existing network still has the old config. `--force-recreate` only recreates containers, not networks. Fix:
  ```bash
  COMPOSE_PROFILES=db-postgres scripts/profile.sh <p> down
  COMPOSE_PROFILES=db-postgres scripts/profile.sh <p> rebuild
  ```
  Include `COMPOSE_PROFILES=` if you have DB siblings; otherwise they stay on the old network. (Named volumes including DB data are preserved by `down`.)
- **`scripts/profile.sh <p> --recreate` exits and prints the help** → flag-style vs subcommand-style mix-up. `setup.sh` uses flags (`--recreate`); `profile.sh` uses subcommands (`recreate`). The script prints a "did you mean" hint pointing at the right form.
- **Tripwire FAIL on `credential.helper`** but value is `!/usr/local/bin/glab auth git-credential` (or `gh`) → that's the **in-container** helper from `glab`/`gh auth setup-git`, which is expected and benign. The tripwire only flags host-reaching helpers (`vscode-server | vscode-remote-containers | osxkeychain | git-credential-manager`); if yours matches one of those, check your host VS Code settings (see "VS Code integration" above).
- **Claude asks to log in after recreate** → check `claude.json` exists, is 644, and contains `{}` (not empty) under the profile's dir.
- **`claude login` → "invalid JSON: Unexpected EOF"** → `claude.json` is 0 bytes. `profile.sh` now seeds `{}` automatically; for older profiles: `echo '{}' > /V/.../profiles/<p>/claude.json`.
- **`gh`/`glab auth login` browser redirect shows "this site can't be reached"** → expected; use token flow instead (see Authentication above).
- **Terminal job-control errors** → seccomp gap; see `CLAUDE.md` debug recipes.
- **VS Code Dev Container tar `utime` errors** → `.vscode-server` is a named volume for a reason; don't switch it to a bind mount.
