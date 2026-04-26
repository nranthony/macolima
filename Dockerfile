# =============================================================================
# macolima — hardened container image for Claude Code in auto/sandbox mode
# =============================================================================
# Design notes:
#   - Non-root user `agent` (UID 1000).
#   - No sudo. Tools are baked in at build time; if you need more, rebuild.
#   - Isolation comes from runtime: cap_drop: ALL, seccomp, no_new_privs,
#     internal network. Rootfs is NOT read-only (tried and removed — broke
#     VS Code Dev Containers with no security gain). See CLAUDE.md.
#   - Base image digest is pinned. First-time setup scripts update it.
# =============================================================================

FROM ubuntu:24.04@sha256:c4a8d5503dfb2a3eb8ab5f807da5bc69a85730fb49b5cfca2330194ebcc41c7b

LABEL description="Hardened sandbox for Claude Code on Colima/macOS"

# ---------- system packages --------------------------------------------------
# tini: PID 1 signal handling.
# bubblewrap + socat + openssh-client deliberately NOT installed:
#   - bwrap needs unprivileged user namespaces, which seccomp correctly
#     blocks — Claude Code's in-process sandbox can't run here anyway.
#   - socat was a raw-TCP exfil channel bypassing Squid's HTTP-only egress.
#   - openssh-client (ssh/scp/sftp/ssh-agent/...) is the tool surface that
#     would weaponize VS Code's SSH_AUTH_SOCK forwarding if it ever
#     reappears. Removing the package physically closes the SSH exfil path
#     even if the host-side VS Code setting reverts. No legitimate agent
#     workflow needs it: gh/glab authenticate with HTTPS tokens, git uses
#     HTTPS remotes, and agent-mode already denies `git push/clone/fetch`.
# Everything else: dev essentials for typical agent work.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git \
      tini \
      build-essential \
      python3 python3-pip python3-venv \
      ripgrep jq less vim-tiny \
      postgresql-client \
      zsh lsd fontconfig locales \
 && apt-get purge -y openssh-client \
 && if dpkg -l openssh-client 2>/dev/null | awk '/^ii/{found=1} END{exit !found}'; then \
      echo "FATAL: openssh-client still installed after purge — invariant violated" >&2; \
      exit 1; \
    fi \
 && apt-get autoremove -y \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ---------- Node.js + Claude Code -------------------------------------------
# Upgrade bundled npm first — NodeSource ships an older npm whose own
# vendored deps (cross-spawn, glob, minimatch, tar) accumulate CVEs between
# NodeSource publishes. Pulling latest npm before installing global packages
# means mongosh/claude-code get extracted by the newer tar, too.
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g npm@latest \
 && npm install -g @anthropic-ai/claude-code mongosh@latest \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ---------- uv (Python package manager) --------------------------------------
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
 && mv /root/.local/bin/uv /usr/local/bin/uv \
 && mv /root/.local/bin/uvx /usr/local/bin/uvx

# ---------- GitHub CLI (gh) -------------------------------------------------
RUN install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
 && chmod 0644 /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ---------- GitLab CLI (glab) — official binary ------------------------------
# Target: a release built with Go >= 1.26.2 (earlier Go stdlib has
# crypto/x509 + crypto/tls CVEs — CVE-2026-32280/32281/32283/33810).
# Latest as of 2026-04-21 is v1.92.1, still built with Go 1.26.1 — those
# CVEs are accepted via .trivyignore pending an upstream rebuild. Re-check
# https://gitlab.com/gitlab-org/cli/-/releases when bumping, and confirm
# the Go version in the release notes before expecting those CVEs to clear.
ARG GLAB_VERSION=1.92.1
RUN ARCH="$(dpkg --print-architecture)" \
 && case "$ARCH" in amd64) GARCH=x86_64 ;; arm64) GARCH=arm64 ;; *) echo "unsupported arch: $ARCH" >&2; exit 1 ;; esac \
 && curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_${GARCH}.tar.gz" \
      | tar -xz -C /tmp bin/glab \
 && mv /tmp/bin/glab /usr/local/bin/glab \
 && rm -rf /tmp/bin \
 && chmod 0755 /usr/local/bin/glab \
 && glab --version

