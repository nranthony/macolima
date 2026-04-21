# CLAUDE.md — notes for AI agents working on this repo

Invariants, gotchas, and root causes that are **not obvious from the code** but are load-bearing. Read this before editing `docker-compose.yml`, `seccomp.json`, `Dockerfile`, or the proxy config.

## What this repo is

A **multi-profile** hardened sandbox for Claude Code on macOS. Colima VM on `/Volumes/DataDrive`. Each profile is a fully isolated Docker Compose project (`macolima-<profile>`) sharing a single image (`macolima:latest`). Profiles run concurrently, each with its own containers, networks, named volume, and persistent state dir.

**Two script layers:**
- `scripts/setup.sh` — one-shot wrapper: full onboarding (up + claude auth + gh/glab auth + git identity + verify), plus lifecycle actions (`--restart`, `--recreate`, `--remove`, `--reset`, `--verify`). Idempotent: detects existing auth and skips. Users hit this for 90% of operations.
- `scripts/profile.sh` — granular primitives (`up`, `down`, `attach`, per-service `auth`, `exec`). `setup.sh` calls into it. Use directly for one-off ops.

Both set `COMPOSE_PROJECT_NAME=macolima-<profile>` and `PROFILE=<profile>` before invoking `docker compose`. Do not invoke `docker compose` directly; the compose file errors out without `$PROFILE` set.

## Non-negotiable invariants

- **Agent runs as UID 1000 (`agent`)**, never root. `cap_drop: ALL`. No sudo. No suid binaries.
- **Agent has no direct network.** `sandbox-internal` is `internal: true`. Only reachable host is `egress-proxy`.
- **Proxy-allowed domains live in `proxy/allowed_domains.txt`.** Shared across profiles. Change → `COMPOSE_PROJECT_NAME=macolima-<p> PROFILE=<p> docker compose restart egress-proxy` (no rebuild).
- **Base image is digest-pinned** (`FROM ubuntu:24.04@sha256:...`). Don't replace with a tag.
- **Seccomp is applied at runtime** (`security_opt: seccomp=./seccomp.json`), not baked into the image. Changes take effect on `--force-recreate`, no rebuild.
- **All mount points under `/home/agent/...` must be pre-created in the `Dockerfile`** with `chown agent:agent`. This includes directories that become named volumes or bind mounts.

## Persistence map per profile

Everything outside these paths is **wiped on container recreate**:

| Container path | Host path | Notes |
|---|---|---|
| `/workspace` | `/Volumes/DataDrive/repo/<profile>` | Must exist before `up`; `profile.sh` validates. |
| `/home/agent/.claude/` | `/V/.../profiles/<profile>/claude-home/` | Tokens, sessions, MCP, projects |
| `/home/agent/.claude.json` | `/V/.../profiles/<profile>/claude.json` | **Single file, chmod 644, must contain `{}` (not empty).** Missing → login prompt every recreate; empty → JSON parse error. |
| `/home/agent/.cache/` | `/V/.../profiles/<profile>/cache/` | npm/uv/pip caches |
| `/home/agent/.config/` | `/V/.../profiles/<profile>/config/` | Holds `gh/`, `glab-cli/`, and `git/config` (git global config, via `GIT_CONFIG_GLOBAL`) |
| `/home/agent/.vscode-server/` | named volume `vscode-server` (per project) | **Must be named volume.** |

Volatile (tmpfs): `/tmp`, `/run`, `/home/agent/.npm-global`, `/home/agent/.local`.

The named volume becomes `macolima-<profile>_vscode-server` — separate per profile, as intended.

## Gotchas with root causes

### Profiles use `COMPOSE_PROJECT_NAME` for isolation
Different project names = different network suffixes (`macolima-work_sandbox-internal` vs `macolima-personal_sandbox-internal`), different volume suffixes, different default container names. `container_name:` fields in the compose file include `${PROFILE}` explicitly so `docker exec claude-agent-work` works directly. Do **not** remove the `${PROFILE}` suffix from `container_name` or two concurrent profiles will collide on Docker's global container-name namespace.

### `PROFILE:?...` compose guard
The compose file uses `${PROFILE:?PROFILE env var required — use scripts/profile.sh}` so any direct `docker compose` invocation without `PROFILE` exported fails fast with a clear message. Keep this.

### Rootfs is NOT read-only
`read_only: true` was tried and removed on the agent container. It breaks VS Code Dev Containers' `/etc/environment` patching with no security gain (non-root + `cap_drop: ALL` already blocks system-dir writes). Stays on `egress-proxy` because Squid doesn't need rootfs writes.

