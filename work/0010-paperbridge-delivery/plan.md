# 0010 — plan

`H` = host/human step (outside what the agent can or should do). Everything else
is agent work in this repo unless a phase names another repo's agent. Step IDs
(P0.1, P2.3, …) are stable — `handoff-depot.md` cites them.

**Decisions this plan implements** are spec §3, settled by the owner 2026-09-11:
**D1 = A** (the profile `dist/` flat index, filled by `vendor-tools` from the
channel: opt-in per profile, append-only, hash-checked); **D2 = (a) with
`[all]`** (bake the CLI with every extra the skill documents; the
zero-runtime-dependencies invariant is superseded by a new ADR-0014, conditional
on pinned versions, wheels-only, and verification as `agent` at build); **D3**
(the sibling adopts the same answers, human-ferried).

**Public-repo rule for every edit outside `work/`:** this repo is public.
`scripts/private-names-check.sh` gates README, AGENTS/CLAUDE.md, justfile,
`scripts/`, `sandbox_templates/`, `docs/index.md`, compose and the Dockerfile —
the P2 Dockerfile and AGENTS.md edits are all in its scope. paperbridge itself
is public and MIT (spec §2), so the tool's name is not the question; let the gate
decide rather than assuming, and keep profile/workspace paths out of tracked
prose.

---

## 0. Measured corrections to the spec — read before planning against §1–§4

Seven things were checked on 2026-09-12 that the spec either predates or states
differently. Each changes a step below.

1. **`sgmllib3k` is not in paperbridge 0.3.0's dependency graph, so this item
   needs ONE host-built wheel, not two.** `depot/paperbridge/pyproject.toml` sets
   `[tool.uv] constraint-dependencies = ["feedparser>=6.0.14"]`; the lock
   resolves `feedparser 6.0.14` → `feedparser-sgmllib 2.1.0`, which ships a
   `py3-none-any` wheel. `grep sgmllib depot/paperbridge/uv.lock` returns only
   the `feedparser-sgmllib` rows. `RELEASES.md` records it:
   `2026-09-10 · paperbridge 0.2.1 → 0.3.0 · 9e0fcbaa2 · 0.3.0 — re-lock drops
   sgmllib3k; …`. The only tree still carrying `sgmllib3k 1.0.0` is a
   *consumer's stale lock* (citation_tools, pinned to `feedparser 6.0.12`) — a
   re-lock question in P3, not a wheel to publish in P0.
2. **`bibtexparser 1.4.4` is the only sdist-only package, and its own dependency
   is fine.** The lock records an `sdist` block and no `wheels` block for
   bibtexparser; `pyparsing 3.3.2`, which it depends on, does have a
   `py3-none-any` wheel. So one host build covers the whole `[all]` set.
3. **`paperbridge[all]` is 61 packages, not the 15–25 assumed.** Measured with
   `uv export --frozen --all-extras --no-dev --no-emit-project --no-hashes` from
   the paperbridge checkout: 61 rows, against **18** for the base dependencies
   alone. The heavy tail is `[docs]`: `pymupdf 1.28.2`, `pymupdf-layout 1.28.2` →
   **`onnxruntime 1.29.0`**, `pdfplumber`, `pypdfium2`, plus `cryptography
   50.0.1` and `lxml 6.0.2`. Torch is genuinely absent (docling was declined),
   but `onnxruntime` is a large per-architecture binary wheel and is the item to
   check before the sibling ferry, not torch.
4. **citation_tools is already half-migrated, uncommitted.** Its working tree
   drops `paperbridge[zotero,bibtex] @ git+https://…` for `paperbridge[all]`,
   flips `[tool.uv] no-build` from `false` to `true`, and adds the
   `therapod-dist` flat index with `[tool.uv.sources]` entries for paperbridge,
   bibtexparser **and sgmllib3k**. Its `uv.lock` is **not** re-locked: it still
   pins `paperbridge 0.1.0` from `git …#ba1b861`, `feedparser 6.0.12` and
   `sgmllib3k 1.0.0`. So P3's "drop the git URL, restore `no-build = true`" is
   already drafted by hand and the *unverified* half is the re-lock.
