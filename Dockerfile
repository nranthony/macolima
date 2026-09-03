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
# Scopes `docker image prune` to images WE built — see IMAGE_PRUNE_FILTER
# in scripts/profile.sh for why an unfiltered daemon-wide prune is unsafe
# on a shared Colima daemon.
LABEL sandbox.image=macolima

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
#     workflow needs it: gh authenticates with HTTPS tokens, git uses
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
      zsh lsd fontconfig locales lsof \
 # CVE-2026-45447 (openssl/libssl3t64): the FROM digest pin above has not been
 # rebuilt upstream, so re-pulling it fetches identical, still-vulnerable bytes
 # and cannot clear the finding. This upgrades exactly the two flagged packages
 # while leaving the base digest — and its reproducibility — untouched.
 # Ported from windows-ai-sandbox e6bca33 (work/0001 Phase 0b).
 && apt-get install -y --only-upgrade openssl libssl3t64 \
 && apt-get purge -y openssh-client \
 && if dpkg -l openssh-client 2>/dev/null | awk '/^ii/{found=1} END{exit !found}'; then \
      echo "FATAL: openssh-client still installed after purge — invariant violated" >&2; \
      exit 1; \
    fi \
 && apt-get autoremove -y \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ---------- Playwright / Chromium runtime libraries --------------------------
# Headless Chromium (used by Crawl4AI for JS-heavy vendor SDK portals) needs
# ~20 shared libraries that the base ubuntu:24.04 image doesn't ship with —
# X/Wayland/audio/font/cups/dbus surface that Chromium dynamically loads even
# in --no-sandbox headless mode. Without these the binary won't start, even
# after `playwright install chromium` succeeds in fetching the build to disk.
#
# Why baked in (not `playwright install-deps` at runtime):
#   - The agent runs as UID 1000 with cap_drop: ALL + no_new_privs=1; sudo
#     is neutralized, and `apt-get` can't write to /var/lib/dpkg anyway.
#   - Per CLAUDE.md planning/autonomous discipline, OS-package installs are
#     a build-time concern — not a runtime activity for any agent.
#   - The list is stable across Playwright versions, so this is one-time.
#
# Adds ~150 MB to the image. Justifiable: any future research profile doing
# JS-heavy crawling reuses the same libs. If a slim profile turns up that
# explicitly doesn't want browser deps, promote to a per-profile overlay
# Dockerfile (see docs/overlay-project-plan.md).
#
# The `t64` suffix on several packages (libcups2t64, libatk1.0-0t64, ...)
# is Ubuntu 24.04's 64-bit-time rebuild of those libraries — required, not
# optional, on this base image.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libglib2.0-0t64 libnspr4 libnss3 \
      libatk1.0-0t64 libatk-bridge2.0-0t64 libatspi2.0-0t64 \
      libdbus-1-3 libcups2t64 \
      libxcb1 libxkbcommon0 libx11-6 libxcomposite1 libxdamage1 \
      libxext6 libxfixes3 libxrandr2 \
      libgbm1 libcairo2 libpango-1.0-0 libasound2t64 \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ---------- Node.js (runtime + npm-global tooling) ---------------------------
# Upgrade bundled npm first — NodeSource ships an older npm whose own
# vendored deps (cross-spawn, glob, minimatch, tar) accumulate CVEs between
# NodeSource publishes. Pulling latest npm before installing global packages
# means mongosh/claude-code get extracted by the newer tar, too.
#
# pnpm: real npm-global install, NOT `corepack enable` (parity with
# windows-ai-sandbox). The corepack shim downloads pnpm lazily at first use —
# registry.npmjs.org is not in the egress allowlist, so the shim can never
# resolve inside the sandbox. Repo `packageManager` pins are deliberately
# ignored at runtime: pnpm 10's own version manager re-execs a downloaded
# pnpm from ~/.local/share/pnpm/.tools/ (noexec tmpfs → EACCES), so
# ensure_state seeds manage-package-manager-versions=false into the
# per-profile ~/.config/pnpm/rc. Pins stay honored on host/CI.
#
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && npm install -g npm@latest \
 && npm install -g mongosh@latest pnpm@10 \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ---------- uv (Python package manager) --------------------------------------
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
 && mv /root/.local/bin/uv /usr/local/bin/uv \
 && mv /root/.local/bin/uvx /usr/local/bin/uvx