### `.vscode-server` must be a named volume
Virtiofs on macOS mis-handles `utime()` during tar extraction of the VS Code server tarball (`tar: Cannot utime: Operation not permitted`). Fix: named Docker volume (`vscode-server:/home/agent/.vscode-server`) — lives in the VM's ext4, bypasses virtiofs.

Any dir that becomes a named-volume mount point must be **pre-created in the Dockerfile** with `chown agent:agent`, or the volume initializes root-owned and the agent can't write.

### `.claude.json` single-file bind mount needs chmod 644 AND valid JSON
Single-file bind mounts on Colima virtiofs don't remap UIDs the same way directory mounts do. A 600 file on the host appears as `root:root 600` inside the container → agent can't read. 644 → appears as `agent:agent 644`.

The file also must contain **valid JSON** — Claude rejects 0-byte files with `JSON Parse error: Unexpected EOF` and forces a reset prompt. `profile.sh`'s `ensure_state()` seeds `{}\n` with chmod 644 on first use (and re-seeds if the file is 0 bytes, so older broken profiles self-heal on next `up`).

`.credentials.json` inside `.claude/` stays 600 — it's inside a *directory* bind mount, which uses the directory-mount UID remapping path that works correctly.

### Why `.gitconfig` is NOT bind-mounted — use `GIT_CONFIG_GLOBAL` instead
Bind-mounting `~/.gitconfig` as a single file fails with `Device or resource busy` on any `git config --global` write. Root cause: `git config` writes atomically via `rename()` of a temp file over the target. `rename()` can't cross a single-file bind-mount boundary on virtiofs → EBUSY. `gh auth setup-git` hits this too.

Fix: don't mount `.gitconfig` at all. Instead set `GIT_CONFIG_GLOBAL=/home/agent/.config/git/config` in the compose env, and mount the whole `.config/` **directory**. `rename()` within a directory-mounted filesystem works fine. `profile.sh`'s `ensure_state()` pre-creates `.config/git/` so the target dir exists.

Do not "simplify" this by re-adding a `.gitconfig` bind mount — it will silently break `gh auth login` and any other tool that touches git config.

### seccomp: syscalls that must stay in the allowlist

| Syscall | Needed by | Symptom if missing |
|---|---|---|
| `getpgid` | bash job control (glibc `getpgrp()` → `getpgid` syscall) | `bash: initialize_job_control: getpgrp failed: Operation not permitted` |
| `rseq` | glibc thread init | random silent stalls in multithreaded binaries |
| `pidfd_open`, `pidfd_send_signal`, `pidfd_getfd` | modern process mgmt | node/zsh subprocess errors |
| `close_range` | Go/C++ runtimes closing inherited FDs | process startup errors |
| `mknod`, `mknodat` | mkfifo (named pipes) for gitstatusd | p10k "gitstatus failed to initialize" |
| xattr family (`getxattr`, `setxattr`, `lgetxattr`, `fgetxattr`, `removexattr`, `listxattr`, and `l*`/`f*` variants) | tar extraction, apt | silent failures |

### clone3 must return ENOSYS (38), not EPERM
`clone3` takes a struct-pointer arg that seccomp can't inspect, so we can't enforce `!CLONE_NEWUSER` on it. We return `ENOSYS` so glibc falls back to `clone()` (which IS filtered). Any other errno → glibc won't fall back, threading breaks.

### Squid needs SETUID + SETGID caps
Squid starts as root then drops to the `proxy` user — needs `SETUID`/`SETGID`. Without them: crash-loop exit 134. `NET_BIND_SERVICE` NOT needed (port 3128 is unprivileged). Also `pinger_enable off` in `squid.conf` — ICMP pinger wants `CAP_NET_RAW` we don't grant.

### tmpfs mounts under `/home/agent/` need `uid=1000,gid=1000`
A bare `tmpfs: - /path:size=N,nosuid,nodev` mount comes up owned by `root:root` mode 755 — it shadows the Dockerfile-created dir. The agent can't write → any tool trying to populate `~/.local/share` or `~/.npm-global` fails with `cannot make directory ... permission denied`. Fix: always append `uid=1000,gid=1000,mode=0755` to tmpfs entries that land inside `/home/agent/`. Applies to `.local` and `.npm-global`; `/tmp` and `/run` are system dirs where root:root is correct.

