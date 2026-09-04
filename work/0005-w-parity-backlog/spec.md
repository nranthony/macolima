# work/0005 — the windows-ai-sandbox parity backlog

Scan run 2026-09-03 against `windows-ai-sandbox@52b7c91` (clean) from
`macolima@dev/0002-vendor-tools`.

**W already wrote most of this.** `docs/handoff-to-macolima-port-forward.md`
(329 lines, anchored `main@eda42dd`) is a deliberate handoff addressed to this
repo. This spec re-validates it against what has since landed here rather than
restating it — where the two disagree, the measurement below is newer.

## 0. Already closed since that handoff was written

Verified in this repo today, not assumed:

| Handoff item | State here |
|---|---|
| Phase 0 — seccomp `creat` | **done** (`seccomp.json:52`) |
| Phase 0 — openssl/libssl3t64 in-layer upgrade | **done** (`Dockerfile:48`) |
| A1 subnet allocator | **done** (`ensure_subnet_octet`) |
| C1 vendoring via one channel door | **done** (work/0002 V1+V3) |
| C3 skills convergence | **done** (work/0004 V5) |
| the wheel layer | **done** (work/0004 V4) |
| webfetch broker + ADR-0011/0012 design | **done** (work/0005 part 1) |
| `secrets.env` | **done** |

The handoff's §8.3 open question — "does `/usr/bin/env bash` resolve to 3.2 or
5.x?" — is answered: **3.2.57**. All five `mapfile` sites it names are real
hazards here. Three are fixed (webfetch suite); two remain in
`private-names-check.sh`, unported.

Suite count: W said 10 there / 1 here. It is now **7 here**. The three absent
each need their subject ported first — which is the handoff's own rule, and the
reason they are absent rather than stubbed.

## 1. Ranked backlog

Ordered by risk closed per unit of work, not by size.

### P1 — `private-names-check.sh` — **DONE 2026-09-03**
**~94 lines, 2 mapfile sites, no substrate risk.**

This repo is public (`github.com/nranthony/macolima`) and profile names double
as real client/project names. Measured today, `therapod` appears on **11**
high-visibility surfaces including `README.md`, `justfile`, `scripts/profile.sh`
and `scripts/with-egress.sh`; `nranthony` on **10**. W added this gate for
exactly this and flagged that we carry "the same client names with the same
public exposure and no check".

The standard is SEARCHABLE, not absent: evidence-bearing uses (the allowlist's
provenance comments, where the name IS the checkable evidence) are out of scope
by design. Needs a `.private-names.local` — it `[SKIP]`s loudly until one
exists, which is the same three-state contract `vendor-tools.sh` uses.

### P2 — Phase D: multi-agent policy — **DONE 2026-09-03**
**The largest item and the one with a live hole.**

`agy` is installed in this image and has **no policy file at all** — no
`permissions`, no hooks, nothing. W ships
`sandbox_templates/antigravity/{antigravity-settings.json,hooks.json,README.md}`,
a `guardrails.sh` symlink, `converge_agent_policies`, `probes/antigravity.py`
and `agent-policy.test.sh` (53 assertions).

It also upgrades the hook from M's **deny-only, single-dialect** shape to
three tiers (warn/ask/deny, ADR-0008) across two dialects. Four things the
handoff says must not be unified, each a hole if they are:

1. Claude fails **open** (static `permissions.deny` underneath); `agy` fails
   **closed** (the hook IS the control). Claude's pass-through `{}` is a DENY to
   `agy`, so the antigravity pass must stay explicit `{"decision":"allow"}`.
2. The ask tier is dialect-branched: Claude `permissionDecision:"ask"`, `agy`
   `decision:"force_ask"` — because `agy` caches a plain `ask` as a permanent
   Always-Allow, so `ask` there means "prompt once, then delete freely forever".
3. An unknown `--dialect=` must be FATAL, not coerced to claude.
4. Convergence modes stay opposite: Claude overwrites, `agy` merges.

Port ADR-0010 + 0011 as ONE unit. Needs a rebuild + recreate to verify, not a
converge. Brings the `converge` verb, which is what `reset-skills` is currently
holding a name open for.

