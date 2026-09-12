# Handoff: to bake paperbridge's CLI with `[all]`, the image needs two things only the channel can publish — one wheel and a constraints file

**To:** the agent working in `depot` (sandbox profile `nranthony`, `/workspace/depot`)
**From:** the agent in `macolima` (host side)
**Date:** 2026-09-12
**Reciprocal-to:** — (this opens the exchange; it follows paperbridge's own
ADR-0001 §4 and its 2026-09-10 addendum, which name both artifacts but leave
them unpublished)
**Filed at:** `macolima/work/0010-paperbridge-delivery/handoff-depot.md` ·
delivery intended: `depot/inbox/2026-09-12-paperbridge-constraints-and-the-bibtex-wheel.md`
(gitignored doorbell; the macolima copy is the record). **The owner ferries it —
nothing has been delivered yet.**

## 1. What was decided, and what it needs from the channel

macolima's `work/0010` settled three things on 2026-09-11 (owner):

- **The library route is the profile `dist/` flat index**, filled from this
  channel — opt-in per profile, append-only, hash-checked. No more hand copies.
- **The CLI is baked into the image with `[all]`**, so `zotero-*`, `--bibtex`
  and `parse` all work — the surfaces the shipped `SKILL.md` documents. The
  image's zero-runtime-dependencies invariant is superseded by a new ADR there,
  **conditional** on: versions pinned from channel-published constraints,
  installed wheels-only, and verified as the `agent` user at build.
- The sibling sandbox adopts the same answers, human-ferried.

That third condition is the whole of this handoff. The image installs with
`uv tool install`, which **re-resolves from PyPI and never reads `uv.lock`** —
your own ADR-0001 addendum of 2026-09-10 says so, and it is why the addendum
ends *"Contained downstream for now by a constraints file generated from this
repo's lock at the published `source_commit`."* That file exists nowhere yet.
Same for the `bibtexparser` wheel that ADR-0001 decision 4 says is *"built into
a wheel host-side and shipped beside the vendored paperbridge wheel"* — the
channel carries the paperbridge wheel and skill, and nothing else.

So: **two artifacts, one publish, and one question about your release process.**

## 2. What did NOT change, and the negative results you cannot derive from here

- **No change is wanted to paperbridge's source, `pyproject.toml` or extras
  set.** `[all]` = `[docs,bibtex,zotero]` is what the image bakes, exactly as
  ADR-0001 decision 3 says.
- **No change to the 0.3.0 wheel or skill.** macolima's `VENDORED.lock` records
  `paperbridge.wheel 0.3.0 4be3a996…` and `paperbridge.skill 0.3.0 785779c7…`;
  both still match `manifest.toml`. This handoff asks for artifacts *beside*
  them, not a republish.
- **No permission-proposal delta.** The manifest's 20 `proposed_allow`,
  8 `proposed_ask` and 2 `proposed_deny` entries already cover the CLI surface
  the image will expose. Baking the CLI changes what exists on `PATH`, not what
  is granted — adoption stays a human decision on the sandbox side.
- **`sgmllib3k` is NOT wanted, and this is the negative result worth having in
  writing.** macolima's spec asked for two wheels — bibtexparser *and*
  `sgmllib3k 1.0.0`. Re-measured on 2026-09-12 against your tree: paperbridge
  0.3.0's lock contains no `sgmllib3k` at all. `RELEASES.md` says why
  (`0.3.0 — re-lock drops sgmllib3k`), and the lock shows `feedparser 6.0.14` →
  `feedparser-sgmllib 2.1.0`, which ships a wheel. **Decision 5 worked.** Do not
  build it. §4 D0.1 turns that into a check rather than an assumption.
- **`bibtexparser 1.4.4` is the only sdist-only package in the whole `[all]`
  set**, and its own dependency `pyparsing 3.3.2` has a `py3-none-any` wheel in
  your lock. One host build covers everything.
- **The image's uv is 0.12.9** (read from the built image, `aarch64-unknown-linux-gnu`)
  and its `uv tool install` carries `-c/--constraints` and `-f/--find-links`.
  The consuming side of this is verified; nothing about the file format is
  guesswork on our end.

## 3. What this may invalidate in your tree — checks, not claims

I read a host-side copy of the depot tree on 2026-09-12. It may be stale, and
you can see things from inside it that I cannot.

- `paperbridge/justfile` — the `test-full` recipe says *"host only, needs the
  host-built [bibtex] wheel"*, and `dist` builds only `paperbridge-*.whl`. If
  the bibtexparser wheel is to be a channel artifact, check whether building it
  belongs in a recipe here rather than in a one-off command that leaves no
  trace. Same question for the constraints export.