5. **wearable_data_testing still has no paperbridge in its lock**
   (`grep -c paperbridge uv.lock` → 0), and its working tree carries a large
   unrelated uncommitted lock change (aiohttp/crawl4ai). `/…/therapod/dist/`
   holds only `paperbridge-0.1.0-py3-none-any.whl`, dated 2026-04-26. Spec §4's
   immediate unblock has **not** happened.
6. **This image has no dependency-carrying `uv tool install` precedent.**
   paperbridge ADR-0001 cites `weasyprint` with thirteen third-party packages as
   proof the mechanism is already deployed — that is the **sibling's** image.
   `grep weasyprint Dockerfile` here returns nothing. paperbridge would be the
   first, which is exactly why ADR-0014 is owed.
7. **The image's uv is 0.12.9 and carries the flags this plan depends on.**
   `docker run --rm --entrypoint uv macolima:latest --version` → `uv 0.12.9
   (aarch64-unknown-linux-gnu)`; `uv tool install --help` on 0.12.9 lists
   `-c, --constraints` (env `UV_CONSTRAINT`) and `-f, --find-links`. Caveat: the
   Dockerfile installs uv **unpinned** from `astral.sh/uv/install.sh`, so a
   future rebuild can move it — which is why P2 keeps the flag's use inside the
   build layer, where a regression fails the build instead of the runtime.

---

## Stage table

| Stage | What | Who | Gate — move on when |
|---|---|---|---|
| P0 | **The depot handoff:** one host-built `bibtexparser 1.4.4` wheel + a generated `paperbridge[all]` constraints file, published through the channel with manifest hashes | depot agent (profile `nranthony`, `/workspace/depot`); **H** ferries [handoff-depot.md](handoff-depot.md) | the channel's `manifest.toml` carries both artifacts with hashes, `just verify` is green at the channel root, and the depot agent has answered the publish-shape question (P0.3) |
| P1 | **`vendor-tools` → profile `dist/`:** channel wheels delivered into opted-in profiles' `dist/`, append-only, hash-checked | **a separate agent in this repo, already in flight** — this plan does not specify it | `just vendor-tools` puts the paperbridge wheel into an opted-in profile's `dist/` with its manifest hash checked, and `just test-offline` stays green |
| P2 | **The image bake:** Dockerfile block, ADR-0014, `verify-sandbox` check, order-test anchor, docs | me | `just test-offline` green; **H** `just build`; **H** `just recreate <p>`; `just verify <p>` green with the new checks; `paperbridge --version` runs as `agent` |
| P3 | **Consumer handoffs:** citation_tools and wearable_data_testing onto one paperbridge version through the `dist/` index | repo agents; **H** ferries and opens the egress window | both locks name the same paperbridge version, both repos green on their own gates, citation_tools' ADR-0004 retired or explicitly kept |
| P4 | **Ferry to the sibling** | **H** | the sibling has the same answers on file; recorded in `docs/sibling-repo-relationship.md`'s live backlog |

**Ordering that is not negotiable:** P0 → P2 (the bake cannot pin what the
channel has not published). P0 → P3 for citation_tools (its re-lock needs the
bibtexparser wheel to reach `therapod-dist`, or its ADR-0004 opt-out has to
stay). P1 and P3 are coupled by the `dist/` supply, not by code. P2 and P4 are
independent of each other.

**P1 and P2 both touch `scripts/vendor-tools.sh`.** P1 teaches it a delivery
target; P2 may need it to teach it a new manifest shape (P2.1). Whoever lands
second rebases; neither invents the other's half.

---

## Phase P0 — the depot handoff

Content and provenance requirements are in
[handoff-depot.md](handoff-depot.md); it is the source of truth for the ask and
this section does not restate it.

- **P0.1 (H)** Deliver the handoff. Intended path `depot/inbox/` (gitignored
  doorbell; the copy here is the record), naming convention as used on
  2026-09-11: `YYYY-MM-DD-<slug>.md`. The owner ferries it — this repo has no
  write path into the depot and must not acquire one.
- **P0.2** Depot builds the wheel and generates the constraints file, from the
  sdist and the lock at the published `source_commit`.
