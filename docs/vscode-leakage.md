# VS Code Dev Containers leakage hardening

Host-side settings (the three `dev.containers.*` / `remote.SSH.*` keys) live in `README.md` §"Required host settings". This page covers the in-container and per-repo mechanics, plus the audit/tripwire posture.

## The leakage surface

VS Code's Dev Containers extension injects several host→container forwards that **bypass the sandbox network identity**:

- `SSH_AUTH_SOCK` + the underlying `/tmp/vscode-ssh-auth-*.sock` socket file.
- The host `.gitconfig` copied into the rootfs overlay (`copyGitConfig`).
- An IPC-backed `git-credential-helper` shim wired into `~/.config/git/config` (`gitCredentialHelperConfigLocation`).
- `VSCODE_GIT_ASKPASS_*` envs that route HTTPS auth prompts through host VS Code.

## In-container mitigations

Dockerfile + `config/.zshrc`:

- **`openssh-client` is purged.** Closes the SSH exfil path at the tool level: even if the env var + socket leak in, no `ssh`/`scp`/`ssh-add` exists to use them.
- **`config/.zshrc` runs `unset SSH_AUTH_SOCK`** so any interactive shell (including `docker exec` paths that bypass `devcontainer.json`'s `remoteEnv`) starts with the env cleared.

## Per-repo `devcontainer.json`

Canonical copy: `devcontainer-template/devcontainer.json`. Required keys:

- `"remoteUser": "agent"`, `"containerUser": "agent"` — match the Dockerfile USER.
- `"updateRemoteUserUID": false` — critical. Without this, VS Code runs `usermod` as root during attach to align UIDs, spawning a root shell that sometimes orphans (the "stray UID-0 process" drift seen in the pre-hardening audit).
- `"overrideCommand": false` — keep compose's `sleep infinity` as PID 1.
- `"remoteEnv": { "SSH_AUTH_SOCK": "" }` — the actual fix for SSH-agent injection. `remoteEnv` runs *after* VS Code's auto-injection and overrides the env. The socket file in `/tmp/` may still appear (cosmetic — it accumulates across reattaches and `/tmp` tmpfs only clears on `--force-recreate`) but the env is empty.
- Workspace-scoped fallback for git-config copy + credential helper, under `customizations.vscode.settings` (NOT a top-level `settings` key — that location was deprecated and is silently ignored, which masked H2-style drift in the 2026-04-25 audit):

  ```jsonc
  "customizations": { "vscode": { "settings": {
    "dev.containers.copyGitConfig": false,
    "dev.containers.gitCredentialHelperConfigLocation": "none"
  } } }
  ```

## Audit / tripwire posture (post-2026-05-09)

Both `scripts/audit/probes/env.py` (`no_vscode_ssh_socket`) and `scripts/verify-sandbox.sh` gate the socket check on the *combination* of mitigations — DRIFT/FAIL only fires when sockets are present AND (`SSH_AUTH_SOCK` set OR `ssh` resolvable). Pre-fix, both probes flagged the cosmetic-only state and shared the same blind spot.

**Don't revert that gating to a bare `glob`/`ls` check** — it produces false-positive DRIFT on every multi-attach session.

## `ensure_state()` defensive scrub

On every `up`, `profile.sh` scans `profiles/<p>/config/git/config` for helpers matching `vscode-server | vscode-remote-containers | osxkeychain | git-credential-manager` and strips only those lines.

VS Code re-injects the helper *on every attach*, *after* `ensure_state()` has already run — the scrub is a stale defense within an attach session; the host setting (`gitCredentialHelperConfigLocation: "none"`) is what actually prevents re-injection.

**The scrub intentionally preserves `!/usr/local/bin/glab auth git-credential` and `!/usr/local/bin/gh auth git-credential`** — legitimate in-container helpers installed by `glab/gh auth setup-git`, using in-container tokens with no host reach. Do not broaden the scrub to "any helper" — that would break authenticated `git push`. `verify-sandbox.sh`'s tripwire uses the same host-reaching patterns, so benign glab/gh helpers PASS.

## `VSCODE_GIT_ASKPASS_*` envs (informational)

The same attach mechanism exports `GIT_ASKPASS`, `VSCODE_GIT_ASKPASS_NODE`, `VSCODE_GIT_ASKPASS_MAIN`, `VSCODE_GIT_IPC_HANDLE`, routing `git` HTTPS auth prompts through host VS Code. With autonomous mode's `git push|clone|fetch|pull` denies these are dormant; in planning mode they become a host-reaching prompt path.

**Don't paste a host credential into a container `git` prompt** — VS Code will happily relay it.
