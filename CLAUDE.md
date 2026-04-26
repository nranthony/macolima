# CLAUDE.md — notes for AI agents working on this repo

Invariants, gotchas, and root causes that are **not obvious from the code** but are load-bearing. Read this before editing `docker-compose.yml`, `seccomp.json`, `Dockerfile`, or the proxy config.

## What this repo is

A **multi-profile** hardened sandbox for Claude Code on macOS. Colima VM on `/Volumes/DataDrive`. Each profile is a fully isolated Docker Compose project (`macolima-<profile>`) sharing a single image (`macolima:latest`). Profiles run concurrently, each with its own containers, networks, named volume, and persistent state dir.

**Two script layers:**
- `scripts/setup.sh` — one-shot wrapper: full onboarding (up + claude auth + gh/glab auth + git identity + verify), plus lifecycle actions (`--restart`, `--recreate`, `--remove`, `--reset`, `--verify`). Idempotent: detects existing auth and skips. Users hit this for 90% of operations.
- `scripts/profile.sh` — granular primitives (`up`, `down`, `attach`, per-service `auth`, `exec`). `setup.sh` calls into it. Use directly for one-off ops.

Both set `COMPOSE_PROJECT_NAME=macolima-<profile>` and `PROFILE=<profile>` before invoking `docker compose`. Do not invoke `docker compose` directly; the compose file errors out without `$PROFILE` set.

## Non-negotiable invariants

- **Agent runs as UID 1000 (`agent`)**, never root. `cap_drop: ALL`. `no_new_privs=1`. No sudo. The stock Ubuntu SUID set (`su`, `mount`, `umount`, `passwd`, `chfn`, `chsh`, `gpasswd`, `newgrp`, `unix_chkpwd`, `chage`, `expiry`, `pam_extrausers_chkpwd`, etc.) is present but neutralized by no_new_privs + dropped caps — any SUID binary outside that stock set is drift. **`ssh-agent` and `ssh-keysign` are NOT stock here** — `openssh-client` is deliberately purged (see below), so their presence would be drift.
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

## Running web UIs from the container (Streamlit, Dash, notebooks, dashboards)

**Default path: VS Code Dev Containers port forwarding.** When you're attached, VS Code auto-forwards any listening port over the `docker exec` channel to `localhost:<same-port>` on the Mac. No published ports, no compose edits, no hole in `sandbox-internal`. Two details:

- **Bind to `0.0.0.0` inside the container**, not `127.0.0.1`. Streamlit/Dash default to localhost-only and VS Code's forwarder won't see it.
  - Streamlit: `streamlit run app.py --server.address 0.0.0.0`
  - Dash/Flask: `app.run(host="0.0.0.0")`
  - Jupyter: `jupyter lab --ip 0.0.0.0 --no-browser`
- Port forwarding is per-attachment; after `--recreate` you re-attach and it resumes.

**Fallback for non-VS Code use:** publish a port to loopback only, e.g. add `ports: ["127.0.0.1:8501:8501"]` to the agent service. This is inbound from your own Mac; it does not grant the agent any new outbound capability, so the threat model is unchanged. Never bind `0.0.0.0` on the host side.

Do **not** add `host.docker.internal` to the proxy allowlist so the container can reach Mac services — that's the wrong direction and defeats the sandbox.

## Databases (optional sibling containers)

Postgres and Mongo are defined in `docker-compose.yml` but gated behind compose `profiles:` — they don't start unless you opt in. Each is per-macolima-profile (container name `postgres-<profile>` / `mongo-<profile>`, named volume `macolima-<profile>_postgres-data` / `_mongo-data`). Both sit on `sandbox-internal`, so the agent reaches them at `postgres:5432` / `mongo:27017` by hostname and they have no external reachability.

**Bring up with DBs:**
```bash
COMPOSE_PROFILES=db-postgres         scripts/profile.sh <p> up   # postgres only
COMPOSE_PROFILES=db-mongo            scripts/profile.sh <p> up   # mongo only
COMPOSE_PROFILES=db-postgres,db-mongo scripts/profile.sh <p> up  # both
COMPOSE_PROFILES=db-all              scripts/profile.sh <p> up   # both (alias)
```

**Credentials:** copy `profiles/<p>/db.env.example` to `profiles/<p>/db.env` and fill in. The template is auto-seeded on first `up`. `db.env` is outside the repo and must not be committed.