- `paperbridge/docs/adr/0001-…` decision 4 says the wheel is *"shipped beside
  the vendored paperbridge wheel"*. Check whether anything in this repo has ever
  produced it; from outside, `dist/wheels/` in the channel holds exactly two
  files (`myclickup-0.7.0`, `paperbridge-0.3.0`), so it looks like a decision
  recorded and not yet executed. If it was built somewhere and lost, that is
  worth a line in the handback — it changes "build it" into "rebuild it
  reproducibly".
- `bin/channel.py` — `PUBLISHERS` is a fixed dict of three names, `cmd_publish`
  refuses an unknown artifact, and `publish_wheel_and_skill` returns a fixed
  entry shape and rotates `dist/wheels/<name>-*.whl` by unlinking the old. So
  neither new artifact can be published by the existing path without a change
  here, and the rotation glob is worth re-reading before adding a second wheel
  under the same directory: check that a `bibtexparser-*.whl` cannot be caught
  by a `paperbridge-*.whl` rotation, or vice versa.
- `AGENTS.md` — *"The channel has no `work/` tree and should not grow one"*. If
  this turns into more than a publish, the work item belongs in `paperbridge/`,
  which already has `work/0001-channel-membership`.
- `AGENTS.md` rule 3 — *"Hashes and permission data are generated, never
  transcribed."* Everything below is written to respect that; if any step reads
  like it asks you to copy a hash into prose, it is misworded and the rule wins.

## 4. Ordered tasks

**D0.1 — confirm the shape of the ask before building anything.**
Two checks, both cheap, both changing what you build:

1. `grep -n sgmllib paperbridge/uv.lock` — expect only `feedparser-sgmllib`
   rows. If `sgmllib3k` appears, §2's negative result is wrong and the answer is
   two wheels, not one; say so and stop.
2. Confirm `bibtexparser 1.4.4` has no `wheels = [...]` block in that lock —
   only an `sdist`. That absence is the entire justification for a host build.

**D0.2 — build `bibtexparser 1.4.4` into a `py3-none-any` wheel, once, with
stated provenance.** The provenance requirement is the point of this step, not
paperwork:

- Build **from the PyPI sdist whose sha256 `paperbridge/uv.lock` already
  records** for `bibtexparser 1.4.4` — not from "whatever 1.4.x PyPI serves
  today", and not from a git checkout. Read the URL and hash out of the lock,
  fetch, **verify the sha256 before building**, then build. The lock is already
  the pin; a wheel built from anything else is a second, unreviewed pin.
- The result is pure-Python and must be `py3-none-any` — architecture-neutral,
  because it is consumed by an arm64 image here and an x86_64 image on the
  sibling from the same channel. If the build emits a platform tag, something is
  wrong; report rather than retagging.
- It is the tool's **dependency**, not the tool. Its version moves only when
  paperbridge's `[bibtex]` pin moves — which, per ADR-0001 decision 6, is
  `<2` and is meant to stay there.

**D0.3 — generate the constraints file; never hand-write it.** Verified working
from the paperbridge checkout on 2026-09-12 (host uv 0.12.9):

```
uv export --frozen --all-extras --no-dev --no-emit-project --no-hashes
```

61 packages. Each flag is doing a job, and changing one changes what the image
installs:

- `--frozen` — export the lock as it stands; never re-lock as a side effect of
  publishing.
- `--all-extras` — `[docs,bibtex,zotero]`; the image bakes all of them.
- `--no-dev` — pytest/ruff/mypy have no business in the image.
- `--no-emit-project` — **the file must not pin `paperbridge` itself.** The
  image installs the local wheel and lets constraints pin only its 61
  dependencies; a self-pin makes installing any other build of the wheel
  unsatisfiable.
- `--no-hashes` — **recommended, and please confirm or overrule.** A constraints
  file carrying `--hash=` entries switches uv's resolution into hash-checking
  mode, which then demands hashes for everything in the resolution, not only
  what the file names. The file's integrity anchor is its sha256 in
  `manifest.toml`, generated by the channel — which is the same guarantee, in
  the place this ecosystem already keeps it.

It must be generated **from the lock at the `source_commit` the channel
publishes**, so the constraints and the wheel can never describe different
resolutions. If `git status` in the member is not clean at publish time, the
channel already refuses — that rule covers this file too.

**D0.4 — publish both as channel artifacts with manifest hashes, and tell
macolima the shape FIRST.** This is a sequencing request, and it is the one
thing in this handoff that can break a green consumer:

`macolima/scripts/vendor-tools.sh` mirrors exactly two artifact kinds,
`wheel+skill` and `plugin`, and its verifier ends the `case` with a hard `die`:
*"unknown artifact kind … A new kind must be taught here explicitly rather than
skipped, or it would enter the image unverified."* It fails closed, which is
correct — but it fails for **every** artifact, not just the new one, so the next
`just vendor-tools` on the host stops dead until the consumer is taught the new
shape.

