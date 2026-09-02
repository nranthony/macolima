# work/0002 — vendored tools and skills, via the depot channel

Branch: `dev/0002-vendor-tools`, from `main@055fa9a` (work/0001 merged 2026-09-02).

Supersedes the sketch in `work/0001-port-from-windows-ai-sandbox/plan.md`
§Phase C (C1, C2, C2a, C3). That section stays as written — it is the record of
what was believed before the channel was read directly. Where the two disagree,
**this file wins**, and each disagreement is named below.

## 0. Anchors, measured 2026-09-02

| | |
|---|---|
| `windows-ai-sandbox` (W) | `52b7c91`, clean — "Merge: ComfyUI and fal into the sandbox…" |
| depot channel | `/Volumes/DataDrive/repo/nranthony/depot`, HEAD `9aebf07`, **6 files dirty** |
| macolima (M) | `main@055fa9a` |

The channel moved to `repo/nranthony/depot/` and was **mid-publish** when this
was written (myclickup rotating 0.7.0 → 0.6.1: manifest, wheel and RELEASES.md
all uncommitted). Treat every version number here as a snapshot, never a pin.

## 1. What the channel actually is

`depot/` aggregates artifacts from member checkouts into `dist/`, with
`manifest.toml` as the machine record (versions, sha256, source commits,
proposed permissions) and `RELEASES.md` as the human one. `just publish <tool>`
runs the member's own gate, refuses a dirty tree, content-checks the wheel
against source, derives permissions from the live CLI parser, and rewrites both
records. **Hashes and permissions are derived, never hand-written.**

**It is TWO artifacts, not one** — the single most common wrong assumption
about this system, and the one §Phase C carried:

| artifact | kind | source repo | delivery |
|---|---|---|---|
| `myclickup` | wheel **+** skill | `myclickup` | wheel → image; SKILL.md → profile |
| `myconv` | plugin tree, **6 skills** + templates | `agentic-conventions` | → profile |

`myconv`'s six: `apply-conventions`, `clickup-pull`, `clickup-report`,
`make-plan`, `report-skill-feedback`, `wrap-up`.

`paperbridge` is a member checkout that has **never been published** (absent
from the manifest); `feedback/` is not a git repo. Neither is in scope here —
but note M's allowlist already carries a `[paperbridge]` block, so the tool
exists in this ecosystem and may arrive later.

## 2. Decisions already taken

**D1. Convergence is the default, per ADR-0005.** Owner decision 2026-09-02.
`sandbox_templates/skills/` becomes the source of truth and a profile's
`claude-home/skills/` a derived cache, reconciled on every `up`. M's current
create-only seeding (`profile.sh` `ensure_state`) goes.

The reasoning is not preference. Create-only *causes* the drift it appears to
prevent: a template edit reaches a profile only if someone remembers
`reset-skills`, and W measured vendored skills 6 and 34 lines behind source
while every profile sat 11 days behind `audit-sandbox`. Worse, ADR-0005 records
a *verified* failure — `~/.claude/skills/` is scanned for skills-dir plugins, so
a `<name>.bak.<stamp>` sibling **loads instead of** the fresh copy
(`claude plugin list` reported the real one `✘ Not loaded — same plugin name`).
Backups inside the scanned directory are not inert. So: no backups, ever.

**D2. User-authored skills are not collateral.** `converge_skills` keeps a
`.sandbox-seeded` manifest and prunes only names it seeded. A skill the user
created in a profile is reported (`INFO … leaving it alone`) and left. This is
what makes D1 safe to adopt wholesale.

**D3. Overwrites and prunes WARN, never silently.** Silent reconciliation trades
one invisible failure for another.

## 3. Ordered work

### V1 — the channel pointer, and the trap it exists for
`$DEPOT_DIR` or a gitignored `.depot-dir.local`. **Three states, three
outcomes**, never two:

- nothing configured → loud `[SKIP]`, exit 0 (ordinary; `--check` only)
- configured, target missing → **FAIL, exit 1** (a broken pointer is never ordinary)
- configured and present → proceed

No guessed fallback path. A guess collapses "never configured" and "moved away"
into one output, and the collapsed state is the silent one.

