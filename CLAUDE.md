# CLAUDE.md — notes for AI agents working on this repo

Invariants, gotchas, and root causes that are **not obvious from the code** but are load-bearing. Read this before editing `docker-compose.yml`, `seccomp.json`, `Dockerfile`, or the proxy config.

User-facing usage (onboarding, DBs, web UIs, auth, host VS Code settings) lives in `README.md`. Root-cause deep dives are in `docs/` — see the pointer table below. This file is the editing checklist plus the invariants you must not violate.

## Script layers

- `scripts/setup.sh` — one-shot wrapper: full onboarding + lifecycle (`--restart`, `--recreate`, `--remove`, `--reset`, `--verify`). Idempotent. Users hit this for 90% of operations.
- `scripts/profile.sh` — granular primitives (`up`, `down`, `attach`, per-service `auth`, `exec`). `setup.sh` calls into it.
- `justfile` (repo root) — optional convenience front door. Every recipe is a **thin pass-through** to `profile.sh`/`setup.sh` (profile is the first positional arg: `just up <p>` → `scripts/profile.sh <p> up`). It is NOT canonical and holds NO logic: it must never call `docker compose` directly (that would bypass the `COMPOSE_PROJECT_NAME`/`PROFILE` export the scripts do, and the compose file's `${PROFILE:?...}` guard). When you add/rename a command in either script, update the matching recipe.

Both export `COMPOSE_PROJECT_NAME=macolima-<profile>` and `PROFILE=<profile>` before invoking `docker compose`. The compose file uses `${PROFILE:?...}` so any direct `docker compose` invocation without `PROFILE` set fails fast — keep that guard.

## Non-negotiable invariants

- **Agent runs as UID 1000 (`agent`)**, never root. `cap_drop: ALL`. `no_new_privs=1`. No sudo. The stock Ubuntu SUID set (`chage`, `chfn`, `chsh`, `expiry`, `gpasswd`, `mount`, `newgrp`, `pam_extrausers_chkpwd`, `passwd`, `su`, `umount`, `unix_chkpwd`) is present but neutralized by no_new_privs + dropped caps — any SUID binary outside that stock set is drift, and `verify-sandbox.sh` enforces this by diffing the live `find / -perm /6000 -type f` output against the expected list. **`ssh-agent` and `ssh-keysign` are NOT stock here** — `openssh-client` is deliberately purged (see `docs/vscode-leakage.md`), so their presence would be drift.
- **Agent has no direct network.** `sandbox-internal` is `internal: true`. Only reachable host is `egress-proxy`.
- **Agent has no working DNS resolver** other than the static `extra_hosts` entries for `egress-proxy`, `postgres`, `mongo`. `internal: true` blocks IP-level egress but does NOT block Docker's embedded resolver from forwarding arbitrary names — that side channel is closed by `dns: [127.0.0.1]` sinkhole + `extra_hosts`. See `docs/compose-network-ipam.md` §"DNS lockdown" before changing this.
- **Sandbox-internal subnet is hard-coded** to `172.30.0.0/24` so static IPs work for `extra_hosts`. Pinned IPs: egress-proxy `.10`, postgres `.20`, mongo `.30`. If that subnet conflicts with a host network, change all four locations together (the network's `ipam.config.subnet`, each service's `ipv4_address`, and `claude-agent`'s `extra_hosts`).
- **Proxy-allowed domains live in `proxy/allowed_domains.txt`.** Shared across profiles. Change → `docker exec egress-proxy-<p> squid -k reconfigure` (zero-downtime). Falls back to `COMPOSE_PROJECT_NAME=macolima-<p> PROFILE=<p> docker compose restart egress-proxy` only when the container is unhealthy.
- **Base image is digest-pinned** (`FROM ubuntu:24.04@sha256:...`). Don't replace with a tag.
- **Seccomp is applied at runtime** (`security_opt: seccomp=./seccomp.json`), not baked into the image. Changes take effect on `--force-recreate`, no rebuild.
- **All mount points under `/home/agent/...` must be pre-created in the `Dockerfile`** with `chown agent:agent`. Includes named-volume mount points (otherwise the volume initializes root-owned and the agent can't write).
- **Profile isolation is by `COMPOSE_PROJECT_NAME`.** Different project names = different network/volume suffixes and `container_name:` fields include `${PROFILE}` explicitly so two concurrent profiles don't collide on Docker's global container-name namespace. Don't remove the `${PROFILE}` suffix.

## Persistence map per profile

`/V/.../profiles/<profile>/` shorthand below means
`/Volumes/DataDrive/.claude-colima/profiles/<profile>/`. **`.claude-colima/`
is a historic misnomer** — it's the macolima state root for ALL per-profile
state (Gemini, gh/glab, db.env, etc.), not just Claude's. Renaming would
touch every script + the dashboard + the audit probes for cosmetic gain;
treat the path as canonical.

Everything outside these paths is **wiped on container recreate**:

| Container path | Host path | Notes |
|---|---|---|
| `/workspace` | `/Volumes/DataDrive/repo/<profile>` | Must exist before `up`; `profile.sh` validates. |
| `/home/agent/.claude/` | `/V/.../profiles/<profile>/claude-home/` | Tokens, sessions, MCP, projects |
| `/home/agent/.claude.json` | `/V/.../profiles/<profile>/claude.json` | Single file, chmod 644, must contain `{}`. See `docs/virtiofs-gotchas.md`. |
| `/home/agent/.cache/` | named volume `cache` (per profile) | npm/uv/pip caches. Named volume by necessity — see `docs/virtiofs-gotchas.md`. |
| `/home/agent/.config/` | `/V/.../profiles/<profile>/config/` | Holds `gh/`, `glab-cli/`, and `git/config` (git global config, via `GIT_CONFIG_GLOBAL`). |
| `/home/agent/.gemini/` | `/V/.../profiles/<profile>/gemini-home/` | Gemini CLI state (`oauth_creds.json` after first `gemini` login, `settings.json`, MCP). Directory mount; no chmod 644 dance. |
| `/home/agent/.vscode-server/` | named volume `vscode-server` (per project) | Named volume by necessity — see `docs/virtiofs-gotchas.md`. |

Volatile (tmpfs): `/tmp`, `/run`, `/home/agent/.npm-global`, `/home/agent/.local`.

Named volumes become `macolima-<profile>_<name>` — separate per profile.

Of everything this map marks as wiped, only three things are **irrecoverable** (no script regenerates them): unpushed `/workspace` code, Claude session history (`claude-home/projects`, `sessions`, `todos`), and DB *rows* (schema is recreatable, data isn't). Everything else re-seeds from `config/`, re-downloads, or comes back on re-login. README → "What you can't get back" has the reset pre-flight checklist; point users there before any `wipe`/`--reset`/`colima delete`.

For project-customization patterns (local wheels, overlay images), see `docs/local-wheels.md` and `docs/_future/overlay-project-plan.md`.

## Gotcha pointers — read before editing

| Editing… | See |
|---|---|
| `docker-compose.yml` DB siblings, `db.env`, DSNs | `docs/database-internals.md` |
| `proxy/squid.conf`, allowlist policy, caps, tmpfs ownership | `docs/squid-internals.md` |
| `seccomp.json`, `clone3` errno, syscall allowances | `docs/seccomp-notes.md` |
| `devcontainer.json`, `openssh-client`, `SSH_AUTH_SOCK`, `ensure_state` scrub | `docs/vscode-leakage.md` |
| Bind mounts, `.gitconfig`, `.claude.json`, `.cache`/`.vscode-server`, tmpfs uid | `docs/virtiofs-gotchas.md` |
| Subnet / `ipv4_address` / `extra_hosts` / `dns:` / `internal:` changes | `docs/compose-network-ipam.md` |
| `permissions.allow`/`deny`, `WebFetch`, `with-egress.sh`, hook self-protection | `docs/permissions-model.md` + `docs/deny-destructive-hook-plan.md` |
| Rootfs read-only, bwrap disabled, `setup.sh` bash 3.2, skills seeding, gh/glab proxy, commit identity | `docs/sandbox-design-notes.md` |
| Colima VM lifecycle, `--cpu`/mount flags wiped by `delete` | `docs/sandbox-design-notes.md` §"Colima VM delete…" + README troubleshooting |

## Editing checklist

Before committing:

- [ ] New `/home/agent/...` mount point? Pre-create it in `Dockerfile` + `chown agent:agent`.
- [ ] New seccomp allowance? Document the syscall and why in the comment above the `names` array.
- [ ] New allowed domain? Justify with a one-line comment above its block.
- [ ] New internal hostname (besides egress-proxy/postgres/mongo)? Add it to `claude-agent`'s `extra_hosts` AND give the target service a static `ipv4_address` in the `172.30.0.0/24` subnet. Don't rely on Docker's embedded resolver — it's bypassed by `dns: [127.0.0.1]`.
- [ ] New build-time download (curl, wget, npm install) of a non-package binary? Add a checksum verification step (compare gitstatusd / glab in `Dockerfile`).
- [ ] New entry in `permissions.allow`? Run through the L7 question list (`docs/permissions-model.md`): does it provide a shell-out path (`-c`, `-e`, `system()`, `exec`, scripted-input)? If so, deny it instead.
- [ ] New allow-listed Bash prefix? Audit its flag surface for destructive primitives (`-delete`, `-exec`, `-c`, `-e`, `of=`, etc.) — extend `config/hooks/deny-destructive.sh` ruleset, the test harness, and the `verify-sandbox.sh` probe if any exist. The hook is the only enforcement for flag-shape destructiveness; matcher-level denies cannot see it.
- [ ] Compose change touching subnet / `ipv4_address` / `extra_hosts` / `dns:` / `internal:`? Plan a full `down` + `rebuild`, not just `--force-recreate` (see `docs/compose-network-ipam.md`).
- [ ] Compose change? Run `PROFILE=_test docker compose config` to validate YAML interpolation.
- [ ] Added/renamed/removed a command in `profile.sh` or `setup.sh`? Update the matching `justfile` recipe (it's a pass-through, no logic) and re-run `just --list` to confirm it parses.
- [ ] Dockerfile / `.zshrc` / `.p10k.zsh` change? Need rebuild: `scripts/profile.sh build`, then `scripts/profile.sh <p> rebuild` per running profile. Add `--no-cache` (force every layer to re-run; refetch claude-code / npm / apt) or `--pull` (re-check the base digest) when a cached layer is masking the change — both accepted by `build`/`rebuild` only.

Routine debug commands moved to `docs/debug-recipes.md`. Accepted CVEs/misconfigs in `.trivyignore.yaml` with dated `expired_at` fields.

## What NOT to do

- Don't `docker compose` directly without `PROFILE` set — use `scripts/profile.sh`.
- Don't add `read_only: true` to the agent container (`docs/sandbox-design-notes.md` §rootfs).
- Don't mount `.vscode-server` or `.cache` as drive bind mounts — named volumes only (`docs/virtiofs-gotchas.md`).
- Don't add broad wildcards (`*.microsoft.com`, `.anthropic.com`) to the proxy allowlist — pin to specific subdomains. Sole exception: `.vscode-unpkg.net` (vendor-controlled CDN that legitimately rotates subdomains).
- Don't share the same profile dir between two profiles via symlinks "to save space" — the whole point is isolation.
- Don't commit secrets from `profiles/<name>/` into git — that dir is user state, not repo content. It lives on the drive, outside this repo.
- Don't chmod `.claude/.credentials.json` to anything other than 600. (And `db.env` to anything other than 600 — `ensure_state` re-asserts this on every `up`.)
- Don't re-add a `.gitconfig` bind mount (use `GIT_CONFIG_GLOBAL`), don't re-enable `sandbox.enabled`, don't re-add `bubblewrap`/`socat`/`openssh-client`.
- Don't revert `claude-agent`'s `dns: [127.0.0.1]` to Docker's default — that re-opens the DNS exfil side channel (`docs/compose-network-ipam.md`).
- Don't delete `http_access deny CONNECT !SSL_ports` from `proxy/squid.conf` — that line closes the CONNECT-on-port-80 hole (`docs/squid-internals.md`).
- Don't drop `cap_drop: ALL` from the postgres/mongo services to "make some extension work" — re-grant the specific cap instead, and document why next to the `cap_add` entry.
- Don't add bare `WebFetch` (no domain restriction) to the template's `permissions.allow` — it's a server-side exfil channel; per-project `WebFetch(domain:…)` only (`docs/permissions-model.md`).
- Don't remove the `hooks` block from `config/claude-settings.json` or relocate `deny-destructive.sh` out of `/usr/local/lib/claude-hooks/` — the matcher cannot express the shapes the hook catches, and the path is hardcoded in `verify-sandbox.sh` and `scripts/audit/probes/settings.py`. Don't switch the hook output to the legacy `{"decision":"block"}` shape — current Claude Code expects `hookSpecificOutput.permissionDecision`, and verify-sandbox greps for it.