- **P0.3 — the sequencing gate, and the reason it is a gate.**
  `scripts/vendor-tools.sh` `verify_all()` ends its `case` on artifact `kind`
  with a `die`: *"unknown artifact kind … A new kind must be taught here
  explicitly rather than skipped, or it would enter the image unverified."* It
  mirrors `wheel+skill` and `plugin` only. So **a new artifact kind appearing in
  `manifest.toml` before this repo learns it makes the next `just vendor-tools`
  fail outright** — fail-closed by design, but it stops every artifact, not just
  the new one. The handoff therefore asks for the intended shape *before* the
  publish (handoff **D0.4**, this step's counterpart), and this repo teaches
  `vendor-tools` first — both `verify_all()` and, per P2.1, `deliver_dist()`.
- **Gate:** `just tools-check` still exits 0 against the updated channel, and
  `just vendor-tools --dry-run` prints the new artifacts without dying.

## Phase P1 — the `dist/` supply (another agent's work; the contract only)

A separate agent is implementing this concurrently. **Do not write it here.**
What the rest of this plan assumes of it, and nothing more:

- it copies channel wheels into `/Volumes/DataDrive/repo/<profile>/dist/`,
  visible in-container as `/workspace/dist/`;
- **opt-in per profile** — no profile gains a `dist/` payload by existing;
- **append-only** — it never deletes a wheel a repo's lock may still name (the
  opposite of the `rm -f` rotation `vendor-tools` performs in
  `sandbox_templates/wheels/`, which exists to make the Dockerfile's
  two-wheels-is-a-refusal check meaningful);
- **hash-checked against `manifest.toml`** before anything lands, so no wheel
  ever arrives by hand copy.

**It landed in the working tree while this plan was being written** (`git diff
scripts/vendor-tools.sh`, 2026-09-12: `deliver_dist()`, `optin_artifacts()`, a
`dist-wheels` opt-in file, +227 lines with a matching test). Read as built, it
meets the contract above and settles two things this plan had left open:

- **Opt-in is `<profiles>/<profile>/dist-wheels`, one ARTIFACT NAME per line.**
  A name the channel does not publish is an error, not a silent skip.
- **Delivery reads exactly one field per artifact:** it requires
  `kind = "wheel+skill"` and copies the entry's single `wheel` (checked against
  `wheel_sha256`, temp-then-atomic-`mv`). Anything else is refused with *"Only a
  wheel-bearing artifact can be delivered to a flat index."*

That second point is the one with teeth, and it reaches back into P0 — see
P2.1. A wheel that rides as an **extra field** on another artifact's entry is
invisible to delivery, and an artifact with a **new kind** is refused by it.
Either publish shape therefore needs `deliver_dist` taught as well as
`verify_all`, and the constraints file — build-time only, wanted by no consumer
— should never be delivered to a `dist/` at all.

`docs/local-wheels.md` currently documents the hand copy (`cp dist/<lib>-*.whl
…`). Spec §5 makes updating it an exit condition; that edit belongs to whoever
lands P1, not to P2.

## Phase P2 — the image bake

### P2.1 The manifest shape reaches `sandbox_templates/`

Depends on P0.3's answer. Two shapes, both of which this repo must be able to
mirror and record in `VENDORED.lock`:

- **extra fields on the existing `paperbridge` entry** (e.g. a second wheel and
  a constraints path beside `wheel`/`skill`) — no new `kind`, so `verify_all`'s
  `wheel+skill` arm extends rather than gaining a branch;
- **a separate artifact with a new `kind`** — a new `case` arm in both
  `verify_all()` and `do_vendor()`, plus rows in `write_lock()`.

**P1's landed code decides most of this, and the answer is a split.**
`deliver_dist` names artifacts one per line and copies one `wheel` field from
each, so:

- **the bibtexparser wheel must be its own artifact.** citation_tools maps
  `bibtexparser = { index = "therapod-dist" }`, so that wheel has to reach a
  profile's `dist/` — and a rider field on the paperbridge entry can never be
  named in a `dist-wheels` file nor read by the delivery loop. Its kind still
  needs teaching (it has no skill, and `wheel+skill` is all delivery accepts
  today);