**Versions:** images are pinned by major (`postgres:18`, `mongo:8`) to match the host Homebrew versions (`postgresql@18`, `mongodb-community`). Bump both together if you upgrade the host.

**Clients baked into the image:** `psql` (via `postgresql-client`) and `mongosh` (via npm) so the agent can connect without installs.

### Why named volumes, not bind mounts
DB data goes into named Docker volumes that live in the Colima VM's ext4. Same rationale as `.vscode-server`: Postgres/Mongo do lots of `fsync`, `rename`, `chmod`, and rely on specific UID ownership (999 for both images) — virtiofs bind mounts from macOS regularly get this wrong and produce permission/initialization errors. If you want the data on the drive for backup/portability, use `pg_dump` / `mongodump` **into `/workspace`** on a schedule — `/workspace` is the one bind mount guaranteed to persist outside the VM.

### Don't connect the sandbox to the host DBs
If you need real data in the sandbox, dump a subset into the sibling container. Allowlisting `host.docker.internal` or attaching the agent to a non-internal network puts a routable path from the agent to services holding real data on your Mac — that's the exact coupling the sandbox exists to prevent.

### GUI access from the Mac (TablePlus, DBeaver, Compass)
Uncomment the `ports:` block on the relevant service (`127.0.0.1:5432:5432` or `127.0.0.1:27017:27017`) and `--recreate`. Loopback-only; never `0.0.0.0`. If you expose Mongo's port, set `MONGO_INITDB_ROOT_*` in `db.env` first — an unauthenticated Mongo on `127.0.0.1` is still reachable by anything running on your Mac.

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

### Squid log/spool tmpfs ownership is split-phase
Squid does some work as root (`/run/squid.pid`, opening `cache.log`) and some as `proxy` user, uid 13 (`access.log`, cache disk). The compose tmpfs mounts reflect this:

| tmpfs | owner/mode | why |
|---|---|---|
| `/var/spool/squid` | `proxy:proxy 0750` | Written only post-drop. |
| `/var/log/squid` | `root:proxy 0775` | `cache.log` opened by root, `access.log` by proxy — both need to write. |
| `/run` | default (root:root) | `/run/squid.pid` created by root. Don't add `uid=13` here or PID write fails. |

If you change any of these, expect crash-loop on next `--force-recreate` (not just restart — tmpfs options only re-apply on recreate). Symptoms map to which phase failed: `Cannot open '...access.log'` = log tmpfs wrong, `failed to open /run/squid.pid` = `/run` was made non-root-writable.

### Squid allowlist: port-restrict non-CONNECT methods
`squid.conf` has `acl Safe_ports port 80 443` + `http_access deny !Safe_ports`. Without that, the `http_access allow allowed_domains` line forwards GET/POST to **any** port on allowed hosts (e.g. `GET http://api.anthropic.com:22/` would be handed off to upstream). The `Safe_ports` restriction stops that and is independent of the CONNECT/`SSL_ports` rule (which only governs HTTPS tunnels). If you ever need a different non-443 port, add it to `Safe_ports`, not just to `allowed_domains.txt`.

### Squid allowlist: avoid wildcards under vendor parents you don't control
Default autonomous-mode allowlist lists specific subdomains (`api.anthropic.com`, `console.anthropic.com`, `statsig.anthropic.com`, `api.claude.com`, `claude.ai`) rather than `.anthropic.com` / `.claude.ai`. Wildcards under a parent are an exfil channel any time a vendor adds a user-controllable subdomain (status pages, marketing, hosted docs). When Claude Code starts hitting a new subdomain, the proxy returns 403 — `docker exec -u proxy egress-proxy-<p> tail -f /var/log/squid/access.log` shows which one to add. `.vscode-unpkg.net` stays a wildcard because the VS Code extension fetcher legitimately rotates across many subdomains under that single MS-controlled parent.

### Squid access log lives on tmpfs as `proxy:proxy 0640`
Forensic trail of every request the agent made through the proxy. Tmpfs-backed, so logs reset on `--force-recreate` of `egress-proxy`. Read it as the proxy user (file is mode 0640, dir is mode 0775):
```bash
docker exec -u proxy egress-proxy-<profile> tail -f /var/log/squid/access.log
```
If you ever need long-term retention, add a second `access_log` directive in `squid.conf` pointing at a host-bind-mounted file (and grant the bind-mount source `proxy` write access).

