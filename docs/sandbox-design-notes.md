# Sandbox design notes

Background on a few architectural choices that look surprising in the code but exist for a specific reason. Editing-time invariants live in `CLAUDE.md`; this is the "why."

## Rootfs is NOT read-only

`read_only: true` was tried and removed on the agent container. It breaks VS Code Dev Containers' `/etc/environment` patching with no security gain (non-root + `cap_drop: ALL` already blocks system-dir writes). Stays on `egress-proxy` because Squid doesn't need rootfs writes.

## Claude Code's bwrap sandbox is disabled; the container is the boundary

Claude Code's `Bash` tool wraps every command in `bwrap` (bubblewrap). bwrap implements isolation by calling `unshare(CLONE_NEWUSER)`, which our seccomp filter **correctly blocks** (unprivileged user namespaces are a non-negotiable deny). Result: every Bash call would fail with `bwrap: No permissions to create new namespace`. Two sandboxes with incompatible mechanisms; the container is the stronger outer boundary.

Three load-bearing consequences:

1. **`sandbox.enabled: false`** in `~/.claude/settings.json` — Claude Code uses unsandboxed execution.
2. **`bubblewrap`, `socat`, and `openssh-client` are NOT installed** in the Dockerfile. Each was either dead weight or an exfil path:
   - `bubblewrap` only supported the in-process sandbox (now disabled).
   - `socat` was a raw-TCP exfil channel bypassing the HTTP-only Squid egress.
   - `openssh-client` (`ssh`/`scp`/`sftp`/`ssh-agent`/...) is the tool surface that weaponizes VS Code's `SSH_AUTH_SOCK` forwarding. There is **no host-side VS Code setting** that disables Dev Containers' SSH agent forwarding (`remote.SSH.enableAgentForwarding` only governs the unrelated Remote-SSH extension). The env-level mitigation is `config/.zshrc`'s `unset SSH_AUTH_SOCK`, which is flow-independent (it fires on VS Code attach, `profile.sh attach`, and `docker exec` alike). A `devcontainer.json` `remoteEnv: { SSH_AUTH_SOCK: "" }` does NOT help on the attach path — *Attach to Running Container* ignores the repo `devcontainer.json` ([VS Code docs](https://code.visualstudio.com/docs/devcontainers/attach-container)); it would only apply under *Reopen in Container*, which macolima doesn't use. With `openssh-client` gone the socket is unusable regardless. No legitimate agent workflow needs SSH: gh/glab use HTTPS tokens, git remotes are HTTPS, and agent-mode denies `git push|clone|fetch`.
3. **`config/claude-settings.json`** is the per-profile settings template. `ensure_state()` copies it into `profiles/<p>/claude-home/settings.json` on first `up` (only if absent — existing profiles keep customizations).

Do **not** "re-harden" by re-enabling `sandbox.enabled` or re-adding `bubblewrap`/`socat`/`openssh-client`. bwrap's threat model protects a real host filesystem from a rogue command; there is no reachable host filesystem from inside this container.

## Per-profile Claude Code skills are seeded from `config/skills/`

Skills live at `config/skills/<name>/SKILL.md` and are seeded into each profile's `claude-home/skills/<name>/` by `ensure_state()` on first `up` — copy only if absent, so user customisations survive subsequent `up`s. To force-refresh from template: `scripts/profile.sh <p> reset-skills` (backs up to `<name>.bak.<stamp>/`; `clean --deep` sweeps those).

The shipped `audit-sandbox` skill points at the staged `claude_internal_audit.md` rather than duplicating it — so when you edit the audit prompt, no skill change is needed; just re-run `scripts/stage-audit-package.sh <profile>`. README §"Self-audit" covers user invocation.

## Commit identity: `git config` is denied — seed `user.*` host-side

The agent's deny list blocks `git config` because that subcommand can rewrite `credential.helper` to a host-reaching shim between `ensure_state()` scrub passes (same threat model as VS Code's injected helper). The matcher is keyed on the command prefix, so benign subcommands (`git config user.name "…"`) are caught in the same net.

Two legitimate paths to attribute commits correctly:

