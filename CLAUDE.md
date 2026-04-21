# CLAUDE.md — notes for AI agents working on this repo

This file captures invariants, gotchas, and root causes that are **not obvious from the code** but are load-bearing. Read this before editing `docker-compose.yml`, `seccomp.json`, `Dockerfile`, or the proxy config.

## What this repo is

A hardened macOS sandbox for running Claude Code in auto mode. Colima VM on `/Volumes/DataDrive`, Docker stack with `claude-agent` + `egress-proxy` sidecar, agent on an `internal: true` network so **all outbound traffic is forced through Squid** with a domain allowlist.

## Non-negotiable invariants

- **Agent runs as UID 1000 (`agent`)**, never root. `cap_drop: ALL`. No sudo. No suid binaries.
- **Agent has no direct network.** `sandbox-internal` is `internal: true`. The only reachable host is `egress-proxy`. If you route traffic around the proxy you've broken the security model.
- **All proxy-allowed domains live in `proxy/allowed_domains.txt`.** Never hardcode in source. Change → `docker compose restart egress-proxy` (no rebuild).
- **Base image is digest-pinned** (`FROM ubuntu:24.04@sha256:...`). Don't replace with a tag.
- **Seccomp is applied at runtime** (`security_opt: seccomp=./seccomp.json`), not baked into the image. Changes take effect on `--force-recreate`, no rebuild needed.

## Persistence map (memorize this)

Everything outside these paths is **wiped on container recreate**:

| Container path | Host path | Notes |
|---|---|---|
| `/workspace` | `/Volumes/DataDrive/repo` | repos; bind mount |
| `/home/agent/.claude/` | `/Volumes/DataDrive/.claude-colima/claude-home/` | tokens, sessions, settings |
| `/home/agent/.claude.json` | `/Volumes/DataDrive/.claude-colima/claude.json` | **single-file bind mount**; holds `oauthAccount`. Missing this = login prompt every recreate |
| `/home/agent/.cache/` | `/Volumes/DataDrive/.claude-colima/workspace-cache/` | npm/uv/pip caches |
| `/home/agent/.vscode-server/` | named volume `vscode-server` | **must be named volume, not bind mount** (see below) |

Volatile (tmpfs): `/tmp`, `/run`, `/home/agent/.npm-global`, `/home/agent/.local`.

## Gotchas with root causes

### Rootfs is NOT read-only
`docker-compose.yml` does **not** set `read_only: true` on `claude-agent`. This was tried and removed — VS Code Dev Containers patches `/etc/environment` and `/etc/profile` on first attach, which fails under a read-only rootfs. Dropping it has no security cost: a non-root user with `cap_drop: ALL` already cannot write to system dirs (file permissions do the job). `read_only: true` stays on `egress-proxy` because Squid doesn't need to write there.

