# Virtiofs gotchas

Colima's virtiofs mount from macOS into the Lima VM mishandles several POSIX operations. Each gotcha here is a workaround in compose/Dockerfile that you must not "simplify" away.

## `.vscode-server` and `.cache` must be named volumes

Virtiofs on macOS mis-handles `utime()` and `chmod()` during archive/wheel extraction. Two concrete failure modes:

- **`tar: Cannot utime: Operation not permitted`** when the VS Code Dev Containers extension extracts the server tarball into `~/.vscode-server/`.
- **`failed to set permissions for file ... .so: Operation not permitted`** when uv/pip extracts wheels with compiled extensions (`lxml`, `pyarrow`, `psycopg[binary]`, `numpy`, etc.) into `~/.cache/uv/` — uv writes the `.so` then `chmod`s the exec bit; virtiofs returns EPERM because the UID-remapping path doesn't carry permission writes correctly across the macOS → Linux boundary.

Same root cause, same fix: named Docker volumes that live in the VM's ext4 and bypass virtiofs entirely. Trade-off: caches no longer host-visible. Fine — content-addressable, rebuild fast, nothing worth backing up.

If you ever add another package extracted by uv/pip/npm that explodes on permission errors during `--recreate`, **don't add it as another bind mount** — make it a named volume too, and pre-create the dir in the Dockerfile with `chown agent:agent`.

## `.claude.json` single-file bind mount needs chmod 644 AND valid JSON

Single-file bind mounts on Colima virtiofs don't remap UIDs the same way directory mounts do. A 600 file on the host appears as `root:root 600` inside the container → agent can't read. 644 → appears as `agent:agent 644`.

The file also must contain **valid JSON** — Claude rejects 0-byte files with `JSON Parse error: Unexpected EOF` and forces a reset prompt. `profile.sh`'s `ensure_state()` seeds `{}\n` with chmod 644 on first use (and re-seeds if the file is 0 bytes, so older broken profiles self-heal on next `up`).

`.credentials.json` inside `.claude/` stays 600 — it's inside a *directory* bind mount, which uses the directory-mount UID remapping path that works correctly.

## Why `.gitconfig` is NOT bind-mounted — use `GIT_CONFIG_GLOBAL` instead

Bind-mounting `~/.gitconfig` as a single file fails with `Device or resource busy` on any `git config --global` write. Root cause: `git config` writes atomically via `rename()` of a temp file over the target. `rename()` can't cross a single-file bind-mount boundary on virtiofs → EBUSY. `gh auth setup-git` hits this too.

Fix: don't mount `.gitconfig` at all. Set `GIT_CONFIG_GLOBAL=/home/agent/.config/git/config` in the compose env, mount the whole `.config/` **directory**. `rename()` within a directory-mounted filesystem works fine. `profile.sh`'s `ensure_state()` pre-creates `.config/git/`. Do not "simplify" by re-adding a `.gitconfig` bind mount — it will silently break `gh auth login` and any other tool that touches git config.

## tmpfs mounts under `/home/agent/` need `uid=1000,gid=1000`

A bare `tmpfs: - /path:size=N,nosuid,nodev` mount comes up owned by `root:root` mode 755 and shadows the Dockerfile-created dir → agent can't write → tools populating `~/.local/share` or `~/.npm-global` fail with `cannot make directory ... permission denied`. Always append `uid=1000,gid=1000,mode=0755` to tmpfs entries inside `/home/agent/`. Applies to `.local` and `.npm-global`; `/tmp` and `/run` are system dirs where root:root is correct.
