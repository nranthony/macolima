# ADR-0013 — The environment names the venv, not the repo

- **Status:** Accepted (2026-09-11)
- **Deciders:** nranthony + agent
- **Work item:** `work/0008-venv-per-environment/`

## Context

`/workspace` is the host's checkout, bind-mounted. So every Python repo is seen
by two environments at once, the host and the profile's container, and both
default to `<repo>/.venv`. A venv is not portable: `.venv/bin/python` is a
symlink to one interpreter on one machine.

The failure is worse than "one side is broken". **uv, finding a project
environment whose interpreter it cannot use, deletes and recreates it.** A `uv run`
in the container silently replaced the host's working venv with a Linux one,
and the next `uv run` on the host did the reverse. Both happened in practice:
one tool repo's `.venv` ended up container-built, and another's host venv was
dead inside the container.

Repos had worked around it one at a time, and inconsistently: a justfile choosing
`.venv` vs `.venv-linux` by `os()`, scripts hard-coding `.venv-linux/bin/python`,
a `CLAUDE.md` telling agents to `export UV_PROJECT_ENVIRONMENT=.venv-linux`.
**Selecting by OS is wrong in principle:** the sibling (`windows-ai-sandbox`)
mounts the checkout from inside WSL, so its host and its container are both
Linux and both pick `.venv-linux`.

## Decision

**The environment names the venv; a repo never chooses it.**

| Where | `UV_PROJECT_ENVIRONMENT` | Venv |
|---|---|---|
| Any sandbox container: this repo (Colima, arm64) and the sibling (Docker on WSL / bare Linux, x86_64) | `.venv-sandbox`, from compose `environment:` | `<repo>/.venv-sandbox` |
| Any host: macOS, WSL, bare Linux, CI runners | **unset** | `<repo>/.venv` (uv's default) |

uv reads the variable on every `uv run` / `uv sync` / `uv venv`, and a
**relative** value resolves against the project root, not the CWD. That was
verified in this image with uv 0.12.9, from a subdirectory and via
`uv run --project` from a parent. So one value serves every repo, and the
container's uv never sees the host's `.venv`.

Repos follow from that:
- they run things through `uv run …`;
- where a path is unavoidable, they derive it from `UV_PROJECT_ENVIRONMENT`
  with `.venv` as the fallback;
- they never select a venv by OS;
- they gitignore `.venv*/`;
- they pin a tracked `.python-version`, to a minor every environment has. This
  image bakes 3.12 and 3.13; unpinned, uv takes the newest.

That repo-side half is the `agentic-conventions` rule (its own ADR), vendored
here as `myconv`.

**The one exception:** two *hosts* sharing one checkout, e.g. Windows-native
Python and WSL both working in `/mnt/c`, or a folder synced between machines.
Both are hosts, so both pick `.venv`, and that pair alone needs per-host names
set in each host's shell profile. None is known.

## Consequences

- `docker-compose.yml` sets the variable next to `UV_LINK_MODE`. It's
  runtime-only, so a change needs a recreate, not a rebuild.
  `verify-sandbox.sh` fails on unset, absolute, or any other name.
- **The deletion hook's disposable exception is `.venv-sandbox`, and no longer
  `.venv`.** From inside the container a plain `.venv` is the host's venv, so
  deleting in it now reaches the prompt. The name is matched exactly, because
  targets are wrapped in slashes and `*/.venv*/*` would also pass a file named
  `.venvrc`.
- The sandbox notice tells agents which venv is theirs and not to set the
  variable themselves.
- **Rollout order: switch first, repos after.** Merging the compose line is the
  switch for every profile at its next recreate, and until a profile has
  switched, a container `uv run` is itself the destructive command. So all
  profiles are recreated in one sitting, and only then are repos edited, in
  final form. No repo doc carries transitional "if the variable is unset…"
  wording; the one precondition check lives in the disposable handoffs.
- **Only uv's project commands read the variable** (`run`, `sync`, `venv`).
  The `uv pip` interface ignores it and uses `VIRTUAL_ENV` or a `.venv` in the
  current directory, which in the container is the host's. Measured with uv
  0.12.9. So a `uv pip` call names its target: `--python .venv-sandbox` (a venv
  directory is accepted). The agent is denied `uv pip install` regardless; this
  is for humans in a container shell and for read-only `uv pip list` / `show`.
- A venv is rebuilt, never renamed: console-script shebangs are absolute.
- Retiring the old venvs (`.venv-linux`, container-built leftovers in `.venv`
  slots) is a human deletion after a soak, and they're classified by their
  console-script shebangs (`#!/workspace/…` = container-built). `pyvenv.cfg`
  `home` can't tell the two apart on a Linux host.
- `scripts/workspace-scan.py` checks every profile's repos host-side, and
  `--fail-on HARDCODED-VENV-LINUX,OS-VENV-SELECT` is the "migration finished"
  check.

## Rejected alternatives

- **Per-OS names** (`.venv-linux` in the container). A Linux host and a Linux
  container collide, which is live on the sibling.
- **Per-host names on every host** (`.venv-mac`, `.venv-wsl`, …). Every host's
  shell profile would need the variable, and every existing host venv would be
  rebuilt, to solve a collision only the container side has.
- **An architecture suffix** (`.venv-sandbox-arm64`). Each sandbox shares a
  checkout only with its own host, and a wrong-arch venv would be recreated by
  uv, not lost.
- **`UV_PYTHON` in the image.** It is `--python`, so it overrides every repo's
  `.python-version`.
- **Dockerfile `ENV`.** Every change would be a rebuild, and the build has no
  bind mounts for the variable to matter in.
- **"Repos first", with fallback wording in repo docs** (read the variable, else
  `.venv-linux`). It was drafted and withdrawn the same day: it put transitional
  text into repos for a window that switching first removes.
- **A per-profile opt-in variable.** A permanent mechanism to solve a one-time
  ordering problem.