# WHERE `uv tool install` PUTS THINGS — pinned, because both defaults are wrong
# here in the same way. Probed inside this image (uv 0.12.8):
#
#   uv tool dir        -> /home/agent/.local/share/uv/tools
#   uv tool dir --bin  -> /home/agent/.local/bin
#
# `/home/agent/.local` is a NOEXEC tmpfs (docker-compose.yml) recreated empty at
# container start, and PATH puts it first (see the ENV block at the tail). So an
# unpinned `uv tool install` builds green, prints a correct version in the build
# log, and delivers nothing at runtime — the binary is both unrunnable and gone.
# /opt is persistent and exec-allowed; /usr/local/bin is where every other baked
# binary lives (agy, just, uv itself), and is on PATH for every user.
#
# These are RUNTIME env too, deliberately. The agent cannot write either path
# (root-owned, UID 1000, cap_drop ALL), so an in-container `uv tool install`
# fails closed rather than scattering a tool into the tmpfs. That matches the
# `Bash(uv tool install:*)` deny in claude-settings.json: bumps are host-side —
# vendor, `profile.sh build`, recreate.
ENV UV_TOOL_DIR=/opt/uv/tools \
    UV_TOOL_BIN_DIR=/usr/local/bin

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

# GitLab CLI (glab) intentionally NOT installed — this setup is GitHub-only.
# gh (above) is the sole forge CLI. If GitLab support is ever needed again,
# re-add a checksum-verified install here AND restore the [git] gitlab.com
# allowlist entries, the profile.sh/setup.sh auth-gitlab paths, the
# Bash(glab:*) deny, and the .trivyignore glab block.

# ---------- just (command runner) — official static binary -------------------
# `just` is a single static musl binary, so it has no glibc/runtime deps and
# drops straight into /usr/local/bin. Not apt-installable on noble, and the
# agent can't fetch it at runtime anyway (github.com is off the proxy
# allowlist + no root for apt) — so it must be baked in here, where the build
# has full network. Checksum-verified like gitstatusd: GitHub publishes
# SHA256SUMS per release; we fetch it, grep our exact tarball's line, and
# sha256sum -c before trusting the binary. When bumping JUST_VERSION just update the ARG —
# the checksum is fetched fresh per build over TLS, no manual pin needed.
# Re-check https://github.com/casey/just/releases when bumping.
ARG JUST_VERSION=1.51.0
RUN ARCH="$(dpkg --print-architecture)" \
 && case "$ARCH" in amd64) GARCH=x86_64 ;; arm64) GARCH=aarch64 ;; *) echo "unsupported arch: $ARCH" >&2; exit 1 ;; esac \
 && TARBALL="just-${JUST_VERSION}-${GARCH}-unknown-linux-musl.tar.gz" \
 && BASE="https://github.com/casey/just/releases/download/${JUST_VERSION}" \
 && curl -fsSL "$BASE/$TARBALL" -o "/tmp/$TARBALL" \
 && curl -fsSL "$BASE/SHA256SUMS" -o /tmp/just_checksums.txt \
 && grep -E "  $TARBALL\$" /tmp/just_checksums.txt > /tmp/just_checksum.line \
 && (cd /tmp && sha256sum -c just_checksum.line) \
 && tar -xzf "/tmp/$TARBALL" -C /tmp just \
 && mv /tmp/just /usr/local/bin/just \
 && rm -rf "/tmp/$TARBALL" /tmp/just_checksums.txt /tmp/just_checksum.line \
 && chmod 0755 /usr/local/bin/just \
 && just --version

