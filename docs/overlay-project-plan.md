# Per-project overlay Dockerfile — design plan

Source-of-truth for current invariants is `CLAUDE.md`. This file is a deferred
implementation plan for adding **per-project image customization** to
macolima while preserving the shared-base + per-profile-state model. Not yet
implemented as of 2026-04-26.

## Why

Profiles today share a single `macolima:latest` image. Anything beyond the
base toolchain has three options, all of them flawed:

1. **Bake into the shared image** — every profile pays the disk + build cost
   for things only one project uses (e.g. ~600 MB Playwright/Chromium for
   wearables; CUDA wheels for an ML profile).
2. **Runtime install into `/workspace/.venv-linux`** — works, but each `up`
   needs the planning-mode proxy block opened for installs, and the install
   isn't reproducible without checking the env into the workspace.
3. **Manually fork the Dockerfile** — drift, no shared base updates.

The overlay convention adds a fourth option: opt-in, per-profile, layered on
top of the shared base.

## Shape

Three optional files per profile:

```
profiles/<p>/
  Dockerfile.overlay      # FROM macolima:latest + project additions
  build.env               # BUILD_CONTEXT / additional_contexts overrides
  post-up.sh              # runtime init, run once after `up` (lighter alt)
```

- **`Dockerfile.overlay` present** → `scripts/profile.sh build` builds
  `macolima-<p>:latest` from the overlay. Compose uses that image instead of
  the shared base.
- **`Dockerfile.overlay` absent** → current behaviour: shared `macolima:latest`.
- **`post-up.sh` present** → `profile.sh up` runs it once after the container
  is healthy (idempotent — script must guard with a sentinel file like
  `/home/agent/.cache/.post-up-done`).

Two-tier ergonomics: overlay for "I need a new package baked in" cases,
post-up for "I need a runtime install into the workspace venv" cases.

## Compose change

Single line in `docker-compose.yml`:

```yaml
claude-agent:
  image: macolima${PROFILE_IMAGE_SUFFIX:-}:latest
```

`profile.sh` exports `PROFILE_IMAGE_SUFFIX=-<profile>` when an overlay exists
for that profile, empty otherwise. Existing profiles without an overlay see
no behavioural change.

## Cross-repo source (the paperbridge case)

Build context is the dir passed to `docker build`. To include a sibling repo
(e.g. paperbridge under a different parent dir than macolima), don't widen
the main `context:` — that ships everything to the daemon. Use BuildKit's
`additional_contexts` instead:

```yaml
build:
  context: .
  dockerfile: profiles/${PROFILE}/Dockerfile.overlay
  additional_contexts:
    paperbridge: /Volumes/DataDrive/repo/nranthony/paperbridge
```

In the overlay Dockerfile:

```dockerfile
FROM macolima:latest
COPY --from=paperbridge . /opt/paperbridge
RUN pip install --no-cache-dir /opt/paperbridge
```

`additional_contexts` is read by Buildx (BuildKit). Compose has supported it
since v2.17. macolima already requires modern compose for `env_file: required:
false`, so no version bump needed.

`build.env` per profile would carry the `additional_contexts` map so the main
compose file stays project-agnostic. Sketch:

```bash
# profiles/therapod/build.env
ADDITIONAL_CONTEXTS="paperbridge=/Volumes/DataDrive/repo/nranthony/paperbridge"
```

`profile.sh build` reads `build.env`, parses entries, passes
`--build-context paperbridge=...` to `docker buildx build`.

## Why `-e` (editable install) doesn't make sense at build time

Editable installs create an `.egg-link` pointing at the source path. At
build time that path is `/opt/paperbridge` *inside the image*. After the
build, that path is baked into the image — you can't edit it from outside
without re-mounting over it. Plain `pip install /opt/paperbridge` is the
right call for build-time. If you want live editability, use the runtime
bind-mount pattern instead (see "Alternatives" below).

## Image size + cache strategy

Each per-profile image is `macolima:latest` + delta. Docker shares the base
layers, so disk cost per overlay profile is *just* the delta (single-digit
MB for paperbridge, hundreds of MB for Playwright). No duplication of the
base.

Rebuild order:

1. `scripts/profile.sh build` — rebuilds shared `macolima:latest` if
   Dockerfile changed, then rebuilds any per-profile overlays that exist.
2. `scripts/profile.sh <p> rebuild` — rebuilds only that profile's overlay
   (if present), then `--force-recreate`s its containers.

## Alternatives considered (and why overlay wins)

- **Always-runtime install via post-up.sh**: works but every `up` re-runs
  the install (or needs sentinel-file logic), and the install must go
  through the planning-mode proxy block being open. Fine for one or two
  packages, painful for hundreds of MB.
- **Bind-mount cross-repo source read-only at runtime**
  (`/Volumes/DataDrive/repo/nranthony/paperbridge:/opt/paperbridge:ro`):
  cheap, gives editable workflow for free, but couples profiles to host
  paths outside `/workspace` — opposite of the isolation discipline.
  Acceptable for one-off active-development cases, not as a general
  pattern.
- **Profile-specific docker-compose overrides** (`compose.<p>.yml`): more
  general than overlay Dockerfiles but heavier — most projects need image
  changes, not service-graph changes.

## Migration / rollout

- Add the convention with no profile actually using it. Existing profiles
  keep working unchanged.
- First adopter: probably `therapod` (paperbridge + crawl4ai/playwright).
- After two profiles are using overlays, decide whether to formalize
  `Dockerfile.overlay` linting (e.g. require `FROM macolima:latest` as the
  first line) into `profile.sh build`.

## Open questions for implementation

1. Should `scripts/profile.sh build` rebuild ALL overlays by default, or
   only the one passed as `<profile>`? Probably the latter — explicit.
2. Where do per-profile `additional_contexts` paths get validated?
   `profile.sh` should fail fast if a referenced path is missing on the
   host (same pattern as the existing `/workspace` mount validation).
3. Image-tag GC: when a profile is removed, is its `macolima-<p>:latest`
   image cleaned up? Add to `scripts/profile.sh <p> remove`.

## What this DOES NOT change

- The egress proxy + allowlist model. Overlay images still go through the
  same Squid choke-point at runtime.
- Per-profile state dirs (`profiles/<p>/`). Overlay is image-time;
  state is runtime.
- Seccomp / cap_drop / no_new_privs. Same posture, different image
  contents.
- The build-time vs runtime split for installs (build-time gets direct
  daemon internet; runtime goes through Squid). Overlays inherit this.
