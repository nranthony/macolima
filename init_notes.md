# Claude Code Sandbox Setup — Implementation Plan

A repo-driven setup for running Claude Code in a Colima container on macOS, with OAuth auth, external drive storage, VS Code integration, and hardened sandboxing.

**Target:** Mac Mini M4, 16 GB RAM, macOS 26 (Tahoe), external TB4 NVMe at `/Volumes/T7` (substitute your actual drive name throughout).

---

## Intended repo structure

```
claude-sandbox-setup/
├── README.md                          # quick-start (mirror of this plan's "Usage")
├── PLAN.md                            # this file
├── Dockerfile                         # container image definition
├── docker-compose.yml                 # (optional) container orchestration
├── .devcontainer/
│   └── devcontainer.json              # VS Code Dev Containers config
├── config/
│   ├── claude-settings.json           # Claude Code settings.json template
│   └── colima.yaml.example            # Colima config reference
├── scripts/
│   ├── bootstrap.sh                   # one-time setup on macOS
│   ├── start.sh                       # daily: start Colima + container
│   ├── stop.sh                        # daily: stop container + Colima
│   ├── attach.sh                      # attach a shell to running container
│   └── auth.sh                        # OAuth login flow helper
└── .gitignore                         # excludes auth tokens, local overrides
```

---

## Phase 1: Prerequisites on macOS

### 1.1 Verify environment

