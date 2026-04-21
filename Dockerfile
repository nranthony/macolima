# =============================================================================
# macolima — hardened container image for Claude Code in auto/sandbox mode
# =============================================================================
# Design notes:
#   - Non-root user `agent` (UID 1000).
#   - No sudo. Tools are baked in at build time; if you need more, rebuild.
#   - Root filesystem is made read-only at runtime (see docker-compose.yml).
#     Writable paths are provided via tmpfs / bind mounts.
#   - Base image digest should be pinned. First-time setup scripts update it.
# =============================================================================

FROM ubuntu:24.04@sha256:c4a8d5503dfb2a3eb8ab5f807da5bc69a85730fb49b5cfca2330194ebcc41c7b

LABEL description="Hardened sandbox for Claude Code on Colima/macOS"

# ---------- system packages --------------------------------------------------
# bubblewrap + socat: required by Claude Code's in-process sandbox.
# tini: PID 1 signal handling.
# Everything else: dev essentials for typical agent work.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git \
      bubblewrap socat tini \
      build-essential \
      python3 python3-pip python3-venv \
      ripgrep jq less vim-tiny \
      openssh-client \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ---------- Node.js + Claude Code -------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g @anthropic-ai/claude-code \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ---------- uv (Python package manager) --------------------------------------
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
 && mv /root/.local/bin/uv /usr/local/bin/uv \
 && mv /root/.local/bin/uvx /usr/local/bin/uvx

# ---------- non-root user ----------------------------------------------------
# ubuntu:24.04 ships with a default `ubuntu` user at UID 1000 — remove it so
# we can create `agent` at that UID (needed to match host file ownership via
# virtiofs bind mounts).
RUN userdel -r ubuntu 2>/dev/null || true \
 && useradd --create-home --shell /bin/bash --uid 1000 agent \
 && mkdir -p /workspace /home/agent/.claude /home/agent/.cache /home/agent/.npm \
 && chown -R agent:agent /workspace /home/agent

USER agent
WORKDIR /workspace

ENV HOME=/home/agent \
    PATH="/home/agent/.local/bin:${PATH}" \
    NPM_CONFIG_PREFIX="/home/agent/.npm-global"

# Expected runtime bind mounts (see docker-compose.yml):
#   /workspace              <- /Volumes/DataDrive/repo
#   /home/agent/.claude     <- /Volumes/DataDrive/.claude-colima/claude-home
#   /home/agent/.cache      <- /Volumes/DataDrive/.claude-colima/workspace-cache

ENTRYPOINT ["tini", "--"]
CMD ["bash"]