- **the constraints file should ride on the paperbridge entry.** It is
  meaningful only for one wheel at one `source_commit`, it is consumed at image
  build, and no consumer's flat index wants it. As a field it cannot drift from
  the wheel it pins; as its own artifact it would carry a second `source_commit`
  that can.

The drift objection to two entries is already answered in this ecosystem by the
manifest's `asserts` (the `myconv` entry states a `myclickup` floor for exactly
this reason). Handoff D0.4 carries this recommendation; the schema is the
depot's to decide.

Either way the payload lands beside the existing wheels, because the Dockerfile
already copies that whole directory (`COPY sandbox_templates/wheels/
/tmp/wheels/`) — no second `COPY`, no new build-context surface.

**One decision to make explicitly:** `.gitignore` line 261 is
`sandbox_templates/wheels/*.whl`, so a `.txt` constraints file dropped there
would be **tracked**. Recommend extending the ignore to cover it and letting
`VENDORED.lock` carry its hash: a tracked copy is a second source of truth that
can drift from the channel, and drift in this file is precisely the failure
ADR-0001's addendum describes. (ADR-0004 gitignores the payload because
myclickup is private; here the reason is different but the conclusion is the
same.)

### P2.2 The Dockerfile block

Position: **immediately after the myclickup block, at the tail**, above
`USER agent`. Reasons, all already encoded in the file: it must be below Gate 3
(`no-build = true` is what makes installing safe at all), and below the AI-CLI
cache-buster and the five network fetches between Gate 3 and the tail, which a
payload bump must not re-run.

`scripts/dockerfile-order.test.sh` locks the chain on anchor strings and
requires each to appear **exactly once**. Add the new block's anchor after
`"myclickup wheel COPY|COPY sandbox_templates/wheels/"`, and add a companion
assertion mirroring the existing
`su -s /bin/sh agent -c 'myclickup --version'` grep.

Sketch — *the resolution form is the one open question, see P2.3*:

```dockerfile
# ---------- paperbridge — vendored literature CLI (OPTIONAL payload) ---------
# Same conditional-install shape as myclickup, and the same refusal on two
# wheels. What differs, and why (ADR-0014):
#   * --constraints is MANDATORY, not tidy. `uv tool install` re-resolves from
#     PyPI and never reads uv.lock, so without it `bibtexparser>=1.4` resolves
#     to 2.x — which HAS wheels, so Gate 3 is satisfied, the build goes green,
#     and BibTeX breaks at runtime (paperbridge ADR-0001 addendum).
#   * --find-links supplies the one package with no wheel on PyPI,
#     bibtexparser 1.4.4, built host-side and shipped through the channel.
#     Gate 3 stays `no-build = true`.
RUN set -eu; \
    n="$(find /tmp/wheels -maxdepth 1 -name 'paperbridge-*.whl' | wc -l)"; \
    if [ "$n" -gt 1 ]; then echo "paperbridge: $n wheels - refusing to guess" >&2; exit 1; \
    elif [ "$n" -eq 1 ]; then \
      whl="$(find /tmp/wheels -maxdepth 1 -name 'paperbridge-*.whl')"; \
      test -f /tmp/wheels/paperbridge-constraints.txt; \
      test -n "$(find /tmp/wheels -maxdepth 1 -name 'bibtexparser-*.whl')"; \
      UV_PYTHON_DOWNLOADS=never uv tool install --python /usr/bin/python3 \
        --constraints /tmp/wheels/paperbridge-constraints.txt \
        --find-links /tmp/wheels "${whl}[all]"; \
      paperbridge --version; \
      su -s /bin/sh agent -c 'paperbridge --version'; \
    else echo "paperbridge: no vendored wheel - skipping"; fi
```

The two `test` lines are load-bearing, not defensive: a paperbridge wheel
present **without** its constraints file is the exact configuration that
produces a green build and a broken runtime. Fail the build instead.

The `rm -rf /tmp/wheels` currently ends the myclickup `RUN`; whichever block is
last owns it, and only one may.

### P2.3 Verify at build what cannot be verified later

- **Which requirement form resolves paperbridge from the local wheel.** The
  sketch appends `[all]` to a wheel path. Confirm at build that uv accepts it;
  if not, the alternative is `--find-links /tmp/wheels "paperbridge[all]==<ver>"`
  with the version read from the wheel filename. **Prefer the wheel-path form:**
  paperbridge is not on PyPI, so a name-based requirement is a name that could
  one day be registered by someone else, and a local path can never resolve
  remotely.