# ---------- AI CLI refresh layer (Claude Code + Antigravity agy) -------------
# Deliberately the LAST heavy build step, and split out of the Node layer above
# on purpose: bumping either CLI must rebuild only this tail, not apt/Playwright/
# Node/uv/gh/just. Routine version bumps go from a multi-minute rebuild to a
# seconds-long tail rebuild:
#   scripts/profile.sh build --refresh-ai            # latest of BOTH CLIs
#   scripts/profile.sh build --claude-version=1.2.3  # pin claude (implies refresh)
# AI_CLI_REFRESH is a cache-buster token — those flags pass a fresh value so this
# RUN re-executes and pulls upstream. Untouched, it stays cached.
#
# It cannot move any later: Gate 2 below writes min-release-age, which applies to
# `npm install` at BUILD time too, so any claude install after it becomes
# unresolvable whenever the newest release is inside the quarantine window.
# scripts/dockerfile-order.test.sh locks that ordering.
#
# agy: Google's Antigravity CLI (replaces the former Gemini CLI). Native
# binary to /usr/local/bin via --dir, NOT the installer default ~/.local/bin
# (noexec tmpfs at runtime — see docker-compose.yml — so a binary there can't
# run or survive a recreate). The installer sha512-verifies the payload
# against its signed manifest. This step runs on the host network, bypassing
# Squid; RUNTIME auth/API hosts are gated in proxy/allowed_domains.txt under
# [antigravity]. Sign in at the container console (`scripts/profile.sh <p>
# auth-antigravity`, or just `agy`); config lives under
# ~/.gemini/antigravity-cli/ (agy reuses the ~/.gemini home — the per-profile
# gemini-home mount is kept, so auth persists across recreates).
# --allow-scripts=@anthropic-ai/claude-code is REQUIRED, not cosmetic. npm 12
# blocks lifecycle scripts by default, and the claude package fetches its
# platform-native binary in a postinstall. Without the flag the install
# "succeeds" and leaves /usr/bin/claude -> claude.exe, a stub whose entire body
# is `echo "Error: claude native binary not installed."`. The CLI is then broken
# while `command -v claude` still passes, which is why verify-sandbox.sh's
# presence check never noticed. That was the live state in this image until
# work/0001 A5's Gate 2 layer ran `claude --version` and the build failed.
# Scoped to the one package: it is an allowlist, not a blanket re-enable.
ARG AI_CLI_REFRESH=0
ARG CLAUDE_VERSION=latest
RUN npm install -g --allow-scripts=@anthropic-ai/claude-code "@anthropic-ai/claude-code@${CLAUDE_VERSION}" \
 && curl -fsSL https://antigravity.google/cli/install.sh | bash -s -- --dir /usr/local/bin \
 && claude --version \
 && /usr/local/bin/agy --version