### tmpfs mounts under `/home/agent/` need `uid=1000,gid=1000`
A bare `tmpfs: - /path:size=N,nosuid,nodev` mount comes up owned by `root:root` mode 755 — it shadows the Dockerfile-created dir. The agent can't write → any tool trying to populate `~/.local/share` or `~/.npm-global` fails with `cannot make directory ... permission denied`. Fix: always append `uid=1000,gid=1000,mode=0755` to tmpfs entries that land inside `/home/agent/`. Applies to `.local` and `.npm-global`; `/tmp` and `/run` are system dirs where root:root is correct.

### `setup.sh` must stay bash 3.2-compatible
macOS ships `/bin/bash` 3.2 and `env bash` often resolves to it. No `;;&` case fall-through, no `mapfile`, no `${var,,}`, no associative arrays. When the `--github` / `--gitlab` / `--both` branch needs shared logic, use a helper function called from multiple case arms — not `;;&`.

### Claude Code's bwrap sandbox is disabled; the container is the boundary
Claude Code's `Bash` tool wraps every command in `bwrap` (bubblewrap). bwrap implements its isolation by calling `unshare(CLONE_NEWUSER)`, which our seccomp filter **correctly blocks** (unprivileged user namespaces are a non-negotiable deny). Result: every Bash call fails with `bwrap: No permissions to create new namespace` before the command runs. Two sandboxes with incompatible mechanisms; the container is the stronger outer boundary.

Three consequences, all load-bearing:

1. **`sandbox.enabled: false`** in `~/.claude/settings.json` — Claude Code uses unsandboxed execution.
2. **`bubblewrap`, `socat`, and `openssh-client` are NOT installed** in the Dockerfile. Each was either dead weight or an exfil path:
   - `bubblewrap` only supported the in-process sandbox (now disabled).
   - `socat` was a raw-TCP exfil channel bypassing the HTTP-only Squid egress.
   - `openssh-client` (`ssh`/`scp`/`sftp`/`ssh-agent`/...) is the tool surface that weaponizes VS Code's `SSH_AUTH_SOCK` forwarding. Removing the package physically closes the SSH exfil path. **There is no host-side VS Code setting that disables Dev Containers' SSH agent forwarding** — `remote.SSH.enableAgentForwarding` only governs the separate Remote-SSH extension. The actual env-level mitigation lives in `devcontainer.json` (`remoteEnv: { SSH_AUTH_SOCK: "" }`) plus a defense-in-depth `unset SSH_AUTH_SOCK` baked into `config/.zshrc`. With `openssh-client` gone the socket is unusable regardless. No legitimate agent workflow needs SSH: gh/glab use HTTPS tokens, git remotes are HTTPS, and agent-mode already denies `git push|clone|fetch`.
3. **`config/claude-settings.json`** is the per-profile settings template. `ensure_state()` in `profile.sh` copies it into `profiles/<p>/claude-home/settings.json` on first `up` (only if the file is absent — existing profiles keep customizations). Persists across `--recreate` via the bind mount.

### Per-profile Claude Code skills are seeded from `config/skills/`
Skills live at `config/skills/<name>/SKILL.md` in the repo and are seeded into each profile's `claude-home/skills/<name>/` by `ensure_state()` on first `up` — same pattern as `claude-settings.json`: copy only if absent, so user customisations to a skill survive subsequent `up`s. To force-refresh from template (e.g. after editing a SKILL.md upstream), use `scripts/profile.sh <p> reset-skills` — it backs up the existing skill dir to `<name>.bak.<stamp>/` before replacing. `clean --deep` sweeps those backups.