- [ ] macOS 13+ (you're on 26, good)
- [ ] External drive at `/Volumes/T7` formatted APFS — verify with `diskutil info /Volumes/T7 | grep "File System"`
- [ ] Homebrew installed
- [ ] Rosetta installed: `softwareupdate --install-rosetta --agree-to-license`

### 1.2 Install tooling

```bash
brew install colima docker docker-compose docker-buildx
brew install --cask visual-studio-code
# Install VS Code "Dev Containers" extension from within VS Code
```

### 1.3 Uninstall Docker Desktop if present

```bash
brew uninstall --cask docker-desktop 2>/dev/null
rm -rf ~/.docker/contexts
```

---

## Phase 2: Colima on the external drive

### 2.1 Create directory structure on the drive

```bash
mkdir -p /Volumes/T7/colima
mkdir -p /Volumes/T7/projects
mkdir -p /Volumes/T7/claude-agent/{claude-home,workspace-cache}
```

### 2.2 Persistent environment variables

Add to `~/.zshrc`:

```bash
# Colima on external drive
export COLIMA_HOME="/Volumes/T7/colima"
export LIMA_HOME="/Volumes/T7/colima/_lima"
```

Reload: `source ~/.zshrc`

### 2.3 First start (creates VM on the drive)

Minimal mounts — only what we actually need, no `$HOME`:

```bash
colima start \
  --vm-type vz \
  --vz-rosetta \
  --mount-type virtiofs \
  --cpu 6 \
  --memory 8 \
  --disk 80 \
  --mount "/Volumes/T7/projects:w" \
  --mount "/Volumes/T7/claude-agent:w"
```

### 2.4 Lock in the config so flags aren't needed going forward

After the first start, edit `$COLIMA_HOME/default/colima.yaml` — the flags above get persisted there. From now on, `colima start` (no flags) uses them.

### 2.5 Verify

```bash
colima status                            # should say macOS Virtualization.Framework
colima ssh -- ls /Volumes/T7             # VM should see the drive
docker run --rm hello-world              # native ARM64 works
docker run --rm --platform linux/amd64 alpine uname -m  # Rosetta works, prints x86_64
```

---

## Phase 3: Build the container image

### 3.1 `Dockerfile`

```dockerfile
FROM ubuntu:24.04

# Core tooling, sandbox dependencies, dev essentials
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl wget git sudo \
    bubblewrap socat \
    build-essential \
    python3 python3-pip python3-venv \
    ripgrep jq less vim-tiny \
    && rm -rf /var/lib/apt/lists/*

# Node.js (required for Claude Code)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && npm install -g @anthropic-ai/claude-code \
    && rm -rf /var/lib/apt/lists/*

# uv for Python (optional but useful)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && mv /root/.local/bin/uv /usr/local/bin/uv

# Non-root user for the agent
RUN useradd -m -s /bin/bash -u 1000 agent \
    && echo "agent ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER agent
WORKDIR /workspace

# Expected mounts at runtime:
#   /workspace         — bind to /Volumes/T7/projects/<repo>
#   /home/agent/.claude — bind to /Volumes/T7/claude-agent/claude-home

CMD ["bash"]
```

### 3.2 Build

```bash
docker build -t claude-sandbox:latest .
```

---

## Phase 4: OAuth auth with Pro/Max (no API key)

### 4.1 First-time login

OAuth state persists in `~/.claude/` inside the container, which we bind-mount to `/Volumes/T7/claude-agent/claude-home` — so it survives container restarts and even rebuilds.

```bash
docker run -it --rm \
  -v /Volumes/T7/claude-agent/claude-home:/home/agent/.claude \
  claude-sandbox \
  claude login
```

Claude prints a URL. Open it on macOS, complete the browser auth, paste the code back. Token lands in `/Volumes/T7/claude-agent/claude-home/`.

### 4.2 Verify auth persists

```bash
docker run -it --rm \
  -v /Volumes/T7/claude-agent/claude-home:/home/agent/.claude \
  claude-sandbox \
  claude whoami
```

Should show your account without re-prompting.

### 4.3 Security note

The files under `/Volumes/T7/claude-agent/claude-home/` contain your OAuth token. Treat them like an SSH private key:
- Don't commit them (add `claude-agent/` to `.gitignore`)
- Don't share the drive casually
- If compromised, revoke the token in your Claude account settings

---

## Phase 5: Claude Code sandbox settings

### 5.1 `config/claude-settings.json`

Copy this into `/Volumes/T7/claude-agent/claude-home/settings.json`:

```json
{
  "sandbox": {
    "enabled": true,
    "autoAllowBashIfSandboxed": true,
    "failIfUnavailable": true,
    "allowUnsandboxedCommands": false,
    "filesystem": {
      "denyRead": [
        "/root/.ssh/**",
        "/home/agent/.ssh/**",
        "**/.env",
        "**/.env.*",
        "**/credentials",
        "**/*secret*",
        "**/*.pem",
        "**/*.key"
      ]
    },
    "network": {
      "allowedDomains": [
        "registry.npmjs.org",
        "pypi.org",
        "files.pythonhosted.org",
        "github.com",
        "api.github.com",
        "raw.githubusercontent.com",
        "objects.githubusercontent.com",
        "api.anthropic.com",
        "statsig.anthropic.com"
      ]
    }
  },
  "permissions": {
    "deny": [
      "Bash(curl:*)",
      "Bash(wget:*)",
      "Read(**/.env)",
      "Read(**/.env.*)",
      "Read(**/*.pem)",
      "Read(**/*.key)"
    ],
    "defaultMode": "ask"
  }
}
```

### 5.2 What this config does

- **Sandbox on, auto-allow on** — bash commands within the sandbox run without prompts, but the sandbox enforces filesystem + network boundaries at the OS level.
- **`failIfUnavailable: true`** — if the sandbox can't start, Claude refuses to run bash rather than silently downgrading.
- **`allowUnsandboxedCommands: false`** — closes the escape hatch where Claude retries failed sandboxed commands outside the sandbox.
- **Deny patterns for secrets** — belt-and-braces; even if Claude tries, reads of common secret patterns fail.
- **Network allowlist** — only package registries, GitHub, and Anthropic. New domains require approval.
- **`Bash(curl:*)` and `Bash(wget:*)` denied** — force Claude to use proper APIs instead of freeform HTTP, which would route around the sandbox proxy logic.

---

## Phase 6: Launch patterns

### 6.1 Long-running persistent container

```bash
docker run -d \
  --name claude-agent \
  -v /Volumes/T7/projects:/workspace/projects \
  -v /Volumes/T7/claude-agent/claude-home:/home/agent/.claude \
  -v /Volumes/T7/claude-agent/workspace-cache:/home/agent/.cache \
  -w /workspace \
  claude-sandbox \
  sleep infinity

docker exec -it claude-agent bash      # attach whenever
```

### 6.2 Ephemeral one-off

```bash
docker run -it --rm \
  -v /Volumes/T7/projects/myrepo:/workspace \
  -v /Volumes/T7/claude-agent/claude-home:/home/agent/.claude \
  -w /workspace \
  claude-sandbox
```

### 6.3 Script wrappers (in `scripts/`)

`start.sh`:
```bash
#!/usr/bin/env bash
set -e
colima start
docker start claude-agent 2>/dev/null || docker run -d --name claude-agent \
  -v /Volumes/T7/projects:/workspace/projects \
  -v /Volumes/T7/claude-agent/claude-home:/home/agent/.claude \
  -v /Volumes/T7/claude-agent/workspace-cache:/home/agent/.cache \
  -w /workspace \
  claude-sandbox sleep infinity
echo "Container running. Attach with: scripts/attach.sh"
```

`attach.sh`:
```bash
#!/usr/bin/env bash
docker exec -it claude-agent bash
```

`stop.sh`:
```bash
#!/usr/bin/env bash
docker stop claude-agent
colima stop
```

---

## Phase 7: VS Code integration

### 7.1 Install the extension

VS Code → Extensions → search "Dev Containers" (by Microsoft) → Install.

### 7.2 Attach to running container

1. `scripts/start.sh` to ensure Colima + container are running.
2. VS Code → `Cmd+Shift+P` → `Dev Containers: Attach to Running Container`.
3. Select `claude-agent`.
4. New VS Code window opens, running against the container's filesystem.
5. `File → Open Folder → /workspace/projects/<your-repo>` to work on a specific repo.

VS Code's integrated terminal in this window is a shell *inside* the container. Run `claude` there to start Claude Code.

### 7.3 Optional: `.devcontainer/devcontainer.json` (per-repo)

For repos you work on frequently, drop a `.devcontainer/devcontainer.json` inside them and VS Code will offer "Reopen in Container" automatically:

```json
{
  "name": "Claude Sandbox",
  "image": "claude-sandbox:latest",
  "workspaceFolder": "/workspace",
  "workspaceMount": "source=${localWorkspaceFolder},target=/workspace,type=bind",
  "mounts": [
    "source=/Volumes/T7/claude-agent/claude-home,target=/home/agent/.claude,type=bind"
  ],
  "remoteUser": "agent",
  "customizations": {
    "vscode": {
      "extensions": ["anthropic.claude-code"]
    }
  }
}
```

---

## Phase 8: Safety and recovery

### 8.1 Git discipline (non-negotiable for autonomous agents)

- Commit and push before giving Claude Code a complex task.
- Work on feature branches, not `main` or `master`.
- Consider `git worktree add ../repo-agent <branch>` so the agent operates on an isolated worktree while your main checkout stays clean.
- If the agent scrambles the repo, `git reset --hard origin/<branch>` or switch to a clean worktree.

### 8.2 Backup the external drive

Time Machine does not back up external drives by default. Either:
- System Settings → General → Time Machine → add `/Volumes/T7` as a source.
- Or use a separate backup tool (Arq, rsync to a second drive, cloud sync).

### 8.3 Drive failure recovery

If the drive fails or disconnects mid-run:
- VM crashes immediately — anything in container RAM is lost.
- Files already written to disk are recoverable from backup.
- Re-mount drive, `colima start`, `docker start claude-agent`, and you're back.

### 8.4 Token hygiene

- Files under `/Volumes/T7/claude-agent/claude-home/` contain your Claude OAuth token.
- Never commit them to git.
- Revoke at [claude.ai account settings](https://claude.ai/settings/) if drive is compromised.

---

## Phase 9: `.gitignore` for the setup repo

```gitignore
# Never commit auth or caches
/claude-agent/
/workspace-cache/
.claude/

# Local overrides
docker-compose.override.yml
.env
.env.*

# OS cruft
.DS_Store
```

---

## Phase 10: Verification checklist

After everything is set up, verify each layer:

- [ ] `colima status` — vz + virtiofs + aarch64
- [ ] `colima ssh -- ls /Volumes/T7` — VM sees drive mounts
- [ ] `colima ssh -- ls /Users` — should fail or be empty (Mac home NOT mounted)
- [ ] `docker run --rm claude-sandbox bubblewrap --version` — sandbox deps present
- [ ] `docker exec -it claude-agent claude whoami` — OAuth works
- [ ] Inside Claude Code: `/sandbox` shows auto-allow mode enabled
- [ ] Network allowlist works: `curl https://example.com` inside sandbox blocks; `curl https://api.github.com` allows
- [ ] Filesystem: `cat /home/agent/.ssh/id_rsa` inside sandbox fails (no such file, and denied even if it existed)
- [ ] VS Code attaches to container cleanly

---

## Maintenance

**Updating Claude Code:**
```bash
docker exec -it claude-agent sudo npm update -g @anthropic-ai/claude-code
# Or rebuild the image: docker build -t claude-sandbox:latest .
```

**Rebuilding the container image:**
```bash
docker build -t claude-sandbox:latest .
docker stop claude-agent && docker rm claude-agent
scripts/start.sh
```

**Growing the VM disk:**
```bash
colima stop
colima start --disk 120        # can grow, not shrink
```

**Full reset (nuclear option):**
```bash
docker stop claude-agent && docker rm claude-agent
colima delete
rm -rf /Volumes/T7/colima      # wipes VM disk
# Re-run Phase 2 onward
```

---

## Open questions to decide later

- **Rootless Docker inside the VM**: possible but adds complexity. Current setup relies on the VM as the security boundary. Revisit if threat model changes.
- **Per-project `devcontainer.json`**: useful if different projects need different tooling. Start with the single shared container and add per-project configs only when needed.
- **Multiple Colima profiles**: if you want fully separate sandboxes for different clients/projects, use `colima start <profile-name>`. Each gets its own VM. Overkill for starters.
- **Rotating the OAuth token**: not automatic. If you suspect compromise, revoke in Claude settings and re-run `claude login`.

---

## References

- Colima: https://colima.run/
- Claude Code sandboxing: https://code.claude.com/docs/en/sandboxing
- Claude Code permissions: https://code.claude.com/docs/en/permissions
- VS Code Dev Containers: https://code.visualstudio.com/docs/devcontainers/containers