# ---------- Gate 2 (npm): publication quarantine + registry pin --------------
# Refuse to resolve anything published in the last 7 days. A malicious release
# of a real package is typically pulled within hours-to-days; a quarantine
# window costs latency on genuinely new versions and buys immunity to that
# whole class.
#
# Why config and not the deny list: `permissions.deny` keys on a command PREFIX,
# so it is routed around by any wrapper (`make`, `just`, `npm run`, `uv run` —
# all allow-listed) and does not constrain the human's interactive zsh at all.
# An npmrc gate is invocation-path independent: it fires no matter what reached
# the installer, and it fires for the human too.
#
# ORDER IS LOAD-BEARING: this MUST come after the claude/agy install above.
# min-release-age applies to `npm install` at BUILD time as well, so writing it
# earlier would make `@anthropic-ai/claude-code@latest` unresolvable whenever
# the newest release is inside the quarantine window — a self-inflicted, and
# INTERMITTENT, build break: it depends on when upstream last published, so it
# passes today and fails next week. scripts/dockerfile-order.test.sh locks the
# chain on anchor strings so this cannot silently reorder.
#
# macolima divergence from windows-ai-sandbox, and it matters. There
# prefix=/usr, so npm's globalconfig is /usr/etc/npmrc and lives in the image.
# Here NPM_CONFIG_PREFIX is /home/agent/.npm-global, which is **tmpfs** (see the
# volatile list in CLAUDE.md) — so npm's default globalconfig path is wiped on
# every container recreate and a gate written there would silently vanish.
# NPM_CONFIG_GLOBALCONFIG therefore points npm at an image path explicitly.
# Verified in the running image: npm honours the variable and reports the
# values below via `npm config get`.
#
# Stronger here than upstream, for once: /usr/etc/npmrc is root-owned and the
# agent runs as UID 1000 with no sudo and no_new_privs, so the agent cannot edit
# it at all. In windows-ai-sandbox the agent is root and can.
#
# KNOWN GAP, deliberately not widened here: this gates **npm**, not **pnpm**.
# pnpm reads npmrc files but its quarantine key is `minimum-release-age`
# (minutes), not npm's `min-release-age` (days), so pnpm installs are NOT
# covered. windows-ai-sandbox has the same gap. macolima ships pnpm@10 and the
# workspace uses it, so this matters more here — but closing it is a scope
# decision, not a port, and belongs in its own item.
#
# NOT setting ignore-scripts=true: npm 12 already blocks lifecycle scripts by
# default, and setting both risks interacting with the CLI install above.
ENV NPM_CONFIG_GLOBALCONFIG=/usr/etc/npmrc
RUN mkdir -p /usr/etc \
 && printf '%s\n' \
      '# Managed by Dockerfile — see the Gate 2 block there before editing.' \
      '# Quarantine: refuse to resolve anything published in the last N days.' \
      'min-release-age=7' \
      '# Pin resolution to the official registry rather than relying on the default.' \
      'registry=https://registry.npmjs.org/' \
      '# Refuse to silently rewrite version ranges — makes lockfile diffs reviewable.' \
      'save-exact=true' \
    > /usr/etc/npmrc \
 && npm config get min-release-age | grep -qx 7 \
 && npm config get save-exact | grep -qx true \
 && claude --version

# ---------- Gate 3 (Python): wheels only ------------------------------------
# An sdist runs setup.py (or a PEP-517 backend) at INSTALL time — it is the
# exact Python analogue of an npm lifecycle script. Blocking source builds costs
# a small fraction of packages and buys default-deny against the next one.
#
# BOTH tools need configuring and they do NOT share config:
#   uv  reads /etc/uv/uv.toml   (it reads no pip config at all)
#   pip reads /etc/pip.conf
#
# Escape hatches differ, which matters when a build legitimately must happen:
#   uv  — no per-package exemption exists. A project opts OUT wholesale with
#         `no-build = false` in its own uv.toml / [tool.uv].
#   pip — `no-binary = <pkg>` exempts one package while `:all:` covers the rest.
#
# pip's refusal message is a trap worth knowing: "Could not find a version that
# satisfies the requirement X (from versions: none)" is indistinguishable from
# the package not existing — i.e. it looks exactly like a typosquat miss. uv's
# message names the real reason.
#
# Config-only and last in the chain: it has no build-time dependency of its own,
# so a change here rebuilds nothing above it.
RUN mkdir -p /etc/uv \
 && printf '%s\n' \
      '# Managed by Dockerfile — see the Gate 3 block there before editing.' \
      '# Refuse to build source distributions: an sdist executes code at install' \
      '# time, a wheel does not. Override per project with no-build = false.' \
      'no-build = true' \
    > /etc/uv/uv.toml \
 && printf '%s\n' \
      '[global]' \
      '# Managed by Dockerfile. No extra-index-url: dependency-confusion vector.' \
      'index-url = https://pypi.org/simple' \
      '# Wheels only — sdists run setup.py at install time (Gate 3).' \
      '# Exempt a single package with:  no-binary = <name>' \
      'only-binary = :all:' \
    > /etc/pip.conf \
 && uv --version

