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
- **`config/.zshrc` runs `unset SSH_AUTH_SOCK`** — this is the *primary*, flow-independent SSH-env defense. It covers every path: VS Code attach (which ignores devcontainer.json `remoteEnv` entirely — see below), `profile.sh attach`, and any `docker exec` shell. Don't demote it to a fallback behind `remoteEnv`; `remoteEnv` does nothing on the attach flow.

## Attach-time config is host-side, not per-repo

`Attach to Running Container` ignores the repo's `.devcontainer/devcontainer.json` — that file is only consumed by `Reopen in Container`, which macolima doesn't use ([VS Code docs](https://code.visualstudio.com/docs/devcontainers/attach-container)). Attach-time customisation lives in the host-side **attached-container configuration file** (image- or name-keyed; `Dev Containers: Open Attached Container Configuration File`), which supports a subset: `workspaceFolder`, `extensions`, `settings`, `forwardPorts`, `remoteUser`.

`remoteEnv` is **not** in that subset — so emptying `SSH_AUTH_SOCK` via `remoteEnv` does nothing on attach. The actual, flow-independent SSH defense is `config/.zshrc`'s `unset SSH_AUTH_SOCK` plus the purge of `openssh-client`; treat those as load-bearing, not a devcontainer.json `remoteEnv`. `updateRemoteUserUID`/`overrideCommand` are likewise inert on attach (Reopen-only): macolima runs as `agent` (UID 1000) under compose regardless of flow, so the `usermod`-as-root orphan never arises on the Attach path.

The git-config-copy + credential-helper closure is a **host setting**, not a devcontainer.json key — set `dev.containers.copyGitConfig: false` and `dev.containers.gitCredentialHelperConfigLocation: "none"` in host user `settings.json` (see `README.md` §"Required host settings"). The host setting is what actually prevents re-injection on every attach.

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