### P3 — the accepted-open allowlist probe — **DONE 2026-09-03**
**Small, and it fixes something the owner asks about every session.**

M's `planning_mode_commented` cannot tell a deliberately-open block from a leak,
so it reports DRIFT either way and gets skimmed past. W's carries an
`ACCEPTED_OPEN_TAGS` set, so a deliberate opening is silent and a forgotten one
is loud. Directly improves the standing "remind me if I leave it unsafe" ask.

### P4 — the agent notice — **DONE 2026-09-03**
`sandbox_templates/common/agent-notice.md` + `sync-agent-notice.sh` +
`agent-notice.test.sh` (13). Injects a managed block into each profile's global
`~/.claude/CLAUDE.md`, so agents see the sandbox's capabilities and prohibitions
even in a workspace whose own AGENTS.md is stale.

**Needs a substrate pass its own test will not catch** (handoff §5.2): the title
names `windows-ai-sandbox`, five `/root` paths, and lines 133–152 are a WSL2/CUDA
block describing hardware we do not have. Delete that block; do not adapt it.
`agent-notice.test.sh` passes 13/13 on the unadapted file because its locks are
about repo-relative paths, not substrate applicability.

### P5 — `recreate-all` + `docker-gc.sh` — **DONE 2026-09-03**
Two independent conveniences, both platform-neutral.

`recreate-all` force-recreates every running profile onto the current image —
the exact gap that has made every `just build` in this session end with
"now recreate each profile by hand". `docker-gc.sh` (157 lines) reclaims Docker
disk no profile's lifecycle owns; worth a Colima pass on the sizing numbers,
since the VM disk is a one-way sparse ratchet here.

### P6 — `AGENTS.md` + `sync-agent-files.sh` — **DONE 2026-09-03**
`agy` reads `AGENTS.md` natively; this repo has only `CLAUDE.md`, so the second
agent we ship has no repo guidance at all. W generates thin `CLAUDE.md` entry
points that `@`-import the `AGENTS.md` beside them (generated files, not
symlinks). Pairs naturally with P2.

### P7 — `docs/adr/` — **DONE 2026-09-03**
W has 12 ADRs; this repo has none. At least six describe decisions **this repo
has already adopted** and currently records only in commit messages and work
items: 0003 strict-egress-default, 0004 python-wheels-only, 0005
skill-templates-are-source-of-truth, 0008 deletion-is-a-human-step, 0009
public-repo-names, 0011/0012 web-read. Cheap, and it is what stops the same
decision being re-litigated.

### P8 — `check-permissions` (work/0002 V6) — **DONE 2026-09-03** (report only)
The depot manifest proposes 19 allow / 11 ask / 2 deny for myclickup.
`vendor-tools.sh --permissions` REPORTS the proposal against
claude-settings.json and never edits it. (Adopted later the same day — §8
item 1 — with three writes promoted to allow, which the report shows as
PROMOTED, a recorded owner decision, not a gap.) Keep it read-only: an artifact must not
widen the sandbox by being vendored.

### P9 — allowlist blocks worth considering — **DONE 2026-09-03** (1 added, 3 refused)
`[openrouter]`, `[openai]`, `[google-fonts]`, `[citation-tools]`. Each is a
per-need decision, not a batch. Parser trap to respect: the block-open regex is
`\[[a-z-]+\]`, so a dot or digit in a tag makes the block unopenable by
`with-egress.sh` while looking correct in the file.

### P10 — smaller doc/process carries — **DONE 2026-09-03**
`docs/extending-a-profile.md`, `docs/sibling-repo-relationship.md`,
`sandbox_templates/skills/UPSTREAM.md` (skill provenance), and a `LICENSE` —
this repo is public and has none.

### P11 — the allow-list gap that was costing prompts — **DONE 2026-09-03**
**Not from the scan.** Found by reading a live profile's transcripts after the
owner asked why auto mode kept prompting for benign reads. The Bash matcher
evaluates EVERY segment of a compound command, and `head`, `echo`, `cd`, `grep`,
`cut`, `tail`, `sort`, `uniq`, `wc` were on no list — so 74% of subagent Bash
calls (175 of 236, measured) could only proceed via the auto-mode classifier and
were prompt-eligible. Latency proved some did stall: **0 of 61** fully
allow-listed calls ever exceeded 20s against **7 of 175** unlisted ones, the
worst 1456s — 24 minutes on `cd … && grep -liE …`, inside a background agent
with nobody watching.