**This is not hypothetical, and it is not historical: it is true in W right
now.** W has no `.depot-dir.local` and no `$DEPOT_DIR`, so after the move to
`repo/nranthony/depot/` its `just tools-check` reports SKIP and exits 0 —
green, vendoring nothing. `vendor-tools.sh`'s own header records this exact
failure from the 2026-08-14 move ("invisible to both existing monitors while a
real three-release wheel drift went green"). It has now happened twice.
**Send W a one-line `.depot-dir.local` as part of this work.**

### V2 — `sandbox_templates/` layout
`config/` → `sandbox_templates/{claude,common,skills,wheels}`.

**Correction (applied 2026-09-02).** This item originally said to leave
`config/hooks/` in place "so `deny-destructive.sh`'s hardcoded path in
`verify-sandbox.sh` and `scripts/audit/probes/settings.py` does not move twice".
That was a misreading of `CLAUDE.md`: the hardcoded path those two files carry
is the CONTAINER path `/usr/local/lib/claude-hooks/deny-destructive.sh`, which
this move does not touch. The repo-side source is referenced in exactly three
places — the Dockerfile `COPY`, the justfile test path, and one comment — so it
moves to `sandbox_templates/claude/hooks/` with everything else, matching W and
avoiding a permanent split in the tree.

`VENDORED.lock` sits at the templates **root as a FILE**, deliberately:
`converge_skills` iterates directories, so a file there can never be carried
into a profile.

### V3 — `vendor-tools.sh` (W: 579 lines, + a 399-line suite) — **DONE 2026-09-02**
One door for every artifact. Verifies **every** hash before copying **any**
file — a partial mirror is a half-updated image with no record of which half.

**Call the channel's `bin/dirhash.py`; do not reimplement it.** Tree identity is
a cross-repo contract (depot's own justfile says so). A bash reimplementation
would be a new boundary of exactly the kind the channel exists to delete.

The single Python dependency is bounded and intentional: the manifest is TOML,
read once via `python3 -m tomllib` into flat TAB-separated lines; everything
downstream is bash + coreutils. `VENDORED.lock` is deliberately **not** TOML —
flat `artifact version sha256 source_commit`, awk-readable — so there is never a
second parser of a security-relevant file.

`VENDORED.lock` is tracked and is the only committed evidence of what an image
contained: the wheel and `skills/myclickup/` are gitignored, because this repo
is public and myclickup is not.

**Landed with one deliberate gap, stated in the script's own header and in its
`--check` output: the CONTENT check.** A hash proves an artifact did not change
in transit; it cannot prove the wheel matches the `source_commit` it claims. W
cross-checks each artifact against its member checkout when reachable, via the
member-pointer machinery (`member_pointer`/`member_dir`/`member_subtree`,
~100 lines). Deferred rather than half-done — a check that implies more coverage
than it has is worse than none.

### V4 — the wheel layer in the Dockerfile
`COPY sandbox_templates/wheels/ /tmp/wheels/` then a conditional `uv tool
install`. Four properties, each load-bearing:

1. **Directory copy, not a glob.** A `COPY` matching nothing is a hard build
   failure; a `.gitkeep` keeps the directory in the context so a clone without
   the private payload still builds.
2. **Conditional install.** No wheel ⇒ no myclickup, build still green.
3. **Two wheels is a refusal, not a pick-one.** The vendor script rotates the
   file on every bump, so two means a failed rotation, and choosing silently
   would ship the wrong version behind a correct-looking `myclickup --version`.
4. **Placement: AFTER Gate 3, at the tail.** Pre-1.0 this is the most
   frequently re-vendored artifact in the tree; above the `ARG AI_CLI_REFRESH`
   cache-buster every bump would re-run the Claude Code/agy install and both
   gate layers. M gained that cache-buster in `0141a0f`, so the constraint now
   applies here identically.

Gate 3 (`no-build = true`) is not an obstacle: a wheel is never built. W
verified the install needs no network (zero deps) in a `--network none`
container.

`dockerfile-order.test.sh` gains a fifth anchor (the wheel `COPY`/install), and
its header note — which currently names `beads` as W's one unported anchor —
gains the wheel layer as a deliberate M addition rather than a W import.

### V5 — convergence (D1)
Port `converge_skills` **verbatim**. W wrote it bash-3.2-clean *specifically so
it ports to this repo unchanged* — space-padded membership tests via case-glob
rather than associative arrays. Do not "improve" it; a divergence here is a
divergence in the only mechanism that keeps profiles current.

Carries `profile-skills.test.sh` (157 lines). `reset-skills` survives as
"converge without touching the container".

### V6 — the permissions leg
The manifest proposes `allow`/`ask`/`deny` per artifact (myclickup: 19/11/2).
`vendor-tools.sh --permissions` **reports** the proposal against
`sandbox_templates/claude/claude-settings.json` and never edits it. Keep that read-only property:
an artifact must not be able to widen the sandbox's permission surface by being
vendored. Applying a proposal is a human decision.

### V7 — egress
`myclickup` needs `app.clickup.com` / `api.clickup.com` (+ the attachment
hosts). **Not added by this work.** Adding a domain is a separate, justified
decision per `CLAUDE.md`, and the tool is useless without credentials anyway.
Decide per profile at the point of use — Phase E's rule.

## 4. Where this contradicts work/0001 §Phase C

1. **"the packages (is it just one: myclickup?)"** — no. Two artifacts; `myconv`
   delivers six skills and a template tree. §C1 read as if the wheel were the
   whole payload.
2. **§C2 "`myconv`/`myclickup`: per-profile decision"** — the *vendoring* is
   repo-wide (both land in `sandbox_templates/`); only the permission proposal
   and the egress are per-profile.
3. **§C3 cites `profile.sh:151-158`** — stale. The seeding block is now at
   `profile.sh:395-408` after work/0001's edits.
4. **`web-read` + `bin/webfetch` (§C2)** — W-only, and it depends on ADR-0011/
   0012 backend design plus `webfetch.test.sh` with three `mapfile` sites to
   fix. Explicitly **out of scope for work/0002**; it is not a channel artifact
   and does not gate the vendoring pipeline.

## 5. Definition of done

- `just vendor-tools` populates `sandbox_templates/` from the channel, hash-gated
- `just tools-check` FAILS on a stale lock and SKIPs loudly when unconfigured
- `just check-permissions` reports, and provably does not edit
- `just build` bakes the wheel when present, stays green when absent, refuses two
- `myclickup --version` works in a rebuilt container
- a template skill edit reaches a running profile on the next `up`, with a WARN
- a user-authored profile skill survives convergence untouched
- `test-offline` carries `vendor-tools.test.sh` + `profile-skills.test.sh`
- `VENDORED.lock` committed; wheel and `skills/myclickup/` gitignored

## 6. Back to W

1. **Its depot pointer is unset** — `just tools-check` is green over a
   disconnected channel, second occurrence of the same failure (§V1).
2. Both members were ahead of published on 2026-09-02 (`myclickup` 48f83be53 vs
   eb2b25a47; `myconv` b98ec792a vs d2b3d0435) — `just verify` in depot reports
   it, nothing in W does.