### `setup.sh` must stay bash 3.2-compatible
macOS ships `/bin/bash` 3.2 and `env bash` often resolves to it. No `;;&` case fall-through, no `mapfile`, no `${var,,}`, no associative arrays. When the `--github` / `--gitlab` / `--both` branch needs shared logic, use a helper function called from multiple case arms — not `;;&`.

### Ubuntu 24.04 default `ubuntu` user at UID 1000
Dockerfile does `userdel -r ubuntu 2>/dev/null || true` before creating `agent` at UID 1000. Don't remove that line.

### VS Code re-attach after container recreate
`docker compose up -d --force-recreate` changes the container ID. VS Code Dev Containers caches attachment by ID. After recreate, user must: `Remote: Close Remote Connection` → re-attach, or reload window, or relaunch VS Code.

### gh/glab binaries and the proxy
`gh` and `glab` are installed at build time (direct internet via host daemon). At runtime they go through Squid. `gh auth login` uses `github.com` + `api.github.com` — both match the `.github.com` wildcard. `glab` uses `gitlab.com` — covered by `.gitlab.com`. For self-hosted GitLab, the hostname must be added to `allowed_domains.txt` before auth.

### OAuth browser flow is broken in both gh and glab — use token flow
Both `gh auth login` and `glab auth login` default to an OAuth browser callback on `http://localhost:<port>` inside the container. The host browser can't reach that port: `sandbox-internal` is `internal: true` with no published ports, by design. User sees "this site can't be reached" on the redirect. Always pick **"Paste an authentication token"** at the prompt. Required scopes:
- gh: `repo`, `read:org`, `workflow` (or fine-grained equivalents)
- glab: `api` + `write_repository`

### gh/glab tokens live in `~/.config/`, not `~/.claude/`
That's why the compose file mounts `/home/agent/.config` as a per-profile bind (`profiles/<profile>/config`). Without it, tokens wipe on every recreate. The directory is pre-created in the Dockerfile.

## Editing checklist

Before committing:

- [ ] New `/home/agent/...` mount point? Pre-create it in `Dockerfile` + `chown agent:agent`.
- [ ] New seccomp allowance? Document the syscall and why in the comment above the `names` array.
- [ ] New allowed domain? Justify with a one-line comment above its block.
- [ ] Compose change? Run `PROFILE=_test docker compose config` to validate YAML interpolation.
- [ ] Dockerfile / `.zshrc` / `.p10k.zsh` change? Need rebuild: `scripts/profile.sh build`, then `scripts/profile.sh <p> rebuild` per running profile.

## Debug recipes

```bash
# One-shot verify (auth status for claude/gh/glab + git identity + compose ps)
scripts/setup.sh <p> --verify

# Force recreate (covers compose/seccomp/mount changes) via wrapper
scripts/setup.sh <p> --recreate

# Full rebuild + recreate (covers Dockerfile changes)
scripts/profile.sh <p> rebuild

# Recreate only (covers seccomp / mounts / env / squid.conf changes)
PROFILE=<p> COMPOSE_PROJECT_NAME=macolima-<p> docker compose up -d --force-recreate

# Proxy reload (covers allowed_domains.txt) — per profile
PROFILE=<p> COMPOSE_PROJECT_NAME=macolima-<p> docker compose restart egress-proxy

# Probe gitstatusd / zsh init with a TTY
docker exec -t claude-agent-<p> zsh -ic 'echo ok'

# Enable p10k debug logs: add `export GITSTATUS_LOG_LEVEL=DEBUG` to config/.zshrc, rebuild
docker exec claude-agent-<p> sh -c 'cat /tmp/gitstatus.*.log'

# Verify a domain reaches through the proxy
scripts/profile.sh <p> exec curl -sI https://<host>/ -o /dev/null -w '%{http_code}\n'

# Inside-container hardening sweep
scripts/profile.sh <p> exec bash /workspace/<any>/macolima/scripts/verify-sandbox.sh
```

## What NOT to do

- Don't `docker compose` directly without `PROFILE` set — use `scripts/profile.sh`.
- Don't add `read_only: true` to the agent container.
- Don't mount `.vscode-server` as a drive bind mount.
- Don't add broad wildcards (`*.microsoft.com`) to the proxy allowlist — pin to specific services.
- Don't share the same profile dir between two profiles via symlinks "to save space" — the whole point is isolation.
- Don't commit secrets from `profiles/<name>/` into git — that dir is user state, not repo content. It lives on the drive, outside this repo.
- Don't chmod `.claude/.credentials.json` to anything other than 600.
