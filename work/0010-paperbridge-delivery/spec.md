# 0010 — paperbridge delivery: one way in for the library, and a decision on the CLI

**State:** spec only. **Opened:** 2026-09-11, from a question during 0008's
stage 6: "wearable_data_testing sees paperbridge 0.1.0; I ran `just vendor-tools`
and recreated, and it's still 0.1.0."

> Numbering note: unqualified `work/0010` citations inside code ported from
> windows-ai-sandbox (`deny-destructive.*`, the antigravity templates, the audit
> probe) name **its** agy-guardrails item, not this one. See `work/README.md`.

## 1. The problem

Paperbridge reaches sandbox profiles by three unrelated routes, none of them
uses the version the depot channel publishes, and the CLI that the vendored
skill describes exists in no container.

| Who | Route | Gets | Measured 2026-09-11 |
|---|---|---|---|
| therapod/citation_tools (7 files import it) | **git source:** `paperbridge[zotero,bibtex] @ git+https://github.com/nranthony/paperbridge.git`, locked to commit `ba1b861` | 0.1.0, **built from source** | needs `github.com` (the `[git]` block is live) and source builds (its ADR-0004 opts out of wheels-only, partly for this) |
| therapod/wearable_data_testing (4 files import it) | **flat index `../dist`** (`[[tool.uv.index]] url = "../dist"`, `format = "flat"`, `explicit`) → `/Volumes/DataDrive/repo/therapod/dist/` = `/workspace/dist/` | 0.1.0, a wheel **copied by hand** 2026-04-26 (the `docs/local-wheels.md` workflow) | **`uv.lock` has no paperbridge entry:** lock 2026-03-31, the index pointer 2026-05-01, never re-locked. `uv sync --frozen` installs no paperbridge; an unfrozen sync re-locks to the only wheel in `dist/`, 0.1.0 |
| The CLI, via the vendored `paperbridge` skill (converged into every profile) | the skill says "with the paperbridge CLI"; paperbridge's `pyproject.toml` says "the console script the sandbox image puts on PATH" | **nothing:** macolima's Dockerfile installs only `myclickup-*.whl`. windows-ai-sandbox's has no paperbridge either (Mac clone, 2026-08-31) | no repo calls the CLI; the only `paperbridge <cmd>` hits are the depot's own publishing docs |
| The depot channel | `vendor-tools` → `sandbox_templates/wheels/paperbridge-0.3.0-py3-none-any.whl` | 0.3.0 (manifest sha256 `4be3a996…`) | **consumed by nothing** |

How it got here: both library consumers were wired before the channel published
paperbridge (0.2.0 on 2026-09-09, 0.3.0 since). Each solved "get it into the
container" locally, and neither moved when the channel arrived.

**Why the obvious fix doesn't work** (pointing a repo's source at the vendored
wheel in macolima's `sandbox_templates/wheels/`, or at the depot's `dist/wheels/`):
- a profile container mounts only `/Volumes/DataDrive/repo/<profile>`, so
  neither folder is visible, and a relative path escapes the mount;
- `sandbox_templates/wheels/` is image-build staging that `vendor-tools` rotates
  on every bump;
- the layout differs on the windows-ai-sandbox machines.

The `../dist` flat index is sound: it resolves identically on the host and in
the container. What it lacks is a supply.

## 2. Constraints