- **Constraints must not pin paperbridge itself.** `--no-emit-project` excludes
  it from the export, so the file pins the 61 dependencies and leaves the tool's
  own version to the wheel. If a future constraints file pins `paperbridge`, the
  install of a *different* local wheel becomes unsatisfiable.
- **Gate 3 at build.** The build has network (Docker build bypasses Squid), but
  `/etc/uv/uv.toml`'s `no-build = true` applies at build time too. That is the
  point: with constraints pinning all 61 to the locked versions, "every one of
  them is a wheel for this architecture" is a claim the build itself checks.

### P2.4 `verify-sandbox.sh`

There is **no baked-tool check in `verify-sandbox.sh` today** — myclickup has
none. This adds the first. Recommend keeping scope to paperbridge and recording
the asymmetry rather than opportunistically adding a myclickup check in this
item.

The script is streamed into the agent container over stdin and runs as the
container's `USER`, i.e. `agent` — so "runs as the agent user" is a property of
where it runs, not something the check has to arrange. The build-time
`su -s /bin/sh agent -c` is what proves it at build; this proves it survived to
runtime. Using the existing `pass`/`fail`/`warn` helpers:

- `paperbridge --version` succeeds → `pass`, else `fail` naming the re-vendor +
  rebuild + recreate route (the agent cannot install it; every installer is
  denied).
- the three extras import, probed through the tool's own interpreter at
  `/opt/uv/tools/paperbridge/bin/python` (`UV_TOOL_DIR` is pinned there):
  `bibtexparser`, `pyzotero`, and pymupdf's `fitz`. One `fail` per missing root
  is more useful than one aggregate — each names a different half of the
  payload.
- The absence of the tool must be a `fail` only when a wheel was vendored;
  otherwise the conditional install is a legitimate skip. Simplest honest
  reading: `fail` if the vendored skill is present and the CLI is not, since the
  shipped SKILL.md already tells agents *"If `paperbridge` is missing or
  outdated, STOP. It is baked into the image"* — a sentence that is **false in
  this image today** and which P2 is what makes true.

### P2.5 ADR-0014 and the docs that carry the superseded sentence

New ADR at **0014** (the index says new decisions here continue from 0014; 0010
stays reserved for the sibling's own history). Title in the register's voice —
*"A baked CLI may carry dependencies when its versions are published"*. It must
carry:

- **Context:** ADR-0004's consequence *"Zero runtime dependencies is an
  invariant, not a starting point"*, and why it held (the agent cannot repair a
  broken dependency; every installer is denied). paperbridge's own ADR-0001
  reaches the opposite conclusion for its own repo, with reasons that are
  properties of myclickup rather than of the channel.
- **Decision:** bake `paperbridge[all]`; the invariant is superseded **only**
  under three conditions — versions pinned from a channel-published constraints
  file generated from the lock at the published `source_commit`; installed
  wheels-only with Gate 3 untouched; verified in-layer as `agent`.
- **Consequences:** 61 packages in an isolated tool venv (`uv tool install`
  isolation is what keeps this from colliding with anything else); the CVE
  surface grows and `.trivyignore.yaml` will need dated entries; a broken
  dependency is repairable only by a host-side rebuild, which the skill already
  states; the image grows materially — measure before/after and record the
  number, since "the image grows" without a figure is not a consequence anyone
  can check later.
