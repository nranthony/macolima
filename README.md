# macolima

Hardened sandbox for running Claude Code in auto mode on macOS. Colima-based Linux VM on an external drive, with a locked-down container (non-root, dropped capabilities, seccomp filter, egress proxy with domain allowlist) plus Claude Code's in-process sandbox as a second layer.

**Target host:** Mac (Apple Silicon), external drive at `/Volumes/DataDrive`.

## Layout

```
macolima/
├── Dockerfile                     # hardened image: non-root agent, zsh+p10k baked in
├── docker-compose.yml             # stack: claude-agent + egress-proxy
├── seccomp.json                   # syscall filter (derived from Docker default)
├── config/
│   ├── claude-settings.json       # seeded to ~/.claude/settings.json
│   ├── zshrc-snippet.sh           # COLIMA_HOME / LIMA_HOME vars for host ~/.zshrc
│   ├── .zshrc                     # in-container zsh config
│   └── .p10k.zsh                  # powerlevel10k prompt config
├── proxy/
│   ├── squid.conf
│   └── allowed_domains.txt        # outbound domain allowlist
├── scripts/
│   ├── bootstrap.sh               # one-time host setup (brew, dirs, zshrc)
│   ├── colima-up.sh               # first-time colima start with flags
│   ├── start.sh / stop.sh         # daily
│   ├── attach.sh                  # shell into running container
│   ├── run-ephemeral.sh           # one-off hardened run, --rm on exit
│   ├── auth.sh                    # claude login (OAuth, one-time)
│   └── verify-sandbox.sh          # inside-container hardening check
└── devcontainer-template/
    └── devcontainer.json          # copy into target repos for VS Code attach
```

## Drive layout (persistent state)

```
/Volumes/DataDrive/
├── .colima/                       # Colima VM state (COLIMA_HOME)
├── repo/                          # your git repos → mounted at /workspace
└── .claude-colima/
    ├── claude-home/               # ~/.claude (tokens, settings, sessions)
    ├── claude.json                # ~/.claude.json (oauth account, first-run state)
    └── workspace-cache/           # ~/.cache (npm, uv, pip)
```

`claude.json` must be **chmod 644** (not 600). Virtiofs owner mapping makes a 600 file appear as `root:root` inside the container, which the agent user can't read.

## First-time setup

```bash
# 1. Host setup (brew, dirs, ~/.zshrc snippet, seed claude-settings.json)
scripts/bootstrap.sh
source ~/.zshrc

# 2. Pin base image digest (periodically refresh)
docker pull ubuntu:24.04
DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' ubuntu:24.04 | sed 's/.*@//')
sed -i '' "s|ubuntu:24.04@sha256:[a-f0-9]*|ubuntu:24.04@$DIGEST|" Dockerfile

# 3. Create the claude.json file so the bind mount has a target
touch /Volumes/DataDrive/.claude-colima/claude.json
chmod 644 /Volumes/DataDrive/.claude-colima/claude.json

# 4. Start Colima
scripts/colima-up.sh

# 5. Build image + bring stack up
scripts/start.sh

# 6. First-time OAuth (token written to claude-home/, survives recreates)
scripts/auth.sh

# 7. Verify hardening
docker exec -it claude-agent bash /workspace/nranthony/macolima/scripts/verify-sandbox.sh
```

## Daily use

```bash
scripts/start.sh       # bring Colima + stack up
scripts/attach.sh      # shell into claude-agent → run `claude`
scripts/stop.sh        # tear down
```

One-off ephemeral run (`--rm` on exit):

```bash
scripts/run-ephemeral.sh nranthony/<repo> claude
```

## VS Code integration

Two ways:

**A. Attach to running container** — `Cmd-Shift-P` → `Dev Containers: Attach to Running Container` → `claude-agent`. Uses the already-running stack.

**B. Dev Container in target repo** — copy `devcontainer-template/devcontainer.json` into `<repo>/.devcontainer/`, then `Dev Containers: Reopen in Container`. Spawns a container from `macolima:latest` with the same mounts + hardening.

Install **MesloLGS NF** on the Mac for p10k icons in the VS Code terminal:

```bash
brew install --cask font-meslo-lg-nerd-font
```

Then set `"terminal.integrated.fontFamily": "MesloLGS NF"` in VS Code settings.

## Security model

| Layer | Where | Enforcement |
|-------|-------|------|
| Host → VM isolation | Colima (vz) | Apple Virtualization.framework |
| Non-root container user | `Dockerfile` | UID 1000, no sudo, no suid binaries added |
| All capabilities dropped | `docker-compose.yml` | kernel (`cap_drop: ALL`) |
| `no-new-privileges` | `docker-compose.yml` | kernel |
| Seccomp syscall filter | `seccomp.json` | kernel (blocks ptrace, mount, bpf, keyctl, kexec, unshare, setns, etc.) |
| Resource limits (cpu/mem/pids/nofile/nproc) | `docker-compose.yml` | cgroups + ulimits |
| No direct internet | `docker-compose.yml` (`sandbox-internal: internal: true`) | Docker network isolation |
| Egress domain allowlist | `proxy/allowed_domains.txt` | Squid proxy sidecar |
| Read-only tmpfs for volatile paths | `docker-compose.yml` | kernel (`noexec,nosuid,nodev`) |
| In-process sandbox (bwrap) | `config/claude-settings.json` | bubblewrap (defense-in-depth) |
| Auth token isolation | drive bind mount | filesystem |

The **kernel-level** controls (cap_drop, seccomp, network isolation, proxy) are the real boundary. Claude's in-process sandbox is a second layer, not the primary one.

Rootfs is **not** `read_only: true` on the agent container — that broke VS Code Dev Containers' `/etc/environment` patching with no security gain (a non-root user with `cap_drop: ALL` already cannot write to system dirs by file permissions).

## Updating

```bash
# Image rebuild
docker compose build --no-cache claude-agent
docker compose up -d --force-recreate claude-agent

# Base image digest (monthly)
docker pull ubuntu:24.04
DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' ubuntu:24.04 | sed 's/.*@//')
sed -i '' "s|ubuntu:24.04@sha256:[a-f0-9]*|ubuntu:24.04@$DIGEST|" Dockerfile

# Proxy allowlist change (hot reload, no rebuild)
vim proxy/allowed_domains.txt
docker compose restart egress-proxy
```

## Troubleshooting

See `CLAUDE.md` for the full list of gotchas and their root causes. The common ones:

- **Claude asks to log in after a recreate** → `/Volumes/DataDrive/.claude-colima/claude.json` missing or not 644.
- **Terminal errors `getpgrp failed: Operation not permitted`** → seccomp missing a syscall. Set `GITSTATUS_LOG_LEVEL=DEBUG` in `.zshrc`, reopen terminal, check `/tmp/gitstatus.*.log`.
- **VS Code Dev Container tar extraction fails with `utime EPERM`** → `.vscode-server` must be a named Docker volume, not a virtiofs bind mount.
- **egress-proxy restart-looping** → Squid needs `cap_add: [SETUID, SETGID]` and `pinger_enable off`.
- **Permissions on `/home/agent/...` wrong** → the Dockerfile must pre-create every path that becomes a named-volume mount point, with `chown agent:agent`.
