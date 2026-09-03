# CLAUDE.md — notes for AI agents working on this repo

Invariants, gotchas, and root causes that are **not obvious from the code** but are load-bearing. Read this before editing `docker-compose.yml`, `seccomp.json`, `Dockerfile`, or the proxy config.

User-facing usage (onboarding, DBs, web UIs, auth, host VS Code settings) lives in `README.md`. Root-cause deep dives are in `docs/` — see the pointer table below. This file is the editing checklist plus the invariants you must not violate.

## Script layers

- `scripts/setup.sh` — one-shot wrapper: full onboarding + lifecycle (`--restart`, `--recreate`, `--remove`, `--reset`, `--verify`). Idempotent. Users hit this for 90% of operations.
- `scripts/profile.sh` — granular primitives (`up`, `down`, `attach`, per-service `auth`, `exec`). `setup.sh` calls into it.
- `justfile` (repo root) — optional convenience front door. Every recipe is a **thin pass-through** to `profile.sh`/`setup.sh` (profile is the first positional arg: `just up <p>` → `scripts/profile.sh <p> up`). It is NOT canonical and holds NO logic: it must never call `docker compose` directly (that would bypass the `COMPOSE_PROJECT_NAME`/`PROFILE` export the scripts do, and the compose file's `${PROFILE:?...}` guard). When you add/rename a command in either script, update the matching recipe. **Exception:** the `colima-*` recipes (`colima-up`/`colima-down`/`colima-status`) take NO profile arg and front the VM-lifecycle scripts (`start.sh`/`stop.sh`) instead of `profile.sh`/`setup.sh` — Colima is shared across all profiles. They are still thin pass-throughs and still never call `docker compose`; `colima-status` is the lone recipe that runs the `colima` binary directly (read-only, no env-guard to bypass). `code` and `dashboard` are two further exceptions in the same spirit: they front `scripts/code-attach.sh` and `scripts/dashboard.sh`, host-side helpers that touch no container state. Still thin pass-throughs; still no `docker compose`.
- `sandbox_templates/bin/webfetch` — the web-read broker, baked to `/usr/local/bin/webfetch`. The ONLY sanctioned route by which the agent reads the open web: `curl`/`wget` are denied and `WebFetch` is scoped per repo, so it fetches through a hosted reader API whose host is allowlisted under `[web-read]`. stdlib-only Python; urllib honours `HTTPS_PROXY` so requests still traverse Squid. Keys come from `secrets.env` and never argv. Every https:// host inside it must be an EXACT live line in `proxy/allowed_domains.txt` — `scripts/webfetch.test.sh` extracts them and diffs, so a host added in one place and not the other fails offline rather than as a TCP_DENIED that reads like a bad key.
- `scripts/profile.sh <p> converge` — re-runs everything `up` seeds (every agent's policy + skills) touching no container. Replaced `reset-settings` and `reset-skills`, which were near-identical commands with three different semantics; that confusion is what let the Claude policy sit behind its template. `--defaults` additionally resets the PRESERVED preference keys to the template defaults and captures what it replaced to `claude-home/settings.discarded.json`.
- `scripts/verify-sandbox.sh` — the tier-1 hardening tripwire, run by `scripts/profile.sh <p> verify`, which STREAMS it
  into the agent over stdin (`docker exec -i … bash -s`) rather than staging a copy into `/workspace`. `verify` also runs
  `check_allowlist_sync` host-side first, because this script executes inside the agent and can see neither the repo nor
  the proxy container. Note `just verify` is the hardening check; the onboarding sanity block is `just setup-verify`.
- `scripts/dashboard.sh` — launches the host-side Streamlit ops console (`just dashboard`). It `cd`s into `dashboard/`
  before exec'ing the venv's streamlit, because Streamlit resolves `.streamlit/config.toml` relative to `$PWD` and that
  file is the only thing pinning the bind address to `127.0.0.1`. Wrong CWD ⇒ no pin ⇒ Streamlit's default of binding
  every interface, for a console that can rewrite the proxy allowlist and restart containers. The script hard-fails if
  the config file is absent; do not "simplify" the cd away.
- `scripts/code-attach.sh` — host-side VS Code addressing helper (`just code <profile> [folder]`). Builds the
  `vscode-remote://attached-container+<hex>/<path>` URI and execs `code --folder-uri`. Read-only with respect to the
  container: it starts nothing, and requires the agent container to be running already. The hex authority names the
  container **and the docker context** — `colima` here, never `default` (that context points at `/var/run/docker.sock`
  and cannot see these containers). Override with `SANDBOX_VSCODE_CONTEXT`; `SANDBOX_CODE_DRYRUN=1` prints the URI.
- `scripts/start.sh` / `scripts/stop.sh` — Colima VM lifecycle for the everyday case. `start.sh` is the idempotent post-reboot start (plain `colima start`, plus a `check_sizing_drift` warning when the live VM's cpu/memory/disk no longer match what `colima-up.sh` declares; with profile args it also brings those profiles up); `stop.sh` stops all running profiles then the VM. Distinct from `scripts/colima-up.sh`, which is the first-time / post-`colima delete` start that bakes the `--cpu`/mount flags into `colima.yaml` (see `docs/sandbox-design-notes.md` §"Colima VM delete…").

Both export `COMPOSE_PROJECT_NAME=macolima-<profile>` and `PROFILE=<profile>` before invoking `docker compose`. The compose file uses `${PROFILE:?...}` so any direct `docker compose` invocation without `PROFILE` set fails fast — keep that guard.

## Non-negotiable invariants

- **Agent runs as UID 1000 (`agent`)**, never root. `cap_drop: ALL`. `no_new_privs=1`. No sudo. The stock Ubuntu SUID set (`chage`, `chfn`, `chsh`, `expiry`, `gpasswd`, `mount`, `newgrp`, `pam_extrausers_chkpwd`, `passwd`, `su`, `umount`, `unix_chkpwd`) is present but neutralized by no_new_privs + dropped caps — any SUID binary outside that stock set is drift, and `verify-sandbox.sh` enforces this by diffing the live `find / -perm /6000 -type f` output against the expected list. **`ssh-agent` and `ssh-keysign` are NOT stock here** — `openssh-client` is deliberately purged (see `docs/vscode-leakage.md`), so their presence would be drift.
- **Agent has no direct network.** `sandbox-internal` is `internal: true`. Only reachable host is `egress-proxy`.
- **Agent has no working DNS resolver** other than the static `extra_hosts` entries for `egress-proxy`, `postgres`, `mongo`. `internal: true` blocks IP-level egress but does NOT block Docker's embedded resolver from forwarding arbitrary names — that side channel is closed by `dns: [127.0.0.1]` sinkhole + `extra_hosts`. See `docs/compose-network-ipam.md` §"DNS lockdown" before changing this.
- **Sandbox-internal subnet is allocated per profile** as `172.30.${SANDBOX_OCTET:-0}.0/24`; pinned IPs are egress-proxy `.10`, postgres `.20`, mongo `.30`. `SANDBOX_OCTET` is assigned by `profile.sh` (`ensure_subnet_octet` / `ensure_octet_free`) from a hash of the profile name, persisted in `<profiles>/<profile>/subnet-octet`, and re-checked against live Docker networks before any network-creating `up`. **Do not re-hardcode the octet, and do not spell it out in more than one place** — the subnet, the three `ipv4_address` pins and the three `extra_hosts` entries must all derive from that one variable. They are the only name-resolution path the agent has (DNS is sinkholed), so a pin/hosts disagreement means the agent dials a dead IP: proxy mismatch kills all egress, DB mismatch is connection-refused. This replaces the old "change all four locations together" rule, which was manual drift waiting to happen. Any script calling `docker compose` on a network-creating verb must go through `profile.sh` so the octet is exported.
- **Proxy-allowed domains live in `proxy/allowed_domains.txt`.** Shared across profiles. Change → `docker exec egress-proxy-<p> squid -k reconfigure` (zero-downtime). Falls back to `COMPOSE_PROJECT_NAME=macolima-<p> PROFILE=<p> docker compose restart egress-proxy` only when the container is unhealthy.
- **Base image is digest-pinned** (`FROM ubuntu:24.04@sha256:...`). Don't replace with a tag.
- **Seccomp is applied at runtime** (`security_opt: seccomp=./seccomp.json`), not baked into the image. Changes take effect on `--force-recreate`, no rebuild.
- **All mount points under `/home/agent/...` must be pre-created in the `Dockerfile`** with `chown agent:agent`. Includes named-volume mount points (otherwise the volume initializes root-owned and the agent can't write).
- **Profile isolation is by `COMPOSE_PROJECT_NAME`.** Different project names = different network/volume suffixes and `container_name:` fields include `${PROFILE}` explicitly so two concurrent profiles don't collide on Docker's global container-name namespace. Don't remove the `${PROFILE}` suffix.

## Persistence map per profile

`/V/.../profiles/<profile>/` shorthand below means
`/Volumes/DataDrive/.claude-colima/profiles/<profile>/`. **`.claude-colima/`
is a historic misnomer** — it's the macolima state root for ALL per-profile
state (Gemini, gh, db.env, etc.), not just Claude's. Renaming would
touch every script + the dashboard + the audit probes for cosmetic gain;
treat the path as canonical.

Everything outside these paths is **wiped on container recreate**:

| Container path | Host path | Notes |
|---|---|---|
| `/workspace` | `/Volumes/DataDrive/repo/<profile>` | Must exist before `up`; `profile.sh` validates. |
| `/home/agent/.claude/` | `/V/.../profiles/<profile>/claude-home/` | Tokens, sessions, MCP, projects |
| `/home/agent/.claude.json` | `/V/.../profiles/<profile>/claude.json` | Single file, chmod 644, must contain `{}`. See `docs/virtiofs-gotchas.md`. |
| `/home/agent/.cache/` | named volume `cache` (per profile) | npm/uv/pip caches. Named volume by necessity — see `docs/virtiofs-gotchas.md`. |
| `/home/agent/.config/` | `/V/.../profiles/<profile>/config/` | Holds `gh/` and `git/config` (git global config, via `GIT_CONFIG_GLOBAL`). |
| `/home/agent/.gemini/` | `/V/.../profiles/<profile>/gemini-home/` | Antigravity CLI (`agy`) state — now also its POLICY: `antigravity-cli/settings.json` (merged) and `config/hooks.json` (whole-file), both converged on every `up`. — agy reuses the `~/.gemini` home; config under `~/.gemini/antigravity-cli/`. Host dir name kept from the former Gemini CLI mount. Directory mount; no chmod 644 dance. |
| `/home/agent/.vscode-server/` | named volume `vscode-server` (per project) | Named volume by necessity — see `docs/virtiofs-gotchas.md`. |

Volatile (tmpfs): `/tmp`, `/run`, `/home/agent/.npm-global`, `/home/agent/.local`.

`db.env` and `secrets.env` are NOT in the table because they are not mounted:
compose injects them as optional `env_file`s, so only the variables reach the
container and the files stay host-side. Both are read at container **create**,
so an edit needs `recreate`, not `up`. Both are chmod 600'd on every `up` and
preserved by `wipe`.

Named volumes become `macolima-<profile>_<name>` — separate per profile.

Of everything this map marks as wiped, only three things are **irrecoverable** (no script regenerates them): unpushed `/workspace` code, Claude session history (`claude-home/projects`, `sessions`, `todos`), and DB *rows* (schema is recreatable, data isn't). Everything else re-seeds from `config/`, re-downloads, or comes back on re-login. README → "What you can't get back" has the reset pre-flight checklist; point users there before any `wipe`/`--reset`/`colima delete`.

For project-customization patterns (local wheels, overlay images), see `docs/local-wheels.md` and `docs/_future/overlay-project-plan.md`.

## Gotcha pointers — read before editing

| Editing… | See |
|---|---|
| `docker-compose.yml` DB siblings, `db.env`, DSNs | `docs/database-internals.md` |
| `secrets.env`, per-profile API keys, `SANDBOX_PROFILE` | `docs/database-internals.md` §"Per-profile API keys" |
| `sandbox_templates/bin/webfetch`, `[web-read]` hosts, adding a backend | `docs/web-read-broker.md` |
| `agy` policy, the two hook dialects, `converge` | `sandbox_templates/antigravity/README.md` + `scripts/agent-policy.test.sh` header |
| `proxy/squid.conf`, allowlist policy, caps, tmpfs ownership | `docs/squid-internals.md` |
| `seccomp.json`, `clone3` errno, syscall allowances | `docs/seccomp-notes.md` |
| `devcontainer.json`, `openssh-client`, `SSH_AUTH_SOCK`, `ensure_state` scrub | `docs/vscode-leakage.md` |
| Bind mounts, `.gitconfig`, `.claude.json`, `.cache`/`.vscode-server`, tmpfs uid | `docs/virtiofs-gotchas.md` |
| Subnet / `ipv4_address` / `extra_hosts` / `dns:` / `internal:` changes | `docs/compose-network-ipam.md` |
| `permissions.allow`/`deny`, `WebFetch`, `with-egress.sh`, hook self-protection | `docs/permissions-model.md` + `docs/deny-destructive-hook-plan.md` |
| Rootfs read-only, bwrap disabled, `setup.sh` bash 3.2, skills seeding, gh proxy, commit identity | `docs/sandbox-design-notes.md` |
| Colima VM lifecycle, `--cpu`/mount flags wiped by `delete` | `docs/sandbox-design-notes.md` §"Colima VM delete…" + README troubleshooting |

## Editing checklist

Before committing:

- [ ] New `/home/agent/...` mount point? Pre-create it in `Dockerfile` + `chown agent:agent`.
- [ ] New seccomp allowance? Document the syscall and why in the comment above the `names` array.
- [ ] New allowed domain? Justify with a one-line comment above its block.
- [ ] New internal hostname (besides egress-proxy/postgres/mongo)? Add it to `claude-agent`'s `extra_hosts` AND give the target service a static `ipv4_address` — both written as `172.30.${SANDBOX_OCTET:-0}.<host>`, never a literal octet. Don't rely on Docker's embedded resolver — it's bypassed by `dns: [127.0.0.1]`.
- [ ] New build-time download (curl, wget, npm install) of a non-package binary? Add a checksum verification step (compare gitstatusd / `just` in `Dockerfile`).
- [ ] New `Bash(...)` entry in ANY tier of `claude-settings.json`? It needs a `command(...)` twin in `sandbox_templates/antigravity/antigravity-settings.json`. `scripts/agent-policy.test.sh` diffs the two files in both directions with no exception list — a one-sided edit fails offline. The agy file is REGENERATED from the claude one, never hand-maintained.
- [ ] New entry in `permissions.allow`? Run through the L7 question list (`docs/permissions-model.md`): does it provide a shell-out path (`-c`, `-e`, `system()`, `exec`, scripted-input)? If so, deny it instead.
- [ ] New allow-listed Bash prefix? Audit its flag surface for destructive primitives (`-delete`, `-exec`, `-c`, `-e`, `of=`, etc.) — extend `sandbox_templates/claude/hooks/deny-destructive.sh` ruleset, the test harness, and the `verify-sandbox.sh` probe if any exist. The hook is the only enforcement for flag-shape destructiveness; matcher-level denies cannot see it.
- [ ] Compose change touching subnet / `ipv4_address` / `extra_hosts` / `dns:` / `internal:`? Plan a full `down` + `rebuild`, not just `--force-recreate` (see `docs/compose-network-ipam.md`).
- [ ] Compose change? Run `PROFILE=_test docker compose config` to validate YAML interpolation.
- [ ] Added/renamed/removed a command in `profile.sh` or `setup.sh` (or a VM verb in `start.sh`/`stop.sh` fronted by a `colima-*` recipe)? Update the matching `justfile` recipe (it's a pass-through, no logic) and re-run `just --list` to confirm it parses.
- [ ] Dockerfile / `.zshrc` / `.p10k.zsh` change? Need rebuild: `scripts/profile.sh build`, then `scripts/profile.sh <p> rebuild` per running profile. Add `--no-cache` (force every layer to re-run; refetch claude-code / npm / apt) or `--pull` (re-check the base digest) when a cached layer is masking the change — both accepted by `build`/`rebuild` only. For a CLI version bump alone, prefer `scripts/profile.sh build --refresh-ai` (or `--claude-version=X.Y.Z`, which implies it): it busts only the AI-CLI tail layer, ~21s against ~100s for a full rebuild. Those two flags are `build`-only. **`build` takes NO profile arg** — the image is shared by every profile.

Routine debug commands moved to `docs/debug-recipes.md`. Accepted CVEs/misconfigs in `.trivyignore.yaml` with dated `expired_at` fields.

## What NOT to do

- Don't `docker compose` directly without `PROFILE` set — use `scripts/profile.sh`.
- Don't add `read_only: true` to the agent container (`docs/sandbox-design-notes.md` §rootfs).
- Don't mount `.vscode-server` or `.cache` as drive bind mounts — named volumes only (`docs/virtiofs-gotchas.md`).
- Don't add broad wildcards (`*.microsoft.com`, `.anthropic.com`) to the proxy allowlist — pin to specific subdomains. Sole exception: `.vscode-unpkg.net` (vendor-controlled CDN that legitimately rotates subdomains).
- Don't share the same profile dir between two profiles via symlinks "to save space" — the whole point is isolation.
- Don't commit secrets from `profiles/<name>/` into git — that dir is user state, not repo content. It lives on the drive, outside this repo.
- Don't chmod `.claude/.credentials.json` to anything other than 600. (And `db.env` / `secrets.env` to anything other than 600 — `ensure_state` re-asserts both on every `up`.)
- Don't re-add a `.gitconfig` bind mount (use `GIT_CONFIG_GLOBAL`), don't re-enable `sandbox.enabled`, don't re-add `bubblewrap`/`socat`/`openssh-client`.
- Don't revert `claude-agent`'s `dns: [127.0.0.1]` to Docker's default — that re-opens the DNS exfil side channel (`docs/compose-network-ipam.md`).
- Don't delete `http_access deny CONNECT !SSL_ports` from `proxy/squid.conf` — that line closes the CONNECT-on-port-80 hole (`docs/squid-internals.md`).
- Don't drop `cap_drop: ALL` from the postgres/mongo services to "make some extension work" — re-grant the specific cap instead, and document why next to the `cap_add` entry.
- Don't add bare `WebFetch` (no domain restriction) to the template's `permissions.allow` — it's a server-side exfil channel; per-project `WebFetch(domain:…)` only (`docs/permissions-model.md`).
- Don't widen the proxy to a research/UGC/PDF domain "so the agent can read it" — that is what the `webfetch` broker exists to avoid. Add a broker backend instead, or scope `WebFetch(domain:…)` in the repo that needs it. Don't add a broker's vendor wildcard, and don't add a host whose key also unlocks a write surface (TinyFish Agent/Browser is the worked example).
- Don't unify anything about the two hook dialects. Four asymmetries are deliberate and each is a hole if flattened: claude fails **open** (its static `permissions.deny` is underneath) while antigravity fails **closed** (there the hook IS the control, so its pass must stay an explicit `{"decision":"allow"}` — `{}` is a DENY to `agy`); the ask tier is dialect-branched (`permissionDecision:"ask"` vs `decision:"force_ask"`, because `agy` caches a plain `ask` as a permanent Always-Allow); an unknown `--dialect=` must stay FATAL rather than coercing to claude; and the two convergence write modes stay opposite (claude overwrites, `agy` merges — `agy` has no repo-local file to hold its preferences).
- Don't turn the `guardrails.sh` symlink into a copy — two copies can diverge on disk, and the divergence is invisible until one agent enforces a rule the other does not.
- Don't remove the `hooks` block from `sandbox_templates/claude/claude-settings.json` or relocate `deny-destructive.sh` out of `/usr/local/lib/claude-hooks/` — the matcher cannot express the shapes the hook catches, and the path is hardcoded in `verify-sandbox.sh` and `scripts/audit/probes/settings.py`. Don't switch the hook output to the legacy `{"decision":"block"}` shape — current Claude Code expects `hookSpecificOutput.permissionDecision`, and verify-sandbox greps for it.