- **Rejected alternatives:** base-only (spec D2(a) as originally framed — the
  skill documents `zotero-*`, `--bibtex` and `parse`, so base-only ships a CLI
  that fails at three of its documented surfaces); dropping the skill from
  convergence (D2(b), still the fallback if P2 is deferred); `uv run` from a
  repo venv (D2(c), scoped, and the skill's text assumes a global CLI);
  docling (declined 2026-09-11, spec §3).

Then: link it from `docs/adr/README.md`; add the gotcha-pointer row in
`AGENTS.md`; **update `docs/extending-a-profile.md` L165**, which repeats the
zero-dependency sentence verbatim and would otherwise contradict the new ADR;
`just sync-agent-files`.

### P2.6 Gates

1. `just test-offline` — twelve commands, including `dockerfile-order.test.sh`,
   `vendor-tools.test.sh`, `private-names-check.sh` and `sync-agent-files
   --check`.
2. **H** `just build`. **A plain `build` suffices** — no `--no-cache`, no
   `--pull`. Docker keys a `COPY` layer on the content of what it copies, so new
   or changed wheels bust `COPY sandbox_templates/wheels/` and everything below
   it, which is exactly the two install blocks. `--refresh-ai` is irrelevant
   here (it busts the AI-CLI tail, which sits above).
3. **H** `just recreate <p>` per running profile — the wheel is baked, and `up`
   does not rebuild.
4. `just verify <p>` per profile: the P2.4 checks green.
5. Record the image size delta and the new trivy findings in `notes.md`.

## Phase P3 — consumer handoffs

One handoff per repo, filed here as `handoff-<repo>.md`, delivered by the owner
to `/Volumes/DataDrive/repo/therapod/inbox/0010/` (the pattern 0008 used: a
workspace-root inbox outside every repo, seen in-container as
`/workspace/inbox/0010/`). Each is phrased as checks against their tree, not
claims about it. Both need the owner's egress window for the re-lock, and the
window's planning-mode domains must be re-commented afterwards, explicitly.

### P3.1 citation_tools

Its working tree has already done half of this by hand (§0.4). The handoff's job
is the half that is unverified, plus the decisions:

- **Re-lock** without deleting the lock, so existing pins are kept and only
  paperbridge and its dependencies move. Review `git diff uv.lock` before
  committing.
- **The `sgmllib3k` question, which is the interesting one.** uv prefers
  versions already in a lock, so a re-lock may well keep `feedparser 6.0.12` and
  with it `sgmllib3k` — the very package paperbridge 0.3.0 removed. If it does,
  the fix is on their side: mirror paperbridge's
  `constraint-dependencies = ["feedparser>=6.0.14"]`, or
  `uv lock --upgrade-package feedparser`. Only if the owner declines both does
  anyone need a published `sgmllib3k` wheel. **Check, don't assume**: read the
  post-re-lock `uv.lock` for `sgmllib3k` and report what happened.
- **Then** the `[tool.uv.sources]` entry for `sgmllib3k` is either still needed
  or is dead weight pointing at an index that never carried it.
- **`no-build = true`** is already set in the working tree; it is only *true* in
  effect once the lock names no source-only package. The order is re-lock first,
  confirm, then keep the flip.
- **Retire its ADR-0004** (`Allow source builds for this project`) with a new
  ADR that supersedes it, per that repo's own append-only rule. Its own
  consequences section anticipates this: *"If all three gain usable wheels (e.g.
  paperbridge publishes one), the override can be dropped."* Two of the three
  (paperbridge, bibtexparser) are answered by this item; the third
  (`sgmllib3k`) disappears with the feedparser floor. Retiring the ADR without
  all three answered is premature — say so rather than leaving it implied.
- Its `.venv-sandbox` is built but empty, blocked on registry access (0008 stage
  6 carried this); the same egress window serves both.

### P3.2 wearable_data_testing

Smaller: it is already on the `dist` index and asks for plain `paperbridge` (no
extras).

- It needs the **0.3.0 wheel in `/…/therapod/dist/`** — today only 0.1.0 is
  there. That is P1's delivery, or spec §4's hand copy with the manifest sha256
  checked; prefer waiting for P1 so the hand copy is never repeated.
- **0.1.0 will still be there afterwards.** Delivery is append-only and refuses
  to touch a file it did not write; different filenames simply coexist. So spec
  §4's "move 0.1.0 aside, or pin `paperbridge>=0.3`" becomes: **pin**, or move
  it aside **by hand**. An unpinned `paperbridge` in a flat index holding two
  versions resolves to the higher one, which is the outcome wanted here — but it
  is worth pinning rather than relying on it, since the same directory is the
  supply for citation_tools too.
- Then `uv lock` (not `--frozen`; the lock has **no** paperbridge row at all
  today, so `uv sync --frozen` installs none), review, commit.