1. **Persistent (preferred):** seed `[user] name=…  email=…` into `profiles/<p>/config/git/config` on the host. It's a directory-mount, picked up via `GIT_CONFIG_GLOBAL` inside the container. `ensure_state()` auto-seeds this from `GIT_USER_NAME` / `GIT_USER_EMAIL` env vars in the calling shell on first `up` if the `[user]` section is missing — set them once in your shell rc (e.g. `~/.zshrc.local`), or write the section manually if you prefer. Survives rebuilds; no per-commit gymnastics.
2. **Per-commit env-var fallback** (legitimate, not evasion): `GIT_AUTHOR_NAME=… GIT_AUTHOR_EMAIL=… GIT_COMMITTER_NAME=… GIT_COMMITTER_EMAIL=… git commit …`. Sets identity on the single commit object only; no config file write, no `credential.helper` reach. Use this when option 1 hasn't been seeded yet and you don't want to bounce out of the agent loop.

Agent-side workflow: `git push|clone|fetch|pull` are denied, but local branch ops (`git branch`, `git checkout -b`, `git switch -c`, `git merge`, `git rebase` local-only) are allowed — agent does the work, user does the push. If commit identity is missing, the agent should ask the user to seed `config/git/config` rather than reach for `git config` (which it can't run anyway).

## Colima VM delete wipes mount + resource config

`colima delete` wipes the VM and Colima's persisted config. A subsequent bare `colima start` creates a fresh VM with **2 CPU / 2 GB RAM / 60 GB disk / no host mounts**. That breaks the stack two ways:

1. CPU limit error on container start (`range of CPUs is from 0.01 to 2.00`) — compose asks for `cpus: 4`, fresh VM has 2.
2. Bind-mount error (`error mounting "...squid.conf" ... not a directory`) — `/Volumes/DataDrive` virtiofs mount is gone, Docker auto-creates the missing source as a directory and tries to mount that dir onto a file in the Squid image.

Fix: **always use `scripts/colima-up.sh` after a delete**, never bare `colima start`. The wrapper encodes the required flags (`--cpu 6 --memory 10 --disk 80 --mount-type virtiofs --mount /Volumes/DataDrive/repo:w --mount /Volumes/DataDrive/.claude-colima:w`). Those persist into `colima.yaml` so subsequent stop/start cycles without flags work — until the next delete.

Sanity-check mounts after a VM start:

```bash
colima ssh -- ls /Volumes/DataDrive/repo/nranthony/macolima/proxy/squid.conf
```

External disks live under `_lima/_disks/<name>/datadisk` — `colima delete` doesn't always remove them, hence the cosmetic "disk size cannot be reduced" WARN. To truly reset disk size, stop Colima and `rm -rf` the `_disks/colima/` subdir before starting.

## Ubuntu 24.04 default `ubuntu` user at UID 1000

Dockerfile does `userdel -r ubuntu 2>/dev/null || true` before creating `agent` at UID 1000. Don't remove that line.

## VS Code re-attach after container recreate

`docker compose up -d --force-recreate` changes the container ID. VS Code Dev Containers caches attachment by ID. After recreate: `Remote: Close Remote Connection` → re-attach, or reload window, or relaunch VS Code.

## gh/glab and the proxy

`gh` and `glab` are installed at build time (direct internet via host daemon). At runtime they go through Squid. `gh auth login` uses `github.com` + `api.github.com` (matched by `.github.com` wildcard); `glab` uses `gitlab.com` (covered by `.gitlab.com`). For self-hosted GitLab, add the hostname to `allowed_domains.txt` before auth.

**OAuth browser flow is structurally broken** — both default to a callback on `http://localhost:<port>` inside the container, which the host browser can't reach because `sandbox-internal` is `internal: true` with no published ports (by design, not a bug to fix). Token flow only. README §Authentication has the user-facing scope list.

**Build-time integrity for `glab`** (audit L3): the Dockerfile fetches GitLab's published `checksums.txt` alongside the release tarball, greps the line matching the platform-specific filename, and pipes to `sha256sum -c -` before extracting. A one-time compromise of the GitLab release CDN between two builds would cause this check to fail rather than silently land a malicious binary. When bumping `GLAB_VERSION`, no manual SHA pin is needed — `checksums.txt` is fetched fresh per build and the integrity assertion is "tarball matches what GitLab says it should be." Compare to `gitstatusd` which uses the same pattern via p10k's `install.info`. The other build-time fetches (`curl|sh` for nodesource/uv/ohmyzsh, `npm install -g … @latest`) are still trusted-on-TLS; tightening those to checksum'd installers is open hygiene work, but glab was the one carrying CVEs in `.trivyignore` and getting it pinned matters most.

## `setup.sh` must stay bash 3.2-compatible

macOS ships `/bin/bash` 3.2 and `env bash` often resolves to it. No `;;&` case fall-through, no `mapfile`, no `${var,,}`, no associative arrays. When `--github` / `--gitlab` / `--both` need shared logic, use a helper function called from multiple case arms — not `;;&`.
