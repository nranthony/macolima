<p align="center">
  <img src="images/macolima_silly_logo.png" alt="macolima" width="520">
</p>

# macolima

Hardened multi-profile sandbox for running Claude Code in auto mode on macOS. Colima-based Linux VM on an external drive. Each profile is a fully isolated stack (own containers, own networks, own persistent state) built from a single shared image.

**Target host:** Mac (Apple Silicon), external drive at `/Volumes/DataDrive`.

## Concept: profiles

A *profile* is a named sandbox instance — e.g. `work`, `personal`, `sideproject`. Each profile:

- Has its own agent container (`claude-agent-<profile>`) and proxy (`egress-proxy-<profile>`).
- Runs on its own isolated Docker networks (no cross-profile traffic).
- Has its own Claude auth, session history, MCP config, git identity, and gh/glab tokens.
- Mounts one subfolder of `/Volumes/DataDrive/repo/<profile>/` as `/workspace`.
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
│   ├── colima-up.sh               # first-time colima start
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
└── .claude-colima/
    └── profiles/
        ├── work/
        │   ├── claude-home/                # → /home/agent/.claude
        │   ├── claude.json                 # → /home/agent/.claude.json (chmod 644)
        │   ├── cache/                      # → /home/agent/.cache
        │   └── config/                     # → /home/agent/.config
        │       ├── gh/                     #     GitHub CLI tokens
        │       ├── glab-cli/               #     GitLab CLI tokens
        │       └── git/config              #     git global config (via GIT_CONFIG_GLOBAL)
        ├── personal/ ...
        └── sideproject/ ...
```

## First-time setup

```bash
# 1. Host setup (one-time)
scripts/bootstrap.sh
source ~/.zshrc

# 2. Pin base image digest
docker pull ubuntu:24.04
DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' ubuntu:24.04 | sed 's/.*@//')
sed -i '' "s|ubuntu:24.04@sha256:[a-f0-9]*|ubuntu:24.04@$DIGEST|" Dockerfile

# 3. Start Colima
scripts/colima-up.sh

# 4. Build the image (shared across all profiles)
PROFILE=_build docker compose build claude-agent
```

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
| `--reset --yes` | **nuke** the profile's state dir, then fresh setup if `--name`/`--email` given |
| `--verify` | print compose ps + auth status (claude/gh/glab) + git config |
| `--yes` | skip confirmation prompts (required for `--reset`) |

Idempotent: `setup.sh` detects if Claude, gh, or glab are already authenticated and skips those prompts. Safe to re-run.

### `profile.sh` commands (granular)

| Command | Does |
|---|---|
| `scripts/profile.sh list` | List all profiles and up/down status |
| `scripts/profile.sh <p> up` | Start the stack |
| `scripts/profile.sh <p> down` | Stop + remove containers (state preserved) |
| `scripts/profile.sh <p> attach` | `zsh` into the agent container |
| `scripts/profile.sh <p> auth` / `auth-github` / `auth-gitlab` | interactive auth |
| `scripts/profile.sh <p> status` / `logs` | `docker compose ps` / logs |
| `scripts/profile.sh <p> rebuild` | rebuild image + recreate `<p>` |
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

On first `up`, `profiles/<p>/db.env.example` is seeded. Copy to `db.env`, set real passwords, re-up:

```bash
cp /Volumes/DataDrive/.claude-colima/profiles/<p>/db.env.example \
   /Volumes/DataDrive/.claude-colima/profiles/<p>/db.env
chmod 600 /Volumes/DataDrive/.claude-colima/profiles/<p>/db.env
# edit passwords, then:
COMPOSE_PROFILES=db-all scripts/profile.sh <p> up
```

Inside the agent the DBs are reachable as `postgres:5432` and `mongo:27017`; `psql` and `mongosh` are preinstalled, and the creds come in via env. For host GUI access (TablePlus, Compass), uncomment the `ports:` block on the relevant service — loopback-only, never `0.0.0.0`.

Backups: `pg_dump` / `mongodump` into `/workspace`, which is the one bind mount on the external drive and survives a VM rebuild. Current caveat: the agent holds DB **admin** creds — see `CLAUDE.md` for the planned least-privilege split.

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

**A. Attach to a running profile:** `scripts/profile.sh work up`, then `Cmd-Shift-P → Dev Containers: Attach to Running Container → claude-agent-work`.

**B. Dev Container in a specific repo:** copy `devcontainer-template/devcontainer.json` into `<repo>/.devcontainer/`. Note that the template mounts the hard-coded `work` profile's state — duplicate it per profile if needed, or parameterize via VS Code container env.

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
| All capabilities dropped | `docker-compose.yml` | kernel (`cap_drop: ALL`) |
| `no-new-privileges` | `docker-compose.yml` | kernel |
| Seccomp syscall filter | `seccomp.json` | kernel |
| Resource limits | `docker-compose.yml` | cgroups + ulimits |
| No direct internet | `docker-compose.yml` | Docker network isolation |
| Egress domain allowlist | `proxy/allowed_domains.txt` | Squid sidecar |
| In-process sandbox (bwrap) | Claude settings | bubblewrap |
| Auth token isolation | per-profile bind mount | filesystem |

The profile layer adds **cross-profile** isolation:
- Separate networks → no IP-level cross-talk between profiles.
- Separate state dirs → no credential, session, or MCP leakage.
- Separate containers → `docker exec` into the wrong profile returns "no such container".

Rootfs is **not** `read_only: true` on the agent — it broke VS Code Dev Containers' `/etc/environment` patching with no security gain given the non-root + cap-drop controls.

## Updating

```bash
# Rebuild shared image (all profiles pick it up on their next `rebuild`)
scripts/profile.sh build

# Apply the new image to a running profile
scripts/setup.sh work --recreate

# Proxy allowlist change (hot reload, per profile)
vim proxy/allowed_domains.txt
COMPOSE_PROJECT_NAME=macolima-work PROFILE=work docker compose restart egress-proxy

# Bump base image (monthly)
docker pull ubuntu:24.04
DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' ubuntu:24.04 | sed 's/.*@//')
sed -i '' "s|ubuntu:24.04@sha256:[a-f0-9]*|ubuntu:24.04@$DIGEST|" Dockerfile
scripts/profile.sh build
```

## Troubleshooting

See `CLAUDE.md` for root-caused gotchas. Common ones:

- **`PROFILE env var required`** → you ran `docker compose` directly instead of `scripts/profile.sh`.
- **`Repo dir does not exist`** → make `/Volumes/DataDrive/repo/<profile>/` first.
- **Claude asks to log in after recreate** → check `claude.json` exists, is 644, and contains `{}` (not empty) under the profile's dir.
- **`claude login` → "invalid JSON: Unexpected EOF"** → `claude.json` is 0 bytes. `profile.sh` now seeds `{}` automatically; for older profiles: `echo '{}' > /V/.../profiles/<p>/claude.json`.
- **`gh`/`glab auth login` browser redirect shows "this site can't be reached"** → expected; use token flow instead (see Authentication above).
- **Terminal job-control errors** → seccomp gap; see `CLAUDE.md` debug recipes.
- **VS Code Dev Container tar `utime` errors** → `.vscode-server` is a named volume for a reason; don't switch it to a bind mount.