- Then in-container `uv sync --frozen` and `scripts/preflight.sh` — its
  paperbridge import is the first 0.1.0 → 0.3.0 compatibility check anywhere.
- Note its `[tool.uv] find-links = ["/workspace/dist"]` sits **beside** the
  `therapod-dist` index; two supply routes to the same directory, one of them
  container-absolute. Worth asking whether the `find-links` line is still wanted
  once the index works — but it is their call, and it is not blocking.

**Both repos must end on the same paperbridge version.** That is the D1 exit
condition, and the only thing that makes "one route in" true rather than
aspirational.

## Phase P4 — ferry to the sibling

**H**, and only after P2 is green here. The payload is this plan's §0 and P2
(ADR-0014, the Dockerfile block, the verify check), not this file wholesale.
Three things differ there and must be stated in the ferried note:

- **x86_64.** Torch is not involved — that was docling, declined. The item to
  check is `onnxruntime 1.29.0` (via `pymupdf-layout`) and the other binary
  wheels: confirm each of the 61 pinned versions has an x86_64 wheel before
  baking, since Gate 3 refuses the fallback.
- **It runs the agent as root**, so its build-time check needs no `su … agent`
  line — the reason `dockerfile-order.test.sh` says that anchor is ours alone.
- **ADR numbers are shared by intent.** 0014 should be the same decision there;
  reserve it even if their bake lags.

Record it in `docs/sibling-repo-relationship.md`'s live backlog ("what W is
owed"), where the 0008 replay is already tracked.

---

## Risks and known facts, stated once

| Fact | Consequence for this plan |
|---|---|
| `uv tool install` re-resolves from PyPI and never reads `uv.lock` | The constraints file is the only thing pinning the 61. Without it the build is green and BibTeX breaks at runtime (paperbridge ADR-0001 addendum). P2.2's `test -f` guard exists for this. |
| The image build has network (it bypasses Squid), but `/etc/uv/uv.toml` `no-build = true` applies at build time too | Every pinned version must have a wheel for the build architecture. Today exactly one package fails that (bibtexparser 1.4.4) and the channel supplies it. A constraints bump can silently introduce a second — the build catches it. |
| `paperbridge[all]` = 61 packages (base 18) | Image size grows materially; the trivy CVE surface grows with `cryptography`, `lxml`, `pymupdf`, `onnxruntime`. Expect new `.trivyignore.yaml` entries with dated `expired_at`. Measure and record. |
| `onnxruntime` arrives via `pymupdf-layout`, not via anything paperbridge names directly | A transitive heavyweight nobody chose. If the size is unacceptable, the lever is upstream in paperbridge's `[docs]` extra — not a local exclusion, which constraints cannot express. |
| The image's uv is unpinned in the Dockerfile (0.12.9 today) | `--constraints` support is verified for 0.12.9, and its use stays inside the build layer so a regression fails the build. Do not move the pin into prose. |
| `vendor-tools` dies on an unknown artifact kind | P0.3 is a gate, not a courtesy: teach this repo first, publish second. |
| The vendored `paperbridge` SKILL.md already says the CLI is baked | Today that sentence is false in this image. P2 makes it true; if P2 is deferred, D2(b) — stop converging the skill — is the fallback and should be taken deliberately rather than by drift. |
| `sandbox_templates/wheels/` is rotated (`rm -f`) on every vendor, while profile `dist/` is append-only | Two different disciplines for two different consumers; don't unify them. The rotation is what makes the Dockerfile's two-wheels refusal meaningful; the append-only rule is what keeps a consumer's lock resolvable. |

---

## Exit

Spec §5, with §0's corrections folded in:

- D1 applied to both consumers, both locked to the same paperbridge version and
  green on their own gates;
- D2 implemented: the Dockerfile block, ADR-0014, the `verify-sandbox` checks,
  and the order-test anchors;
- D3 ferried and recorded in the sibling backlog;
- `docs/local-wheels.md` names the supply route rather than a hand copy (P1's
  edit);
- `docs/extending-a-profile.md` no longer states an invariant ADR-0014
  supersedes.

Then archive this folder per `work/README.md`, distilling ADR-0014 as the
durable record.