The shipped skill is `audit-sandbox`. It wraps the in-container security audit (`claude_internal_audit.md`): the agent reads the staged audit prompt and writes report + replayable command log to `~/.claude/audits/`. Invocation inside the container: `/audit-sandbox`. Prerequisite: the host has run `scripts/stage-audit-package.sh <profile>` first (the skill aborts with a clear message if `/workspace/temp_audit_package/` isn't present). When updating `claude_internal_audit.md`, no skill change is needed — the skill points at the staged file rather than duplicating it.

Do **not** "re-harden" by re-enabling `sandbox.enabled` or re-adding `bubblewrap`/`socat`/`openssh-client` to the image. bwrap's threat model protects a real host filesystem from a rogue command; there is no reachable host filesystem from inside this container. Existing profiles whose `settings.json` predates this template need the keys added manually once.

### Permissions posture: plan interactively, execute autonomously
The agent's permission posture and the proxy's egress allowlist are designed around a two-phase workflow:

- **Planning runs** (you're driving, approving each step): uncomment the planning-mode section in `proxy/allowed_domains.txt` (github/pypi/npm/nodejs), restart Squid, do clones/installs/pushes yourself. `permissions.defaultMode: "acceptEdits"` means Edit/Write auto-apply, Bash is prompt-gated.
- **Autonomous runs** (agent driving): re-comment the planning-mode domains, restart Squid. The agent's allow list covers routine read-only and non-destructive Bash; its deny list blocks network tools (`curl`, `wget`, `ssh`, `scp`, `rsync`, `git push/clone/fetch`, `gh`, `glab`), package installers (`pip`, `npm`, `uv`, `pipx`, `cargo`, `go install`), and shell-escape patterns (`bash -c`, `python -c`, `node -e`, `uv run bash`, `perl`, `ruby`, `lua`, `env`, `xargs`). Web search still works because `WebSearch`/`WebFetch` execute server-side on Anthropic's infra, not through the container's network.

The deny list is **defense in depth, not the security boundary**. Claude Code's permission matcher keys on the command prefix, so denies can be routed around by wrapper idioms that are hard to enumerate exhaustively — e.g. `find . -exec …`, `make` targets, `npm run` scripts, and `<interpreter> /tmp/script.<ext>` all run arbitrary code and can't be denied without breaking the tool's normal use. When the deny list misses, the real boundary still holds: the egress proxy (domain + port allowlist), seccomp (no user namespaces → no in-container bwrap/nsenter), non-root + `cap_drop: ALL`.

The discipline: **if the agent says it needs a new package or a fresh clone, that's a planning-phase signal** — exit autonomous mode, you do it yourself, resume. Don't widen the agent's permissions to cover one-off installs; widen them only for patterns you'll keep seeing.

Reload Squid after toggling the allowlist:
```bash
PROFILE=<p> COMPOSE_PROJECT_NAME=macolima-<p> docker compose restart egress-proxy
```

### Colima VM delete wipes mount + resource config — always use `scripts/colima-up.sh`
`colima delete` does what it says — it wipes the VM and Colima's persisted config for it. A subsequent bare `colima start` creates a fresh VM with **2 CPU / 2 GB RAM / 60 GB disk / no host mounts**, because none of the flags you passed originally are remembered across a delete. That immediately breaks this stack in two ways:

1. **CPU limit error on container start**: `range of CPUs is from 0.01 to 2.00`. The compose file asks for `cpus: 4`, the fresh VM only has 2 → Docker refuses to schedule. You'll see this during `rebuild` or `up`.
2. **Bind-mount error on container start**: `error mounting ".../proxy/squid.conf" to rootfs at "/etc/squid/squid.conf": not a directory: Are you trying to mount a directory onto a file (or vice-versa)?` — the source path isn't visible inside the VM because the `/Volumes/DataDrive` virtiofs mount is gone. The Docker daemon inside the VM then auto-creates the missing source as a directory and tries to mount that dir onto `/etc/squid/squid.conf` (which is a file in the Squid image), hence the error.

Fix: **always use `scripts/colima-up.sh` after a delete**, never bare `colima start`. The wrapper encodes the required flags (`--cpu 6 --memory 10 --disk 80 --mount-type virtiofs --mount /Volumes/DataDrive/repo:w --mount /Volumes/DataDrive/.claude-colima:w`). Those persist into `colima.yaml` so subsequent stop/start cycles without flags work — until the next delete.

If you need to sanity-check mounts after a VM start:
```bash
colima ssh -- ls /Volumes/DataDrive/repo/nranthony/macolima/proxy/squid.conf
```
Should print the path. If it errors, the mount didn't land; re-run `scripts/colima-up.sh`.

External disks live under `_lima/_disks/<name>/datadisk` (separate from the profile dir — Lima's external-disk feature). `colima delete` doesn't always remove them, which is why `--disk N` can produce a "disk size cannot be reduced" WARN; it's cosmetic. To truly reset disk size, stop Colima and `rm -rf` the `_disks/colima/` subdir before starting.

### VS Code Dev Containers leakage hardening
VS Code's Dev Containers extension injects several host→container forwards by default that **bypass the sandbox network identity**: `SSH_AUTH_SOCK` + the underlying `/tmp/vscode-ssh-auth-*.sock`, the host `.gitconfig` copied into the rootfs overlay, and an IPC-backed `git-credential-helper` shim wired into `~/.config/git/config`. Hardening lives in three layers (container, repo, host); the tripwire (`verify-sandbox.sh`) checks all four leakage items.

1. **In-container** (Dockerfile + `config/.zshrc`):
   - `openssh-client` is purged. Closes the SSH exfil path at the tool level: even if the env var + socket leak in, no `ssh`/`scp`/`ssh-add` exists to use them.
   - `config/.zshrc` runs `unset SSH_AUTH_SOCK` so any interactive shell (including `docker exec` paths that bypass `devcontainer.json`'s `remoteEnv`) starts with the env cleared. Defense-in-depth on top of the per-repo fix.
2. **Per-repo** (`.devcontainer/devcontainer.json` — see `devcontainer-template/devcontainer.json` for the canonical copy). Each workspace that gets attached should have one. Required keys:
   - `"remoteUser": "agent"`, `"containerUser": "agent"` — match the Dockerfile USER.
   - `"updateRemoteUserUID": false` — critical. Without this, VS Code runs `usermod` as root during attach to align UIDs, which spawns a root shell that sometimes orphans (the "stray UID-0 process" drift seen in the pre-hardening audit). `"overrideCommand": false` — keep compose's `sleep infinity` as PID 1.
   - `"remoteEnv": { "SSH_AUTH_SOCK": "" }` — the actual fix for SSH-agent injection. The Dev Containers extension has **no settings-level disable** for SSH agent forwarding; `remote.SSH.enableAgentForwarding` only governs the unrelated Remote-SSH extension. `remoteEnv` runs *after* VS Code's auto-injection and overrides the env. The socket file in `/tmp/` may still appear (cosmetic) but the env is empty so nothing references it.
   - Workspace-scoped fallback for git-config copy + credential helper, under `customizations.vscode.settings` (NOT a top-level `settings` key — that location was deprecated and is silently ignored, which masked H2-style drift in the 2026-04-25 audit until we noticed):
     ```jsonc
     "customizations": { "vscode": { "settings": {
       "dev.containers.copyGitConfig": false,
       "dev.containers.gitCredentialHelperConfigLocation": "none"
     } } }
     ```
3. **Host VS Code settings** (`~/Library/Application Support/Code/User/settings.json` on macOS) — these are the primary defense for the git-config and credential-helper paths; the workspace-scoped block above is belt-and-braces:
   - `"dev.containers.copyGitConfig": false` — blocks the host `.gitconfig` copy into the rootfs overlay.
   - `"dev.containers.gitCredentialHelperConfigLocation": "none"` — blocks the IPC-backed credential helper shim. **Separate setting** from `copyGitConfig`; disabling `copyGitConfig` alone is not sufficient (the 2026-04-25 audit caught the helper still being injected because we hadn't set this one).
   - `"remote.SSH.enableAgentForwarding": false` — fine to set, but **does not affect Dev Containers attach**. It only governs Remote-SSH chained connections. Don't rely on it for sandbox hardening.

**`ensure_state()` defensive scrub**: on every `up`, `profile.sh` scans `profiles/<p>/config/git/config` for helpers whose value matches any of `vscode-server | vscode-remote-containers | osxkeychain | git-credential-manager` and strips only those lines. Note: VS Code re-injects the helper *on every attach*, *after* `ensure_state()` has already run — so the scrub is correct in design but is a stale defense within an attach session. The host setting (`gitCredentialHelperConfigLocation: "none"`) is what actually prevents re-injection. **The scrub intentionally preserves `!/usr/local/bin/glab auth git-credential` and `!/usr/local/bin/gh auth git-credential`** — those are the legitimate in-container helpers installed by `glab auth setup-git` / `gh auth setup-git`, which use in-container tokens from `~/.config/{glab-cli,gh}/` and have no host reach. Do not broaden the scrub to "any helper" — that would break authenticated `git push`.

`verify-sandbox.sh`'s credential helper tripwire uses the same host-reaching patterns, so benign glab/gh helpers PASS.

**`VSCODE_GIT_ASKPASS_*` envs** (informational): the same VS Code attach mechanism that injects the credential helper also exports `GIT_ASKPASS`, `VSCODE_GIT_ASKPASS_NODE`, `VSCODE_GIT_ASKPASS_MAIN`, `VSCODE_GIT_IPC_HANDLE`. They route `git` HTTPS auth prompts through the host VS Code UI for credential entry. With autonomous mode's `git push|clone|fetch|pull` denies these are dormant; in planning mode they become a host-reaching prompt path. **Don't paste a host credential into a container `git` prompt** — VS Code will happily relay it.

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

### Postgres 18+ wants the mount at `/var/lib/postgresql`, not `.../data`
Starting in pg 18 the image manages a major-version subdirectory (`18/docker/`) inside `/var/lib/postgresql` to support `pg_upgrade --link` across major bumps without mount-point boundary issues. Mounting the old `/var/lib/postgresql/data` path makes the entrypoint refuse to start with a long "unused mount/volume" error and the container crash-loops. Keep the compose mount as `postgres-data:/var/lib/postgresql:rw`. If you ever rebuild a volume that was initialized under the old path, wipe it (`docker volume rm macolima-<p>_postgres-data`) before the next `up`.

### Agent currently holds DB admin creds — TODO: least-privilege split
`db.env` injects `POSTGRES_USER`/`POSTGRES_PASSWORD` and `MONGO_INITDB_ROOT_*` into the `claude-agent` container as ambient env. That's the DB **superuser**, so the agent can DROP tables/databases/collections. This is fine for throwaway dev DBs but wrong for anything holding real data. Planned fix: an `initdb.d` script (pg) / `mongo-init.js` (mongo) that creates a second role — `agent_rw` with CRUD-only grants on the app schema — and the agent gets only that role's creds in its env. Admin creds stay in `db.env` for container init but never reach the agent. Not yet implemented; revisit before putting anything load-bearing in these DBs.

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

# Blank-slate a profile but KEEP auth (claude creds + claude.json + gh + glab + git identity).
# Tears down containers, drops vscode-server volume, nukes everything else under
# profiles/<p>/ except the auth files, then re-seeds settings.json + skills from
# config/. DB volumes (postgres-data/mongo-data) are preserved unless you pass
# --all-volumes. Confirms first; --dry-run prints the plan, --yes skips the prompt.
scripts/profile.sh <p> wipe --dry-run
scripts/profile.sh <p> wipe                    # interactive (type profile name to confirm)
scripts/profile.sh <p> wipe --yes              # non-interactive
scripts/profile.sh <p> wipe --all-volumes      # also drop postgres/mongo named volumes

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

# Inside-container hardening sweep — stage the audit package first so the
# script is available inside the container (it's not in /workspace otherwise)
scripts/stage-audit-package.sh <p>
scripts/profile.sh <p> exec bash /workspace/temp_audit_package/scripts/verify-sandbox.sh

# Trivy scan (host-side, requires `brew install trivy`) — config + secret + image
scripts/trivy-scan.sh                    # all three (default)
scripts/trivy-scan.sh config             # Dockerfile/compose misconfig only
scripts/trivy-scan.sh image              # CVE scan of macolima:latest
scripts/trivy-scan.sh 2>&1 | tee /tmp/trivy-$(date +%Y%m%d).log  # keep a record

# Stage sandbox config into a profile workspace for an in-container audit
scripts/stage-audit-package.sh <p>              # stage /workspace/temp_audit_package/
scripts/stage-audit-package.sh <p> --clean      # remove when done
```

Accepted CVEs/misconfigs live in `.trivyignore.yaml` with dated `expired_at` fields — on each expiry, re-run Trivy, and either delete the entry (upstream fixed it) or extend the date with a refreshed statement.

## What NOT to do

- Don't `docker compose` directly without `PROFILE` set — use `scripts/profile.sh`.
- Don't add `read_only: true` to the agent container.
- Don't mount `.vscode-server` as a drive bind mount.
- Don't add broad wildcards (`*.microsoft.com`, `.anthropic.com`) to the proxy allowlist — pin to specific subdomains. Sole exception: `.vscode-unpkg.net` (vendor-controlled CDN that legitimately rotates subdomains).
- Don't share the same profile dir between two profiles via symlinks "to save space" — the whole point is isolation.
- Don't commit secrets from `profiles/<name>/` into git — that dir is user state, not repo content. It lives on the drive, outside this repo.
- Don't chmod `.claude/.credentials.json` to anything other than 600.