# ---------- non-root user ----------------------------------------------------
# ubuntu:24.04 ships with a default `ubuntu` user at UID 1000 — remove it so
# we can create `agent` at that UID (needed to match host file ownership via
# virtiofs bind mounts).
RUN userdel -r ubuntu 2>/dev/null || true \
 && useradd --create-home --shell /bin/bash --uid 1000 agent \
 && mkdir -p /workspace /home/agent/.claude /home/agent/.cache /home/agent/.npm /home/agent/.vscode-server /home/agent/.config \
 && chown -R agent:agent /workspace /home/agent

# ---------- zsh + oh-my-zsh + powerlevel10k + plugins -----------------------
# Installed as the agent user so ownership is correct. Dotfiles are baked in.
COPY --chown=agent:agent config/.zshrc      /home/agent/.zshrc
COPY --chown=agent:agent config/.p10k.zsh   /home/agent/.p10k.zsh

USER agent
RUN set -eux; \
    export RUNZSH=no CHSH=no; \
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended --keep-zshrc; \
    ZSH_CUSTOM="$HOME/.oh-my-zsh/custom"; \
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git              "$ZSH_CUSTOM/themes/powerlevel10k"; \
    git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions.git      "$ZSH_CUSTOM/plugins/zsh-autosuggestions"; \
    git clone --depth=1 https://github.com/zsh-users/zsh-history-substring-search.git "$ZSH_CUSTOM/plugins/zsh-history-substring-search"; \
    git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git  "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"

# Pre-install gitstatusd into the image so p10k finds it locally on first
# shell start. Otherwise p10k fetches it from github.com/romkatv/gitstatus
# releases — which the autonomous proxy allowlist correctly blocks (we
# dropped the .github.com wildcard per audit M3). The plugin checks
# `$gitstatus_dir/usrbin/$file` BEFORE its $HOME/.cache fallback, so the
# binary placed there is shadowing-proof against the bind-mounted .cache
# (which gets nuked by `scripts/profile.sh <p> wipe`).
#
# Version + sha256 are pinned by p10k itself in install.info — we parse
# the entry that matches this build's uname -m so re-cloning p10k
# automatically picks up upstream's pin without a Dockerfile bump.
RUN set -eux; \
    GS_DIR="$HOME/.oh-my-zsh/custom/themes/powerlevel10k/gitstatus"; \
    uname_s="linux"; \
    uname_m="$(uname -m)"; \
    LINE="$(awk -v m="$uname_m" '/^uname_s_glob="linux"/ && $0 ~ "uname_m_glob=\""m"\""' "$GS_DIR/install.info" | head -1)"; \
    [ -n "$LINE" ] || { echo "no install.info entry for linux/$uname_m" >&2; exit 1; }; \
    eval "$LINE"; \
    URL="https://github.com/romkatv/gitstatus/releases/download/${version}/${file}.tar.gz"; \
    curl -fsSL "$URL" -o /tmp/gsd.tar.gz; \
    echo "${sha256}  /tmp/gsd.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/gsd.tar.gz -C "$GS_DIR/usrbin/"; \
    rm /tmp/gsd.tar.gz; \
    chmod +x "$GS_DIR/usrbin/$file"; \
    test -x "$GS_DIR/usrbin/$file"
USER root
RUN usermod -s /usr/bin/zsh agent

USER agent
WORKDIR /workspace

ENV HOME=/home/agent \
    PATH="/home/agent/.local/bin:${PATH}" \
    NPM_CONFIG_PREFIX="/home/agent/.npm-global" \
    SHELL=/usr/bin/zsh

# Expected runtime bind mounts (see docker-compose.yml):
#   /workspace              <- /Volumes/DataDrive/repo
#   /home/agent/.claude     <- /Volumes/DataDrive/.claude-colima/claude-home
#   /home/agent/.cache      <- /Volumes/DataDrive/.claude-colima/workspace-cache

ENTRYPOINT ["tini", "--"]
CMD ["bash"]