So: **decide the shape, send it, publish after macolima confirms it can mirror
it.** Two candidates, and the choice is yours because it is your schema:

- **(a)** extra fields on the existing `paperbridge` entry — a second wheel path
  and a constraints path beside `wheel`/`skill`, keeping `kind = "wheel+skill"`.
  Nothing new to teach a mirror that already walks that arm, and the three files
  can never be published at different commits because they are one entry.
- **(b)** separate artifacts with a new `kind`. Cleaner if the bibtexparser
  wheel is ever wanted independently of paperbridge — but then two entries carry
  two `source_commit`s that can drift, which is the failure `asserts` exists for
  in the `myconv` entry.

**Recommendation: split them — and this is not an aesthetic preference, it is
forced by code on our side.** macolima's wheel-delivery step (the half that
fills a profile's flat index) was written while this handoff was being drafted.
It reads an opt-in file naming **artifacts, one per line**, and for each one it
copies that entry's single `wheel` field, refusing anything that is not a
wheel-bearing artifact. Consequences:

- **The bibtexparser wheel must be its own artifact (b).** A consumer repo maps
  `bibtexparser` to the flat index by name, so the wheel has to be deliverable
  on its own. A second wheel riding as an extra field on the `paperbridge` entry
  cannot be named in an opt-in file and is never read by the delivery loop — it
  would reach the image and never reach a repo.
- **The constraints file should be a field on the `paperbridge` entry (a).** It
  is consumed only at image build, no flat index wants it, and it is meaningful
  only for one wheel at one `source_commit` — as a field it cannot drift from
  what it pins.

The drift objection to a second entry is the one your `myconv` entry already
answers with `asserts`: if the bibtexparser wheel becomes its own artifact, an
assertion tying it to the paperbridge version it was resolved for is the
existing mechanism for saying so. You own the schema and the publisher; this is
a recommendation with its reason attached, not a request.

**D0.5 — the release-process question (c).** Should paperbridge's own release
process carry the constraints file from now on — i.e. does `just dist` (or the
publisher) emit it every time, so a paperbridge release cannot ship without the
pins that make it installable in a sandbox?

Your ADR-0001 already contains the argument for yes: *"Decisions 5 and 6 are
lockfile facts, not source facts … A drift check belongs in the publish gate
rather than in prose."* A constraints file generated by hand once is precisely
prose. But it is a change to your release process, it costs something on every
publish, and you can see the cost from inside; we can only see the failure mode.
**Answer it explicitly either way** — "no, it is regenerated on demand" is a
fine answer if someone owns the regeneration.

## 5. What happens on the macolima side (for context; nothing here for you to do)

macolima carries the Dockerfile install block, a new ADR superseding its
zero-runtime-dependencies invariant, a `verify-sandbox` check that
`paperbridge --version` runs as the agent user and that the three extras import,
and the `vendor-tools` change that mirrors whatever shape D0.4 settles on.

Payload classes, named rather than routed: this adds **wheel-class** payload
(two files that are baked into an image) and **no skill-class change** — the
0.3.0 `SKILL.md` already tells agents the CLI is baked, which is a sentence
macolima is currently making true. Nothing you publish requires a decision from
you about rebuilds, converges or restarts; that tier picks its own verb.

One thing worth knowing because it explains the urgency: the shipped skill's
*"If `paperbridge` is missing or outdated, STOP. It is baked into the image"* is
false in macolima's image today. It is baked in no container anywhere. Either
the bake lands or the skill stops converging; the owner chose the bake.

## 6. What to hand back

Into `macolima/work/0010-paperbridge-delivery/` via the owner (macolima has no
inbox; the owner ferries), or in the thread carrying this doorbell:

1. **D0.4's answer first — the publish shape — because macolima's
   `vendor-tools` change waits on it**, and publishing before it lands breaks
   `just vendor-tools` for every artifact.
2. The two D0.1 check results, in one line each. If `sgmllib3k` is still in the
   graph, everything below changes and this is where it surfaces.
3. Confirmation that the bibtexparser wheel was built from the lock's sdist with
   the sha256 verified before the build, and that the result is `py3-none-any`.
   The channel's manifest carries the wheel's own hash — don't retype it here;
   cite the manifest.
4. The exact `uv export` invocation you shipped with, if it differs from D0.3,
   and your answer on `--no-hashes`.
5. **D0.5's answer** — does paperbridge's release process carry the constraints
   file going forward, and if so, from which version.
6. Anything in §3 that reads differently from inside your tree, especially
   whether the bibtexparser wheel was ever built before and where it went.

Closing state from this side: macolima owes you nothing until you answer D0.4;
after that it owes you the `vendor-tools` change that can mirror the new shape,
and a note when the bake is green so the sibling ferry can follow. Nothing else
is outstanding in either direction.