Nineteen read-only utilities added to both grammars. They grant no new write
reach: `Bash(cat:*)` was already allow-listed and `cat > file` already writes,
and the hook blocks redirects into the sandbox's control paths whichever command
produces them. `sed`/`awk` deliberately stay denied — 11 hard denials in the same
logs, all agents using `sed -n '1,40p'` as a pager, which is a deny-list bypass
with a direct replacement (`Read` with offset/limit). The notice now says so.

**Owed back to W** — see §3 item 13; their list has the same gap.

## 2. Deliberately EXCLUDED

Recorded so absence is not read as oversight and re-litigated later.

**GPU/ML stack** — `[comfyui]`, `[comfyui-models]`, `[comfyui-models-extra]`,
`[pytorch]`, `[fal]`, `[nvidia]`, `[blender]`, `[kaggle]`, `[numerai]`, plus
`ffmpeg`, `libgl1`, OpenCV and the uv-managed CPython 3.12/3.13 layer. This is a
48 GB WSL2 host with `/dev/dxg`; Colima at 8 GB with no GPU has no use for it and
the image growth is a straight loss. If media tooling is ever wanted it is a
FRESH item against this substrate, not a port.

**Also excluded**, per prior owner decisions: `glab` / `auth-gitlab` (GitHub-only
here, deliberately), `beads`, the PDF/OCR stack (pandoc/WeasyPrint/tesseract) and
`common/pdf-styles`, every profile-specific allowlist block,
`docker-compose.wsl-gpu.yml`, `win_setup/`, `host_setup/`, `container_testing/`.

