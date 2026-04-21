# macolima

Hardened sandbox for running Claude Code in auto mode on macOS. Colima-based VM on an external drive, with a locked-down container (read-only rootfs, dropped capabilities, seccomp filter, egress proxy with domain allowlist) plus Claude Code's in-process sandbox as a second layer.

**Target host:** Mac (Apple Silicon), external drive at `/Volumes/DataDrive`.

## Layout

```
macolima/
├── Dockerfile                     # hardened image: non-root agent, no sudo
├── docker-compose.yml             # persistent stack: agent + egress-proxy
├── seccomp.json                   # syscall filter (blocks ptrace, mount, bpf, ...)
├── config/
│   ├── claude-settings.json       # seeded to ~/.claude/settings.json in container
│   └── zshrc-snippet.sh           # COLIMA_HOME / LIMA_HOME env vars
├── proxy/
│   ├── squid.conf
│   └── allowed_domains.txt        # outbound domain allowlist
├── scripts/
│   ├── bootstrap.sh               # one-time host setup
│   ├── colima-up.sh               # first-time `colima start` with flags
│   ├── start.sh / stop.sh         # daily
│   ├── attach.sh                  # shell into running container
│   ├── run-ephemeral.sh           # one-off hardened run, --rm on exit
│   ├── auth.sh                    # `claude login` (OAuth)
│   └── verify-sandbox.sh          # runs inside container to confirm hardening
└── devcontainer-template/
    └── devcontainer.json          # copy into target repos for VS Code integration
```

## Drive layout

```
/Volumes/DataDrive/
├── .colima/                       # Colima VM state (COLIMA_HOME)
├── repo/                          # your git repos, mounted at /workspace
└── .claude-colima/
    ├── claude-home/               # ~/.claude (OAuth token, settings.json)
    └── workspace-cache/           # ~/.cache (npm, uv, pip)
```

## First-time setup

```bash
# 1. One-time host setup
scripts/bootstrap.sh
source ~/.zshrc

# 2. Pin the base image digest in Dockerfile
docker pull ubuntu:24.04
DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' ubuntu:24.04 | sed 's/.*@//')
sed -i '' "s/REPLACE_WITH_CURRENT_DIGEST/$DIGEST/" Dockerfile

# 3. Start Colima with persistent mounts (one-time)
scripts/colima-up.sh

# 4. Build the image + start the stack
scripts/start.sh

# 5. Log into Claude (OAuth, once; token persists on the drive)
scripts/auth.sh

# 6. Verify hardening
docker exec -it claude-agent bash /workspace/nranthony/macolima/scripts/verify-sandbox.sh
```

## Daily use

```bash
scripts/start.sh         # bring Colima + stack up
scripts/attach.sh        # shell inside the agent container → run `claude`
scripts/stop.sh          # tear down when done
```

Or for a one-off hardened run that self-destructs:

```bash
scripts/run-ephemeral.sh nranthony/<your-repo> claude
```

## VS Code integration

Either attach to the running container (`Cmd+Shift+P → Dev Containers: Attach to Running Container → claude-agent`), or copy `devcontainer-template/devcontainer.json` into `<target-repo>/.devcontainer/` and use "Reopen in Container".

## Security model

| Layer | Where | Enforcement |
|-------|-------|------|
| Host → VM isolation | Colima (vz) | Apple Virtualization.framework |
| Non-root container user | `Dockerfile` | UID 1000, no sudo |
| Read-only rootfs | `docker-compose.yml` | kernel |
| All capabilities dropped | `docker-compose.yml` | kernel |
| Seccomp syscall filter | `seccomp.json` | kernel |
| Resource limits (cpu/mem/pids) | `docker-compose.yml` | cgroups |
| No direct internet | `docker-compose.yml` | Docker network isolation |
| Egress domain allowlist | `proxy/squid.conf` | Squid proxy sidecar |
| In-process sandbox (bwrap) | `config/claude-settings.json` | bubblewrap (defense-in-depth) |
| Auth token isolation | drive bind mount | filesystem |

The **kernel-level** controls (caps, seccomp, read-only rootfs, proxy) are the real boundary. Claude Code's in-process sandbox is an additional layer, not the primary one.

## Updating

```bash
# Claude Code / image rebuild
docker compose build --no-cache && scripts/stop.sh && scripts/start.sh

# Base image digest (periodic)
docker pull ubuntu:24.04
DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' ubuntu:24.04 | sed 's/.*@//')
sed -i '' "s|ubuntu:24.04@sha256:[a-f0-9]*|ubuntu:24.04@$DIGEST|" Dockerfile
```
