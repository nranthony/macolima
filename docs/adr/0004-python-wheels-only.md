# ADR-0004 — A private CLI reaches the image as a vendored wheel, never as a network install

- **Status:** Accepted (2026-09-02, with `myclickup` 0.7.0)
- **Deciders:** nranthony + agent

## Context

`myclickup` is a private tool the whole fleet needs and no public index carries.
Three obvious routes were all wrong:

- **`pip install` from a private index at build time** puts a deploy token
  inside the build of a security-critical image, and makes the image
  unbuildable without network the allowlist deliberately does not grant.
- **`COPY ../myclickup`** cannot work: `build.context: .` means `COPY` cannot
  read a sibling checkout, however the host is laid out.
- **Installing it at first use inside the container** puts it in
  `/home/agent/.local`, which is a `noexec` tmpfs recreated empty at container
  start — it would report success and then fail with `EACCES`.

## Decision

Private tools arrive as **zero-dependency Python wheels, vendored into the repo
and installed by the `Dockerfile`.**

- The wheel is mirrored from the depot channel into
  `sandbox_templates/wheels/` by `scripts/vendor-tools.sh`, hash-verified
  against the channel manifest and recorded in `VENDORED.lock`.
- The payload is **gitignored** — this repo is public and the tool is not — with
  a tracked `.gitkeep` so the directory exists in the build context.
- The `Dockerfile` does a **directory `COPY` and a conditional install**: zero
  wheels skips and still builds green; **two wheels is a hard refusal**, because
  the vendor script rotates the file on every bump, so two means a failed
  rotation and guessing would ship the wrong version behind a correct-looking
  `--version`.
- The install pins `--python /usr/bin/python3` with `UV_PYTHON_DOWNLOADS=never`,
  and the image pins `UV_TOOL_DIR=/opt/uv/tools` and
  `UV_TOOL_BIN_DIR=/usr/local/bin`. Unpinned, `uv` installs into the `noexec`
  tmpfs and may silently download an interpreter into a root-owned directory the
  agent cannot read.
- The layer verifies as **root and as `agent`**. Verifying only as root proves
  the wrong thing: root is not who runs it.

## Consequences

- **Zero runtime dependencies is an invariant, not a starting point.** The agent
  cannot repair a broken dependency — every installer is denied to it.
- **The image is no longer reproducible from a clone alone.** Accepted
  explicitly; a clone without the payload still builds, just without the tool.
- **The wheel and its skill are one payload.** A skill describes a tool
  *version*, so a stale skill sends an agent to run commands that no longer
  exist in a container where it cannot install a fix. Both are vendored together
  and the check compares **content, not version strings** — pre-1.0 the version
  changes rarely and the tree changes constantly, so the common drift is a
  rebuilt same-version wheel with different bytes.
- **Different lifecycles.** The skill converges on the next `up`; the wheel is
  baked into the image and needs a `build` plus a recreate. `up` does not
  rebuild.
