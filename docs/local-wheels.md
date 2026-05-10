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
