# Per-profile `dist/` for local wheels

Convention: `/Volumes/DataDrive/repo/<profile>/dist/` holds local `.whl` files (and other build artifacts) that should be installed into the profile's in-container venv but aren't on PyPI. Visible inside the container at `/workspace/dist/` because `/workspace` is the bind mount of the profile dir. Use this for sibling-repo libraries (e.g. paperbridge built from `nranthony/paperbridge`) instead of widening the proxy to a private index or grafting bind mounts onto cross-repo source.

## Workflow

```bash
# host: build the wheel from its source repo
cd /Volumes/DataDrive/repo/nranthony/<lib> && uv build
cp dist/<lib>-*.whl /Volumes/DataDrive/repo/<profile>/dist/

# container: install into the project venv
cd /workspace/<project> && source .venv-linux/bin/activate
uv pip install /workspace/dist/<lib>-*.whl
```

The directory is per-profile (no sharing) and lives on the external drive — survives container recreate AND VM rebuild. `dist/` matches the standard Python `.gitignore` entry, so wheels won't get committed by accident if a workspace is itself a git repo. This is the lightest of the three project-customization options; the heavier overlay Dockerfile pattern is in `overlay-project-plan.md`.

## Cross-environment `pyproject.toml` (the canonical pattern)

`uv pip install <wheel>` works once but a subsequent `uv sync` or `uv pip install -e ".[..."]` will rip it back out unless `pyproject.toml` declares the source. The pitfall: a host-absolute `path = "/Volumes/DataDrive/repo/nranthony/<lib>"` in `[tool.uv.sources]` blows up inside the container with `Distribution not found at: file:///Volumes/...` — only `/Volumes/DataDrive/repo/<profile>` is mounted (as `/workspace`), so cross-profile source paths aren't reachable. Fix is a platform-conditional source so host devs get the editable checkout and the container picks up the wheel from `/workspace/dist/`:

```toml
[tool.uv.sources]
<lib> = [
    { path = "/Volumes/DataDrive/repo/nranthony/<lib>",
      editable = true,
      marker = "platform_system == 'Darwin'" },
    { path = "/workspace/dist/<lib>-0.1.0-py3-none-any.whl",
      marker = "platform_system == 'Linux'" },
]
```

uv evaluates the marker per environment, so the same `pyproject.toml` resolves correctly on macOS (Darwin → editable host path) and inside the agent container (Linux → wheel in mounted dist/). Bump the wheel filename in lockstep with the upstream `version` field — uv won't fall back if the literal filename doesn't match.

## Gate 2 / Gate 3 — what the image enforces on every install (work/0001 A5)

Two config gates ship in the image. Both are defence-in-depth, not the sandbox
boundary; `scripts/verify-sandbox.sh` asserts the LIVE values on demand so drift
surfaces within one cycle.

| Gate | Where | Setting | Covers |
|---|---|---|---|
| 2 (npm) | `/usr/etc/npmrc` (image, root-owned) | `min-release-age=7` **DAYS**, `registry` pinned, `save-exact=true` | `npm` |
| 2 (pnpm) | `<profiles>/<p>/config/pnpm/rc` (bind mount) | `minimum-release-age=10080` **MINUTES** | `pnpm` |
| 3 (uv) | `/etc/uv/uv.toml` | `no-build = true` | `uv` |
| 3 (pip) | `/etc/pip.conf` | `only-binary = :all:`, index pinned | `pip` |

**The two Gate-2 units are different and both are correct.** npm counts DAYS,
pnpm counts MINUTES — `7` and `10080` are the same 7-day window. Do not
"harmonise" them to one number. A non-integer in the pnpm value is worse than
absent: pnpm computes `value * 60 * 1e3`, so `0s` yields `Invalid Date` and
rejects *every* version, which presents as a broken registry rather than as a
disabled gate.

**Why npm's lives in the image and pnpm's does not.** npm's `globalconfig`
derives from `prefix`, which here is `/home/agent/.npm-global` — **tmpfs**, wiped
on every recreate. So `NPM_CONFIG_GLOBALCONFIG` points npm at `/usr/etc/npmrc`
instead, which is in the image layer and root-owned: the UID-1000 agent cannot
edit it at all. pnpm's rc lives under `~/.config`, a persistent per-profile bind
mount the agent owns, and is seeded by `ensure_state`.

**Layer order is load-bearing** and `scripts/dockerfile-order.test.sh` locks it
on anchor strings: **claude/agy install < npmrc (Gate 2) < uv/pip (Gate 3)**.
`min-release-age` applies at *build* time too, so writing the npmrc above the CLI
install makes `@anthropic-ai/claude-code@latest` unresolvable whenever upstream
published inside the quarantine window — an intermittent break that appears on a
routine refresh, not on a cold build.

### Escaping a gate, when a build legitimately must happen

- **uv** has no per-package exemption. A project opts out wholesale with
  `no-build = false` in its own `uv.toml` / `[tool.uv]`.
- **pip** exempts one package with `no-binary = <name>` while `:all:` still
  covers the rest.
- **A whole install window** can be run without the Python age gate via
  `scripts/with-egress.sh <p> --allow-fresh "<reason>"`. The reason is required
  and lands in the audit record — an opt-out nobody can see later is not one.

`verify-sandbox.sh` reports project-level opt-outs under `/workspace` as WARN,
never FAIL: the workspace is your own repo and may have a considered reason.

**pip's refusal message is a trap:** "Could not find a version that satisfies the
requirement X (from versions: none)" is indistinguishable from the package not
existing — i.e. it looks exactly like a typosquat miss. uv's message names the
real reason. If a local wheel install fails that way, check Gate 3 before
assuming the package is gone.