# ---------- non-root user ----------------------------------------------------
# ubuntu:24.04 ships with a default `ubuntu` user at UID 1000 — remove it so
# we can create `agent` at that UID (needed to match host file ownership via
# virtiofs bind mounts).
RUN userdel -r ubuntu 2>/dev/null || true \
 && useradd --create-home --shell /bin/bash --uid 1000 agent \
 && mkdir -p /workspace /home/agent/.claude /home/agent/.cache /home/agent/.npm /home/agent/.vscode-server /home/agent/.config /home/agent/.gemini \
 && chown -R agent:agent /workspace /home/agent

# ---------- zsh + oh-my-zsh + powerlevel10k + plugins -----------------------
# Installed as the agent user so ownership is correct. Dotfiles are baked in.
COPY --chown=agent:agent sandbox_templates/common/.zshrc      /home/agent/.zshrc
COPY --chown=agent:agent sandbox_templates/common/.p10k.zsh   /home/agent/.p10k.zsh

# ---------- webfetch — the web-read broker ----------------------------------
# curl/wget are DENIED to the agent and the real WebFetch tool is scoped per
# repo, so the agent reads the open web ONLY through a hosted reader API that is
# already allowlisted ([web-read] in proxy/allowed_domains.txt). The vendor does
# the arbitrary-URL egress from ITS infrastructure and returns clean text, so
# this repo's own egress surface never grows to the dozens of research/UGC/PDF
# domains a direct-fetch design would need.
#
# stdlib-only Python, so it needs no pip layer and cannot drift with a
# dependency; urllib honours HTTPS_PROXY, so every request still goes through
# the Squid sidecar. Keys come from the per-profile secrets.env env_file and
# never from argv — argv lands in the Bash-tool transcript and Squid logs URLs.
#
# Baked into the image rather than mounted: /home/agent/.local is a noexec
# tmpfs, so a broker delivered through a profile dir would be both unrunnable
# and wiped on recreate. See docs/web-read-broker.md.
COPY sandbox_templates/bin/webfetch /usr/local/bin/webfetch
RUN chmod 0755 /usr/local/bin/webfetch

# ---------- PreToolUse hook (deny-destructive) ------------------------------
# Inspects every Bash/Edit/Write/MultiEdit tool envelope; blocks destructive
# primitives reachable through allow-listed prefixes (find -delete, dd of=,
# git clean, etc.) and any write targeting the hook script or live
# settings.json. Root-owned, world-readable, world-executable. Agent (UID
# 1000) has no tool path that bypasses the kernel's write-protect on this
# file (the matched Edit-tamper rule is defence in depth). Updates require
# image rebuild — intentional friction. See docs/deny-destructive-hook-plan.md.
COPY --chown=root:root sandbox_templates/claude/hooks/deny-destructive.sh /usr/local/lib/claude-hooks/deny-destructive.sh
RUN chmod 0755 /usr/local/lib/claude-hooks/deny-destructive.sh

# The SAME script, reached by a second name for the second agent. `agy`'s
# hooks.json points at /usr/local/lib/sandbox-hooks/guardrails.sh and passes
# --dialect=antigravity; one rule table serves both, so a rule added for Claude
# protects Antigravity in the same edit.
#
# A SYMLINK, not a copy — two copies could diverge on disk and the divergence
# would be invisible until one agent enforced a rule the other did not. And the
# claude-hooks path stays canonical because every already-seeded profile's
# settings.json names it: adding the second name must not require an existing
# profile to converge before its hook works again.
RUN mkdir -p /usr/local/lib/sandbox-hooks \
 && ln -sf /usr/local/lib/claude-hooks/deny-destructive.sh \
           /usr/local/lib/sandbox-hooks/guardrails.sh

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