- **The image is wheels-only** (ADR-0004, `/etc/uv/uv.toml` `no-build = true`),
  at build time too. paperbridge's **base** dependencies (pydantic,
  pydantic-settings, requests, loguru, beautifulsoup4, lxml) all ship wheels.
  **Two extras do not:** `[bibtex]` needs `bibtexparser` 1.4, source-only; and
  `[zotero]` → pyzotero → feedparser → `sgmllib3k`, source-only (as found by
  citation_tools' ADR-0004). So "the CLI in the image" can mean base only, or it
  means a build-time source exemption.
- **Vendored tools are zero-dependency by invariant** (`docs/extending-a-profile.md`:
  "Zero runtime dependencies is an invariant, not a starting point"). myclickup
  meets it; paperbridge has six runtime dependencies. Baking it breaks that
  invariant, and the agent can never repair a broken dependency in the
  container.
- paperbridge's own `pyproject.toml` anticipates `uv tool install`, and bounds
  pydantic `<3` and bibtexparser `<2`, because `uv tool install` re-resolves from
  PyPI and ignores `uv.lock`.
- paperbridge is **public, MIT-licensed** (`gh repo view`: PUBLIC).
- The 0.1.0 → 0.3.0 jump is an upgrade for both consumers; their tests decide.

## 3. Decisions (owner, 2026-09-11 — all three settled; the plan follows)

- **D1 = A.** The profile `dist/` flat index is the route, filled by
  `vendor-tools` from the channel: opt-in per profile, append-only,
  hash-checked. PyPI (C) stays the longer-term target.
- **D2 = (a), with `[all]`.** Bake the CLI into the image with every extra the
  skill documents, so `zotero-*`, `--bibtex` and `parse` all work. The
  zero-runtime-dependencies invariant is **superseded** (ADR-0014), on the
  condition that versions are pinned from channel-published constraints,
  installed wheels-only, and verified as `agent` at build.
- **D3.** The sibling adopts the same answers; ferried.
- **D4 (2026-09-12) — the dependency set is checked at build, and a finding
  flags rather than blocks.** `scripts/depaudit.py deps` (OSV, host-side,
  network) runs over the pinned set as part of the bake, and reports. It never
  fails the build: OSV is reactive, so a clean result is "nothing known yet",
  and a scanner that can block on someone else's database entry is a scanner
  that gets bypassed on a deadline. First run, 2026-09-12, over paperbridge's
  lock: **100 packages, 0 malicious records**. Age was measured at the same
  time — 15 of the 61 were published within 90 days, the youngest `regex` at 2
  days and `numpy` at 5 — which the constraints file then freezes.

**Also considered and declined (2026-09-11): replacing the `[docs]` stack with
docling.** Docling is better at tables and multi-column layout, but `docling`
is just `docling-slim[standard]`: 29 dependencies including torch,
torchvision and `docling-ibm-models`, against roughly 10 today. Its models come
from `huggingface.co`, which this allowlist doesn't carry, so they would have to
be baked or cached; and on the sibling's x86_64, torch pulls the CUDA wheels
unless the build pins the CPU index. It also wouldn't replace trafilatura,
which strips boilerplate rather than converting structure. Revisit as a
**paperbridge-side** spike (measure the dependency tree, convert sample papers,
compare tables) — not on this item's path.

### The options as they stood

**D1 — one route for the library.**

| Option | For | Against |
|---|---|---|
| **A. Everyone uses the profile `dist/` flat index** | wheels only; no git egress; no source build for paperbridge; env-neutral relative path; already how wearable_data_testing works | needs a supply step: a small host-side recipe copying channel wheels into `/Volumes/DataDrive/repo/<p>/dist/`, **hash-checked against `manifest.toml`**, so nothing is hand-copied |
| B. Everyone uses a git source pinned to a tag | no copying | every install is a source build (wearable_data_testing would need ADR-0004's opt-out too); GitHub access at install |
| C. Publish paperbridge to PyPI | an ordinary dependency (`paperbridge>=0.3`); no special wiring anywhere; wheels from PyPI | changes paperbridge's release process (PyPI account/token, `uv publish`); a public name to own |

Recommendation: **A now, C as the target.** citation_tools keeps its source-build
opt-out regardless: it has two other source-only packages.

**D2 — the CLI the skill describes.**
- **(a) Bake it:** mirror the myclickup block with `uv tool install` for
  paperbridge, **base only**, since extras would need a source exemption.
  Accepts six runtime dependencies in the image, against the zero-dependency
  invariant. Record that as an ADR.
- **(b) Don't bake it:** stop converging the `paperbridge` skill into profiles,
  so no agent is told to use a CLI that isn't there. Keep the library route (D1).
  The skill could return with the CLI later.
- **(c) Run it from a repo venv:** `uv run paperbridge …` inside a repo that
  depends on it. That works today in citation_tools and wearable_data_testing
  once built. Scoped, but the skill's text assumes a global CLI.

Recommendation: **(b) until there's a concrete CLI need**. Today nothing calls
it, and a skill describing an absent tool invites workarounds. Revisit with C:
a PyPI release makes (a) a plain `uv tool install paperbridge==X`.

**D3 — the sibling.** windows-ai-sandbox consumes the same channel; its D2
answer should match, or the skill means different things on different machines.
It's carried in `replay-other-hosts.md` terms: human-ferried.

## 4. Immediate unblock (in flight, 0008 stage 6)

wearable_data_testing's handoff build can't succeed until its lock carries
paperbridge. On the Mac:
1. Copy the channel's `paperbridge-0.3.0-py3-none-any.whl` into
   `/Volumes/DataDrive/repo/therapod/dist/`, and check its sha256 against the
   depot `manifest.toml`. Move 0.1.0 aside, or pin `paperbridge>=0.3`.
2. Run `uv lock` in wearable_data_testing **without deleting the lock**: uv
   keeps existing pins and adds paperbridge 0.3.0 and its dependencies. Review
   `git diff uv.lock`, then commit.
3. In the sandbox: `uv sync --frozen` (egress window), then `scripts/preflight.sh`.
   Its paperbridge import is the first 0.3.0 compatibility check.

That's D1-A done by hand for one repo; the recipe replaces the hand copy.

## 5. Exit

- D1 decided and applied to both consumers, both locked to the same
  paperbridge version and green on their own gates;
- D2 decided and either implemented (Dockerfile block, ADR, verify check) or the
  skill removed from convergence;
- D3 ferried to the sibling;
- `docs/local-wheels.md` updated to name the supply route rather than a hand copy.