### `.vscode-server` must be a named volume
Virtiofs on macOS (Colima's file-sharing for bind mounts) mis-handles `utime()` during tar extraction of the VS Code server tarball. Error: `tar: Cannot utime: Operation not permitted`. Fix: use a Docker named volume (`vscode-server:/home/agent/.vscode-server`), which lives inside the VM's ext4 and bypasses virtiofs.

Corollary: any directory that will be mounted as a named volume must be **pre-created in the Dockerfile with `chown agent:agent`**, otherwise the volume initializes with root ownership and the agent user can't write. See the `mkdir -p ... /home/agent/.vscode-server && chown` line in `Dockerfile`.

### `.claude.json` bind mount needs chmod 644
Single-file bind mounts on Colima virtiofs don't remap UIDs the same way directory mounts do. A 600 file on the host appears as `root:root 600` inside the container → agent can't read it. 644 → appears as `agent:agent 644`. The file contains email/userId (not tokens — those are in `.credentials.json` inside `.claude/`), so 644 is acceptable.

### seccomp: syscalls that must stay in the allowlist
Discovered the hard way. If any of these go missing, diagnose by setting `defaultAction` temporarily to `SCMP_ACT_LOG` (needs audit), or by process of elimination.

| Syscall | Needed by | Symptom if missing |
|---|---|---|
| `getpgid` | bash job control (modern glibc implements `getpgrp()` via `getpgid` syscall) | `bash: initialize_job_control: getpgrp failed: Operation not permitted` |
| `rseq` | glibc thread init | random silent stalls in multithreaded binaries |
| `pidfd_open`, `pidfd_send_signal`, `pidfd_getfd` | modern process mgmt | node/zsh subprocess errors |
| `close_range` | Go/C++ runtimes closing inherited FDs | process startup errors |
| `mknod`, `mknodat` | mkfifo (named pipes) for gitstatusd, IPC | `mkfifo: Operation not permitted` → p10k "gitstatus failed to initialize" |
| xattr family (`getxattr`, `setxattr`, `lgetxattr`, `fgetxattr`, `removexattr`, `listxattr`, and `l*`/`f*` variants) | tar extraction, apt | silent failures / extraction errors |

### clone3 must return ENOSYS, not EPERM
`clone3` takes a struct pointer whose contents seccomp can't inspect, so we can't enforce the `!CLONE_NEWUSER` rule on it. Instead we return `ENOSYS` (errnoRet 38) so glibc falls back to `clone()`, which IS filtered. If you change this to `SCMP_ACT_ERRNO` with any other errno, glibc won't fall back and threading breaks.

```json
{ "names": ["clone3"], "action": "SCMP_ACT_ERRNO", "errnoRet": 38 }
```

### Squid needs SETUID + SETGID
`egress-proxy` is `cap_drop: ALL` by default. Squid starts as root then drops to the `proxy` user — which needs `SETUID` and `SETGID`. Without these, Squid crash-loops with exit 134. `NET_BIND_SERVICE` is NOT needed (port 3128 is unprivileged).

Also: `pinger_enable off` in `squid.conf`. Squid's ICMP pinger wants `CAP_NET_RAW` which we don't grant, and there are no cache peers to measure anyway.

### glibc default user in ubuntu:24.04
Ubuntu 24.04 ships with a default `ubuntu` user at UID 1000. The Dockerfile does `userdel -r ubuntu 2>/dev/null || true` before creating `agent` at UID 1000. Don't remove that line.

### VS Code re-attach after container recreate
`docker compose up -d --force-recreate claude-agent` changes the container ID. VS Code Dev Containers caches the attachment by ID. After a recreate, the VS Code Dev Container session is stale and won't pick up new seccomp/mount changes. User must: `Remote: Close Remote Connection` → re-attach, or reload the window.

## Editing checklist

Before you commit changes:

- [ ] If you added a mount point under `/home/agent/...`, did you also pre-create it in `Dockerfile` with `chown agent:agent`?
- [ ] If you relaxed seccomp, did you document the syscall and why in the `_blocked_dangerous_syscalls_explanation` section OR the comment above the `names` array?
- [ ] If you added a domain to `allowed_domains.txt`, did you justify it (which package/service, one-line comment above the block)?
- [ ] If you changed `docker-compose.yml`, run `docker compose config` to validate YAML before bringing the stack up.
- [ ] Did you change anything that requires a rebuild (`Dockerfile`, `config/.zshrc`, `config/.p10k.zsh`)? If so, `docker compose build claude-agent` is needed, not just `--force-recreate`.

## Debug recipes

```bash
# Rebuild + recreate (covers Dockerfile and config changes)
docker compose build claude-agent && docker compose up -d --force-recreate claude-agent

# Recreate only (covers seccomp, mounts, env, squid.conf changes)
docker compose up -d --force-recreate claude-agent

# Proxy-only reload (covers allowed_domains.txt)
docker compose restart egress-proxy

# Probe gitstatusd / zsh init with a TTY (matches what VS Code terminal sees)
docker exec -t claude-agent zsh -ic 'echo ok'

# Enable p10k debug logs
# Add `export GITSTATUS_LOG_LEVEL=DEBUG` to config/.zshrc, rebuild, open a terminal
docker exec claude-agent sh -c 'cat /tmp/gitstatus.*.log'

# Verify a domain is allowed by the proxy
docker exec claude-agent curl -sI https://<host>/ -o /dev/null -w '%{http_code}\n'

# Inside-container hardening sweep
docker exec -it claude-agent bash /workspace/nranthony/macolima/scripts/verify-sandbox.sh
```

## What NOT to do

- Don't add `read_only: true` to the agent container (see above).
- Don't mount `.vscode-server` as a drive bind mount.
- Don't add broad wildcards (`*.microsoft.com`, `*.visualstudio.com`) to the proxy allowlist — pin to specific services.
- Don't install packages at runtime inside the container if they can be baked into the Dockerfile (rootfs is writable for Dev Containers, but everything under `/home/agent` outside the mounts disappears on recreate).
- Don't chmod `.claude/.credentials.json` to anything other than 600.