# ---------- myclickup — vendored ClickUp CLI (OPTIONAL payload) --------------
# Zero-dependency pure-Python wheel from the PRIVATE nranthony/myclickup repo,
# delivered through the depot channel. `docker-compose.yml` sets
# `build.context: .`, so a sibling checkout is unreachable from the build and the
# artifact has to be inside the context; a network install would need a deploy
# token inside the build of a security-critical image. Host-side
# `scripts/vendor-tools.sh` puts it here, hash-gated against manifest.toml.
#
# THE PAYLOAD IS GITIGNORED — this repo is public, myclickup is not, and a
# py3-none-any wheel is a zip of the .py files. Two consequences are encoded in
# the two unusual things about this block:
#
#   1. DIRECTORY copy, not `COPY .../myclickup-*.whl`. A COPY whose glob matches
#      nothing is a hard build failure, so the paste-ready form would break every
#      clone that lacks the payload. The tracked `.gitkeep` keeps the directory
#      in the context.
#   2. CONDITIONAL install. No wheel => no myclickup, build still green. A clone
#      of this repo therefore does NOT reproduce this image bit-for-bit; that is
#      the accepted cost of not publishing a private tool.
#
# Two wheels is a REFUSAL, not a pick-one: the vendor script rotates the file on
# every bump, so two means a failed rotation, and choosing silently would ship
# the wrong version behind a correct-looking `myclickup --version`.
#
# --python /usr/bin/python3 + UV_PYTHON_DOWNLOADS=never are NOT belt-and-braces.
# uv's python-downloads defaults to automatic, so an unpinned install may fetch a
# managed CPython into a root-owned directory UID 1000 cannot read — a build that
# passes and a runtime that does not. The system 3.12.3 satisfies the wheel's
# `>=3.11`, so the correct interpreter is already here; pinning makes a surprise
# a hard build failure instead.
#
# THE SECOND VERSION CHECK IS THE LOAD-BEARING ONE. windows-ai-sandbox runs the
# agent as root, so its in-layer `myclickup --version` runs as its runtime user.
# Here the runtime user is `agent` (UID 1000), and a root-only check would prove
# nothing about who actually runs the tool — exactly the gap that lets a
# permissions or interpreter mistake through with a green build log.
#
# Placed in the root interlude at the TAIL, below Gate 3 and the AI-CLI
# cache-buster: pre-1.0 this is the most frequently re-vendored artifact in the
# tree. Above the zsh block it would re-run oh-my-zsh, three plugin clones and
# the gitstatusd release download on every bump; above the cache-buster it would
# re-run the Claude Code/agy install and both gates. scripts/dockerfile-order.test.sh
# locks the position.
#
# Verified 2026-09-02 in this image under `--network none`: the install needs no
# network (zero Requires-Dist), passes Gate 3's `no-build = true` because a wheel
# is never built, and resolves for both root and agent.
COPY sandbox_templates/wheels/ /tmp/wheels/
RUN set -eu; \
    n="$(find /tmp/wheels -maxdepth 1 -name 'myclickup-*.whl' | wc -l)"; \
    if [ "$n" -gt 1 ]; then \
      echo "myclickup: $n wheels in sandbox_templates/wheels/ - refusing to guess" >&2; \
      exit 1; \
    elif [ "$n" -eq 1 ]; then \
      whl="$(find /tmp/wheels -maxdepth 1 -name 'myclickup-*.whl')"; \
      UV_PYTHON_DOWNLOADS=never uv tool install --python /usr/bin/python3 "$whl"; \
      myclickup --version; \
      su -s /bin/sh agent -c 'myclickup --version'; \
    else \
      echo "myclickup: no vendored wheel - skipping (run: just vendor-tools)"; \
    fi; \
    rm -rf /tmp/wheels

USER agent
WORKDIR /workspace

ENV HOME=/home/agent \
    PATH="/home/agent/.local/bin:${PATH}" \
    NPM_CONFIG_PREFIX="/home/agent/.npm-global" \
    SHELL=/usr/bin/zsh

# Expected runtime mounts (see docker-compose.yml):
#   /workspace                <- bind: /Volumes/DataDrive/repo/<profile>
#   /home/agent/.claude       <- bind: profiles/<profile>/claude-home
#   /home/agent/.config       <- bind: profiles/<profile>/config
#   /home/agent/.cache        <- named volume `cache`        (virtiofs-incompatible: wheel chmod)
#   /home/agent/.vscode-server <- named volume `vscode-server` (virtiofs-incompatible: tar utime)

ENTRYPOINT ["tini", "--"]
CMD ["bash"]