**Not ours to take:** `opencode` (W's work/0009) stays out until they unpark it.

**Not applicable:** `init-profile-state.sh` — W's separate bootstrap; this repo
does the same work inside `profile.sh`'s `ensure_state`, and having both would be
two sources of truth for profile seeding.

## 3. What W is owed back

The handoff §9 asks for a report. Accumulated so far:

1. **F5** — `converge_skills`' staged replace is cross-device on macOS
   (work/0004 §2). A portability defect in W's own function.
2. **`docs/web-read-broker.md`** says "recreate the agent to pick it up" and then
   prints `up`, which does not re-read `env_file`.
3. **W's depot pointer is unset** — `just tools-check` green over a disconnected
   channel, second occurrence (work/0002 §6).
4. **`docker builder prune --keep-storage`** silently negates `--refresh-ai`
   (work/0001 §4): measured 22s → 97s → 97s with 0 cached layers, against
   21s/21s/21s under `--filter until=168h`. W carries the same line.
5. §8.3 answered: `/usr/bin/env bash` here is **3.2.57**.
6. **A bash-3.2 hazard their §1.2 does not list.** `"$( … "…" … )"` — a nested
   double quote inside a double-quoted command substitution — terminates the
   OUTER quote in 3.2.57, leaving the result unquoted and brace-expanded. One
   site in `deny-destructive.test.sh` (the `dep-add via Write` assertion) arrived
   as TWO arguments, so `assert` read `want` from the second half. Measured
   argc=5 inline / argc=4 hoisted, and instrumenting all 155 assertions proved it
   was the only affected site. Their §1.2 lists `mapfile` only; this belongs
   beside it.
7. **`private-names-check.sh` scans contents only.** A tracked PATH is at least
   as searchable as a line inside a file. Added here; they have profile-named
   files too.
8. **The block walker in `proxy.py` opens a block on a tag mention.** Their copy
   guards with `"---" in raw`; this repo's had dropped it, and adding one tag
   made a comment that merely NAMES another block re-tag eight always-on hosts.
   Worth a note that the guard is load-bearing, not cosmetic.
9. **`agent-notice.md`'s "What works" line names `/usr/lib/wsl/lib/nvidia-smi`**
   outside the CUDA section their handoff told us to delete — so following the
   instruction exactly leaves a dangling WSL reference.

10. **`sync-agent-files.sh` overwrites `CLAUDE.md` unconditionally.** `cat >`
    with no existence check, no marker check, no backup. Safe in W only because
    its migration already happened and its root `CLAUDE.md` is already the
    stub — but it is one `AGENTS.md` away from truncating a real file in any
    directory. Our copy refuses unless the target carries the GENERATED marker.
11. **That script's exclusion list is `.git` and `docs/_archive` only.** Both
    repos carry two `AGENTS.md` files that are NOT repo guidance —
    `sandbox_templates/skills/myconv/.../templates/AGENTS.md` (payload inside a
    vendored plugin; a file beside it changes the tree hash, so `tools-check`
    reports DRIFT and the next vendor deletes it) and
    `scripts/depaudit-fixtures/docs-injection/AGENTS.md` (a fixture whose
    assertion is "install command lives only in AGENTS.md"). Running the script
    in W today writes into both.
12. **`[openrouter]` and `[openai]` are ALWAYS ON with `# claude, fill in here`
    as their justification.** Two permanent third-party LLM POST targets with no
    stated reason, in a file whose own header requires one per block.
13. **The read-only text utilities are missing from their allow list too.**
    None of `head`, `tail`, `cut`, `cd`, `echo`, `grep`, `sort`, `uniq`, `wc`,
    `nl`, `tr` is in their 58 entries. Since the Bash matcher checks every
    segment of a compound command, this is the same prompt-stall we measured
    here: 74% of subagent Bash calls prompt-eligible, seven stalls over 20s, the
    worst 24 minutes. Their substrate does not change the arithmetic. This is
    probably the highest-value single item we owe them.
14. **Their `docs/sibling-repo-relationship.md` has gone stale in three
    places** — it still says macolima has the seccomp `creat` bug unreported (it
    landed), that macolima has 1 offline suite against their 10 (it is 10 and
    10), and it advises `diff seccomp.json` expecting byte-identity when the two
    files legitimately differ in their substrate comments.

## 8. Still open, in rank order

**P1–P11 are all landed.** What remains is not port work:

1. ~~Adopt or reject the myclickup permission proposal~~ — **DECIDED
   2026-09-03: adopted, mirroring W tier-for-tier** (21 allow / 8 ask / 2 deny;
   the channel's 19 / 11 / 2 with `comment`, `set-status` and `update` carried
   into allow). Reasoning lives in the claude template's `_myclickup_note`;
   `just check-permissions` now reports those three as PROMOTED rather than
   MISSING. Residual for agy only: an approved `ask` is cached as a permanent
   Always-Allow, so the eight asked writes are one approval from permanent per
   profile — wiring them through the hook's `force_ask` is the open follow-up.
2. **Set `CLICKUP_TOKEN`** in a profile's `secrets.env` and `recreate` — the
   plumbing has been in place since work/0004 §5 and has never been fed a token.
3. **Decide whether `agy` should get the notice per workspace** — the mechanism
   exists and is documented in `sandbox_templates/antigravity/README.md`, and is
   deliberately not wired into `up` because it writes into the operator's own
   git tree. Until then agy is gated but not briefed.
4. **Decide whether to keep tracking per-profile compose overlays**
   (`docker-compose.<profile>.yml`), currently scoped out of
   `private-names-check.sh` with the reason recorded.
5. **Send §3's fourteen items back to W.**
6. **Three judgement calls from the 2026-09-03 re-scan, default no.** Not GPU
   work despite where §2 files them; each is a per-profile need, not a port.
   - ~~*Baked CPython 3.12/3.13 via uv*~~ — **ADOPTED 2026-09-03**, patch
     level unpinned so rebuilds pick up security releases. Dockerfile block
     sits above the myclickup wheel; §2's exclusion of it is superseded.
   - *PDF stack* (pandoc + WeasyPrint + tesseract + poppler, metric-compatible
     fonts, `common/pdf-styles/legal.css`) — travels as ONE unit; pairs with
     `[google-fonts]`. Only if a profile needs document generation.
   - *`[grants-gov]` / `[quarto-install]`* — profile-specific blocks. Add
     `[grants-gov]` pinned to the `api.*` hosts when a profile needs it;
     `[quarto-install]` is `[git]`'s hosts and needs nothing until Quarto is
     installed.
