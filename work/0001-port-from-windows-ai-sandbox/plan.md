# 0001 — Port stable windows-ai-sandbox work forward to macolima

**Status:** Planned 2026-08-23 from a read-only comparison run on Linux.
**Re-validated and re-anchored 2026-08-31** (§0.1), then **re-measured on the
macOS host the same day** (§0.1a) — which is where §0.1's numbers were found to
have been taken at W HEAD rather than at the anchor. **Phase 0 executed and
green 2026-08-31 (`a623808`); Phases A-E not started.**
Execution requires the macOS/Colima host — every step below that touches the
image or compose needs `scripts/profile.sh build` + `<p> rebuild` and a `--verify`.

**Shelf life:** delete or archive on merge.

**Source:** W = `/Volumes/DataDrive/repo/sandbox/windows-ai-sandbox` on this host.
(Earlier revisions of this plan said `~/repo/sandbox/windows-ai-sandbox`; that is
the Linux box's path and does not exist on the Mac. Every W path below is
relative to the DataDrive checkout.)

**RE-ANCHORED 2026-08-31.** This plan originally pointed at `21fdbde`, a HEAD on
W's unmerged `feat/0010-antigravity-guardrails` branch. That pointer is now
meaningless. **The anchor is `W main@eda42dd`** (2026-08-26): everything at or
below it is a port candidate; above it is W's ComfyUI/fal work, excluded except
for four named carve-outs (§0.2).

**The re-diff this plan asked for has been done** — see §0.1, **as corrected by
§0.1a**. Phase D's stated blocker genuinely cleared on 2026-08-24. But §0.1
compared M against W **HEAD**, not against the anchor it had just declared, so
its table overstates the port surface and its `seccomp.json` "DIVERGED" row is
an artifact of that: at `eda42dd` the two files are byte-identical.

**Read [`docs/handoff-to-macolima-port-forward.md`](https://github.com/nranthony/windows-ai-sandbox/blob/main/docs/handoff-to-macolima-port-forward.md)
in W alongside this file** (locally:
`/Volumes/DataDrive/repo/sandbox/windows-ai-sandbox/docs/handoff-to-macolima-port-forward.md`).
It is the executable form of this plan: counted `/root`
substitutions, the five bash-4 sites, per-phase mechanics, and the questions
only this host can answer. This plan stays the strategy; that document is the
procedure. **Read in full on this host 2026-08-31 and fully consumed** — the
earlier "not yet read" note here was stale, written before the Phase 0 session.
Every section of it is reflected below: its §2 table → §0.1 (corrected by
§0.1a), §1.1/§1.2 → §1.1, §3 → §0.1 tail + §0.2, §4 → Phase A0, §5.0-5.4 →
Phases 0/A/C/D/E, §8 → §4. **Nothing in it is outstanding.** Its own counts
predate the anchor correction in §0.1a; spot-check any it reports against
`git show eda42dd:<path>` rather than against W's working tree.

---

## 0. State of play (measured 2026-08-23)

- Core threat model still shared: `seccomp.json` byte-identical; `squid.conf`
  rulesets semantically equivalent (M spells `deny CONNECT !SSL_ports`, W uses
  `allow CONNECT SSL_ports allowed_domains` + blanket deny).
- Drift is almost entirely additive on W's side. Line counts W/M: `profile.sh`
  1724/713, `with-egress.sh` 766/188, `deny-destructive.sh` 485/154,
  `verify-sandbox.sh` 589/236, `Dockerfile` 560/242, `justfile` 280/138.
- Only two prior W→M ports: glab removal + pnpm/agy/resource-limit ports
  (`5679866`). Both `MACOLIMA_in-transit_*.md` files are effectively closed and
  should be archived by this item.
- W has written material *addressed to macolima* that M never consumed:
  `docs/handoff-to-macolima-subnet-allocator.md` (bash-3.2-safe allocator),
  ADR-0005 (lists macolima under Affects), `sync-agent-notice.sh` (written in the
  bash-3.2/POSIX-awk subset "for macolima"),
  `docs/dependency-guardrails-handoff.md` item D5 (cross-port scope).

## 0.1 Re-diff, measured 2026-08-31 (SUPERSEDED — read §0.1a)

| §0 said (2026-08-23) | Measured 2026-08-31 |
|---|---|
| `seccomp.json` byte-identical | **DIVERGED** — `creat` + comment (W `ce860b3`) |
| `profile.sh` 1724/713 | **2136**/713 |
| `with-egress.sh` 766/188 | 1040/188 |
| `verify-sandbox.sh` 589/236 | 735/236 |
| `deny-destructive.sh` 485/154 | 736/154 |
| `Dockerfile` 560/242 | 753/242 |
| `allowed_domains.txt` (unstated) | 719/278; **32 tagged blocks / 15** |
| offline test suites (unstated) | **10 / 1** |
| `squid.conf` semantically equivalent | **confirmed**, line by line |
| Phase D "HOLD until W 0011 lands" | **0011 merged 2026-08-24 — UNBLOCKED** |

New since this plan was written and not described anywhere in it: W's seccomp
`creat` fix (we have the same `tar -cf` bug today, unreported), the in-layer
openssl/libssl3t64 upgrade for CVE-2026-45447 (our base ships the same
vulnerable `ubuntu3.4` and we have no openssl handling at all), the third hook
tier, `converge_agent_policy`, the settled webfetch broker design,
`private-names-check.sh`, the single-channel `vendor-tools.sh`, and the depaudit
repo-root fix that must travel *with* A6. The handoff document tabulates all of
them with the reason each crosses.

## 0.1a Correction, measured on the Mac 2026-08-31

**§0.1's W column is W HEAD, not W@`eda42dd`.** The anchor was declared in the
same revision that took these measurements, but the measurements never moved to
it. Re-measured against `git show eda42dd:<path>`:

| File | §0.1 said | W@`eda42dd` | M | Note |
|---|---|---|---|---|
| `seccomp.json` | DIVERGED | **145 — byte-identical** | 145 | see below |
| `profile.sh` | 2136 | 2116 | 713 | |
| `with-egress.sh` | 1040 | 1040 | 188 | §0.1 correct |
| `verify-sandbox.sh` | 735 | 716 | 236 | |
| `deny-destructive.sh` | 736 | 736 | 154 | §0.1 correct; W path is `sandbox_templates/claude/hooks/` |
| `Dockerfile` | 753 | **568** | 242 | |
| `allowed_domains.txt` | 719 | **513** | 278 | |
| tagged blocks | 32 / 15 | **25 / 14** | | block headers incl. commented-out |
| offline test suites | 10 / 1 | 9 `.test.sh` / 1 | | **not an error** — see below |

The test-suite row reconciles: 9 files match `*.test.sh` at the anchor; the
handoff's 10th is `private-names-check.sh`, which is a check script, not a
`.test.sh`. Both counts are right under their own definition. Use **10** when
working from the handoff's §4 table.

The `Dockerfile` (−185) and `allowed_domains.txt` (−206) gaps are the proof: that
material is CPython 3.12/3.13 (`d76360c`), `libgl1` (`b16e75c`), genmedia+ffmpeg
(`4e86b54`) and the ComfyUI/`[pytorch]`/`[fal]`/HF allowlist blocks — all above
the anchor, all excluded by §0.2. **The real Phase A surface is smaller than
§0.1 implies. Do not size the work off that table.**

`squid.conf` semantic equivalence and the Phase D unblock are unaffected and
stand as recorded.

`seccomp.json`: M and W@anchor are byte-identical. The `creat` divergence is
entirely `ce860b3`, which sits **above** the anchor — so Phase 0a is a
deliberate cherry-pick from excluded territory, not a drift repair. See §0.2.

**This is A9's mistake a second time.** A9 was wrong because it reasoned from
file sizes instead of comparing checks; §0.1 was wrong because it reasoned from
a tree it hadn't pinned. Same failure — a cheap proxy standing in for the
measurement. A9's fix applies here too: compare *at a named revision*, and for
anything behavioural extract the checks rather than counting the lines. W
work/0021 §2 has the extraction method.

**The error is upstream, and W needs telling.** §0.1's table was not derived
locally — it is `docs/handoff-to-macolima-port-forward.md` §2 copied across, and
that document has the same HEAD-vs-anchor mismatch in a file whose own §7 opens
"This document covers everything at or below that anchor and nothing above it."
Two of its other measurements inherit the same slip: §5.1's
`profile.sh:1008-1083` (A1) and §6's "21 commits above the anchor" (now 27).
This goes back with the handoff's §8 answers — see **§4** — because W's
`work/0022` exits on our confirmation and `work/0021` is parked behind it.

## 0.2 Excluded — with four named carve-outs

W now has **27** commits above `main@eda42dd` (was 21; six more landed
2026-08-26..31, including the `52b7c91` ComfyUI/fal merge).

**Excluded:** the GPU/ML stack — ComfyUI, `[pytorch]`, `[fal]`, `[nvidia]`,
`genmedia` + `ffmpeg` + `libgl1`, CPython 3.12/3.13 baked via uv. Built for a
48 GB WSL2 host with `/dev/dxg`. This is a 6 GB VM with no GPU. If we ever want
media tooling it is a fresh item against **this** substrate.

**Not "everything above the anchor."** The earlier wording excluded the whole
range, which formally excluded two commits this plan itself depends on. Four
above-anchor commits are not GPU/ML and cross on their own merits:

| Commit | What | Where it lands |
|---|---|---|
| `ce860b3` | seccomp `allow creat` | **Phase 0a** — without this, 0a has no source |
| `e6bca33`… | *(below anchor — listed here only to avoid confusion; see 0b)* | Phase 0b |
| `ccf27a3` | depaudit enumerates repo roots (11 scanned → 16) | **must travel with A6** (§0.1 already said so) |
| `bd0e33f` | drops W's trivy openssl acceptance | Phase 0b housekeeping — **N/A to M**, we never had the entry |
| `f9b1a39` | operator override: closes `[numerai]` | **Phase E** — that candidate is now decided upstream |

Everything else above the anchor stays out.

## 1. Substrate rules (do not violate while porting)

| Axis | macolima | W | Consequence |
|---|---|---|---|
| Container user | `agent` UID 1000, non-root | root (rootless `userns=host`) | Every `/root/...` in W's hook, `Read` denies, probes → `/home/agent/...`. M's kernel write-protect on the hook is real; W's is not — keep M's stronger posture. |
| Host | Colima VM, 6 GB, virtiofs | WSL2, 48 GB | Never copy `mem 20g` / `pids 4096` / sidecar `2g`. Keep `pids 2048`, `mem 3g`. |
| GPU | none | `/dev/dxg`, CUDA base | Skip all GPU detection, `docker-compose.wsl-gpu.yml`, `nvidia/cuda` base. Keep digest-pinned `ubuntu:24.04`. |
| State root | `/Volumes/DataDrive/.claude-colima/` | `~/.ai-sandbox/` | Path substitution in `init-profile-state.sh`, dashboard `docker_client.py`, trivy `emit()`. |
| Shell | bash 3.2 for `setup.sh` | bash 5 | Port only code already in the 3.2 subset or rewrite; no assoc arrays, no `xargs -r`, `cksum` not `md5sum`. |

Judgement calls, not mechanical (decide per profile, default **no**): glab (M
removed deliberately), myclickup CLI, beads, PDF/OCR stack (pandoc/WeasyPrint/
tesseract), W's profile-specific allowlist blocks.

### 1.1 Host facts, measured on this Mac 2026-08-31

- **`/usr/bin/env bash` → GNU bash 3.2.57 (`/bin/bash`).** Homebrew is installed
  but its bash is not ahead of `/bin/bash` on PATH. This **settles the handoff's
  open question §8.3 in the strict direction**: the five `mapfile` sites are not
  a "note it" — they are a **hard blocker** and must be rewritten before those
  scripts run here at all. Sites (verified at the anchor, line numbers exact):
  `scripts/webfetch.test.sh` 124, 150, 169; `scripts/private-names-check.sh`
  53, 63. The mechanical rewrite is in the handoff §1.2.
  Treat bash 3.2 as the ceiling for **every** ported script, not just `setup.sh`.
- **The handoff's §1.1 `/root` table counts _lines_, not _occurrences_.** For a
  substitution task that undercounts the edits: `deny-destructive.sh` is 14
  lines but **24 occurrences**, `agent-notice.md` 5 lines but **8**. The rest
  match either way, and its four "zero occurrences" files are confirmed clean.
  Substitute with a global replace and verify by count, don't work the table
  line by line.
- **M's allowlist tags are all `[a-z-]`-safe** (checked: no digits, no dots), so
  A4's block-open regex `\[[a-z-]+\]` will not silently fail to open any
  existing M block. Keep that constraint in mind when *adding* tags.

## 2. Phases

### Phase 0 — parity hotfix — **EXECUTED 2026-08-31, green**

Applied on profile `therapod` (the only profile). Baseline captured **before**
the change, per §3.

| Check | Result |
|---|---|
| tier-2 audit, pre | 70 probes — OK 64 / INFO 4 / N/A 1 / **DRIFT 1** |
| tier-2 audit, post | 70 probes — **identical**; zero verdict changes |
| the 1 DRIFT | `settings/template_diff`, **pre-existing** — live settings vs repo template on `hooks`/`permissions`/`agentPushNotifEnabled`. Not Phase 0's. Open item. |
| `verify-sandbox.sh` | **24 passed / 0 failed / 0 warnings** |
| `creat` in live profile | present (group 234 syscalls) |
| `tar -cf` | exit 0 — **also exit 0 before the change**, see 0a |
| openssl / libssl3t64 | `3.0.13-0ubuntu3.4` → **`3.0.13-0ubuntu3.15`** |
| CVE-2026-45447 | **absent** from trivy HIGH/CRITICAL (scanned with **no** `.trivyignore.yaml`, so nothing suppressed) |
| `PROFILE=_test docker compose config` | clean |
| `just --list` | parses, 24 recipes |

Trivy still reports 10 HIGH findings — `brace-expansion`, `ip-address`, npm
`tar`, `golang.org/x/mod`. All npm/go dependency CVEs, all pre-existing, none
touched by Phase 0. Separate item.

Rebuild was a full one (the openssl line sits in the first apt layer, so every
downstream layer re-ran). `scripts/profile.sh <p> rebuild` does build +
force-recreate in one verb — that is the right verb here, not `recreate`.

**One judgement call, flagged for review.** 0a's second stated reason was to
restore *byte*-identity with W's `seccomp.json`. The syscall arrays now match
exactly — but the `_comment` does not, because it carries the aarch64 note from
0a. Literal `diff` therefore shows one comment-only hunk, permanently.

Kept the note deliberately: dropping it would delete the substrate finding that
justifies the entry, which is exactly what CLAUDE.md says to record, and a
comment cannot affect enforcement. **The drift check becomes
comment-insensitive**, and it is stronger than the byte check because it ignores
prose on both sides:

```sh
# strips every _comment/_blocked_* key, then compares
# → "IDENTICAL": every syscall, action, arg and archMap entry matches W HEAD
```

Verified today with that comparison: **identical**.

**DECIDED 2026-08-31 (owner): byte-identity is not required here.** The
comment-insensitive check above is the drift check for `seccomp.json` going
forward. Keep the aarch64 note. Do not re-open this to chase a literal `diff`,
and do not let a future "restore byte-identity" cleanup delete the substrate
finding — the enforcement surface is what is being compared, not the prose.

---

Two files, no substrate risk, both closing defects we carry today. Not in the
original plan because both landed in W after it was written.

0a. **`seccomp.json`** — add `creat` to the basic-I/O group (W `ce860b3`,
    W work/0017). Applies at container START — next `up`, not on write.

    **CORRECTED 2026-08-31, measured on this host — the premise does not hold
    here.** This plan and W's handoff both assert `tar -cf <file>` "fails EPERM
    in **every profile** right now" and that we "have this bug today and have
    not reported it." **We do not have the bug.** Measured in
    `claude-agent-therapod` before any change: both `tar -cf /tmp/x.tar tartest`
    and the `tar -cf /tmp/y.tar .` form exit 0 and write a valid archive.

    Cause: **`__NR_creat` is not defined on aarch64.** The ARM64 Linux ABI drops
    the legacy syscalls, so glibc implements `creat()` via
    `openat(AT_FDCWD, …, O_CREAT|O_WRONLY|O_TRUNC)` — already allowed. GNU tar
    1.35 on this substrate can never issue `creat`. Verified by preprocessor
    (`#ifdef __NR_creat` → absent) inside the container. W is x86_64 WSL2, where
    `creat` is a real syscall; that is why the bug is theirs and not ours.

    **Still applied, for two reasons that are not the bug fix:** the profile's
    `archMap` covers `SCMP_ARCH_X86_64` as well as `SCMP_ARCH_AARCH64`, so an
    x86 host would hit it for real; and byte-identity with W's `seccomp.json` is
    what makes every future `diff seccomp.json` a meaningful drift check.
    Security cost is nil — `creat` is strictly weaker than the already-allowed
    `openat`, reaching nothing new. The entry is **inert on this substrate** and
    the file's `_comment` says so.

    **This is the §1 substrate filter working.** Do not record 0a as a defect
    closed; record it as parity plus x86 portability. It also goes back to W
    (§4) — their handoff's claim about our bug is wrong.
    **Source is above the anchor** — carve-out, see §0.2. Two hunks, clean
    cherry-pick: the `_comment` rewrite and `"creat",` prepended to the
    basic-I/O `names` array. M and W@anchor are otherwise byte-identical
    (§0.1a), so after this the files match W HEAD exactly.
0b. **`Dockerfile`** — `apt-get install -y --only-upgrade openssl libssl3t64`
    in the existing install layer, for CVE-2026-45447. Our digest-pinned
    `ubuntu:24.04` ships the vulnerable `ubuntu3.4` and re-pulling the digest
    cannot clear it (W `e6bca33`, **at-or-below the anchor** — a normal port,
    not a carve-out). 7 lines, landing immediately before the
    `apt-get purge -y openssh-client` step. **Two adaptations:** W's comment
    says "the FROM digest pin" meaning its CUDA base — reword for
    `ubuntu:24.04`; and W's closing line ("drop the matching
    `.trivyignore.yaml` entry") does not apply — M has **no** CVE-2026-45447
    entry, so this closes the finding outright rather than clearing an
    acceptance. Drop that sentence rather than porting a dangling instruction.

Verify: `tar -cf /tmp/x.tar .` succeeds in a recreated container (**note: it
already succeeded before the change — see 0a; this confirms no regression, it
does not demonstrate a fix**); trivy no longer reports CVE-2026-45447.

**Trivy noise, pre-existing:** M's `.trivyignore.yaml` carries five entries with
`expired_at: 2026-07-21` — six weeks stale as of today. Not this item's scope,
but a trivy run for 0b will surface them. Triage or re-date them separately;
don't let them muddy 0b's before/after.

### Phase A0 — the test suites (NEW, from handoff §4 — highest leverage)

The handoff's strongest claim, and it is right: **10 suites there, 1 here.** They
are pure-offline — no docker, no network, no `agy`, no `claude` — so they land
**without Colima being up**, ahead of all image work. They also encode findings
we cannot rediscover locally; each exists because something in W shipped
inverted or drifted silently.

| Suite | Assertions | Lands with |
|---|---|---|
| `with-egress.test.sh` | 82 | A4 |
| `depaudit.test.sh` | 56 | A6 (+ `ccf27a3`) |
| `dockerfile-order.test.sh` | 8 | A5 |
| `deny-destructive.test.sh` | 207 | D (A7 folded in) |
| `webfetch.test.sh` | 90 | C2 — **fix 3 `mapfile` sites** |
| `vendor-tools.test.sh` | 65 | C1 |
| `agent-policy.test.sh` | 53 | D |
| `profile-skills.test.sh` | 24 | C3 |
| `agent-notice.test.sh` | 13 | C1 |
| `private-names-check.sh` | — | B — **fix 2 `mapfile` sites**; `[SKIP]`s until `.private-names.local` exists |

**The caveat that must not be lost:** a suite whose subject is not ported yet
will fail. **Port each suite _with_ its subject, not ahead of it.** So A0 is not
a phase that ships alone — it is the instruction that every A–D item below
carries its suite in the same change. The "Lands with" column is the binding.

### Phase A — stable, independent, platform-neutral (first PR)

A1. **Subnet allocator.** Consume W's `docs/handoff-to-macolima-subnet-allocator.md`
    §4 verbatim — **verified 2026-08-31 as byte-identical to W's live allocator**
    (57 code lines, comments ignored), so it is current despite being written
    2026-06-09. At `eda42dd` that code is **`profile.sh:~1030-1083`** — three
    functions, `first_free_octet` / `ensure_subnet_octet` / `ensure_octet_free`
    (an earlier revision of this line said `1008-1083`, which was measured
    against W HEAD; cite the function names, not line numbers, since they drift
    every time W edits `profile.sh`). `SANDBOX_OCTET` drives `172.30.${SANDBOX_OCTET}.0/24`, the three
    `ipv4_address` pins and the three `extra_hosts`. Check §5's two bugs
    (`set -e` + command-substitution; missing `mkdir -p`). Update CLAUDE.md
    invariant "change all four locations together" and `docs/compose-network-ipam.md`.
    Full `down` + rebuild per running profile.
A2. **Proxy directory mount.** Mount `./proxy` as a directory, squid reads
    `/etc/squid/host/allowed_domains.txt`. Fixes single-file inode staleness on
    edit. Update `docs/squid-internals.md`, dashboard writer, `verify-sandbox.sh`.
A3. **`.dockerignore`** (M builds an unpruned context). Port W's 17 lines minus
    `host_setup/`/`win_setup/`; add `profiles`, `temp_audit_package`, `dashboard/.venv`.
A4. **`with-egress.sh` instrumentation + `with-egress.test.sh`.** OSV pre-flight
    (host-side, `api.osv.dev` stays off the allowlist), `flock` serialisation,
    lockfile-hash + module-tree snapshots, Squid access.log window analysis,
    `depgate.jsonl` under `profiles/<p>/audit/`. Fix `open_section()` prose bug
    (`fcaf831`). Skip W's "phase 3" egress-topology parts per D5.
A5. **Gate 2 / Gate 3 in Dockerfile** (npm `min-release-age` quarantine; pip
    wheels-only) + `dockerfile-order.test.sh`. Adapt paths to `/home/agent`
    (`~/.config/pnpm/rc`). Document in `docs/local-wheels.md`.
    **Layer order is load-bearing** and `dockerfile-order.test.sh` locks it:
    **beads < claude/agy < npmrc (Gate 2) < uv/pip (Gate 3)**. `min-release-age`
    applies at *build* time, so putting the npmrc above the CLI install makes
    `@anthropic-ai/claude-code@latest` unresolvable whenever upstream published
    inside the quarantine window — an **intermittent** break that surfaces on a
    routine refresh, not on a cold build. Get the order right the first time;
    this is not a failure you will reproduce on demand.
A6. **`depaudit.py` + fixtures + tests**, `profile.sh <p> deps`. Stdlib-only,
    host-side, no sandbox change.
A7. **FOLDED INTO PHASE D — DECIDED 2026-08-31 (owner). Nothing ships under
    A7; it is not a phase-A item any more.** The handoff (§5.1, §3
    `e9deb82`/ADR-0008) records that W's third hook tier landed *with* the
    dialect branching already in it, so splitting the tier from the dialect
    means writing an engine we then rewrite in Phase D. The two-dialect engine
    is ported **once**, in D. The rule list below is not cancelled — it moves
    to D and ships in the same change as the engine:

    Hook rules into `config/hooks/deny-destructive.sh`:
    `rm-recursive`, `git-hook-tamper`, `cred-read`, `manifest-dep-add`,
    `docs-install-cmd`, `quarantine-weaken/touch/tamper`; log schema
    `{ts,rule,envelope}`. Extend `deny-destructive.test.sh` and the
    `verify-sandbox.sh` probe. `claude-settings.json`: add `ask` tier, `env`
    autoupdater kill, fetch-and-run installer denies, `Read` denies for
    credential stores (paths under `/home/agent`).

    **The cost this accepts, stated so it is not rediscovered later.** Phase A
    no longer improves the hook at all, and D is the phase least able to close
    (§3.5 item 6: the `agy` sign-in is punted, so D can be *ported* but not
    fully *verified*). The Claude-side rules above are therefore deferred behind
    an unverifiable phase — that was the trade, taken knowingly against writing
    a throwaway engine. **If they become urgent before D is schedulable, the
    reopening move is to ship the rule list against the existing
    single-dialect hook as an explicit stopgap — not to un-fold A7.**
A8. **Ops verbs.** `profile.sh <p> verify | audit [--stage-only]` (stage + run +
    save JSON), `trivy-scan.sh` `emit()` JSON persistence, `docker-gc.sh`,
    `code-attach.sh`. Matching `justfile` recipes (thin pass-throughs; `just --list`).
A9. **DO NOT EXECUTE — superseded 2026-08-31.** This item asked to send five
    checks back to W. **Four of the five are wrong.** `external_dns_blocked`,
    `connect_80_blocked` (W dropped our `H1_` audit prefix, which is what made it
    read as absent), the `bwrap`/`socat`/`ssh` triad and the `--show-origin`
    credential.helper sweep are all already in W; non-root UID is inapplicable to
    W's substrate. The list was built from file sizes — our `fs.py` is 284 lines
    to W's 258 — and a larger file was read as a richer check set. It is not.

    The corrected result lives in **[`W work/0021`](https://github.com/nranthony/windows-ai-sandbox/blob/main/work/0021-pull-back-controls-from-macolima/spec.md)**,
    which is the W work item this line asked for. It keeps four rows: PORT our
    tier-1 SUID/SGID tripwire (W has it only at tier 2), ASSESS hook
    immutability (our check measures a kernel guarantee W's container-root does
    not have), REJECT the stray-UID-0 probe for W, KEEP the wildcard
    INFO/DRIFT divergence and document it. Its §2 holds the check-level
    extraction that should replace every future eyeball comparison — **use it
    instead of comparing file sizes.**

    That item is **parked until this plan's handoff comes back**, because
    several of its rows may resolve once we carry the same three-tier engine.

### Phase B — repo process (no runtime risk, can ship with A)

B1. Split CLAUDE.md → `AGENTS.md` (conventions, golden rules, security-sensitive
    change protocol, boundary monitors) + `ARCHITECTURE.md` (state map, network,
    persistence table); `CLAUDE.md` becomes the `@AGENTS.md` stub via
    `sync-agent-files.sh`. Matches the global "AGENTS.md is canonical" rule.
B2. Adopt `docs/adr/`, `docs/rfcs/`, `docs/incoming/` with exit rules; import
    ADR-0001/0003/0004/0005 with M framing (M is origin). Archive
    `MACOLIMA_in-transit_*.md`, `claude_internal_audit.md`,
    `macolima_audit_threapod.md`, `macolima_therapod_audit_sh.json` to
    `docs/_archive/`; fold `TODO.md` (DB least-privilege) into a work item.
B3. Port `docs/sibling-repo-relationship.md` with framing flipped (queued in the
    old in-transit §4 — never done). Replace `docs/vscode-leakage.md` with W's
    `vscode-integration-security.md` (platform-independent, 4× depth).
B4. `.agents/skills/` host-side skills (`profile-lifecycle`, `security-audit`,
    `squid-management`) with M paths/commands.

### Phase C — templates, vendoring, skills (depends on W's channel being stable)

C1. `config/` → `sandbox_templates/{claude,common,skills,bin}` layout;
    `vendor-tools.sh` + `VENDORED.lock`; `init-profile-state.sh` with M paths;
    `sync-agent-notice.sh` + `common/agent-notice.md`.
    **Simpler than this plan assumed** (handoff §5.2): **one** `vendor-tools.sh`
    against the depot channel, not two per-payload scripts. Channel pointer
    resolves from `$DEPOT_DIR` or a gitignored `.depot-dir.local`.
    **The two halves of "absent" must not collapse:** nothing configured → loud
    `[SKIP]`, exit 0; configured but missing → **FAIL, exit 1**. Collapsing them
    is what turned W's `test-offline` green over a real three-release drift on
    2026-08-14. `sync-agent-notice.sh` itself is bash-3.2-clean (verified).
    **`common/agent-notice.md` is NOT clean and needs a substrate pass** —
    see C2a.
C2. Skills: refresh `audit-sandbox` (18 lines behind), add `web-read` +
    `bin/webfetch`. **Port the settled broker design, not this plan's sketch**
    (handoff §3, `efbf5bd`/`c32e88e`, ADR-0011/0012): backends are peers with
    **no default**, **read-hosts-only**, keys in **headers, never URLs**. Add
    the chosen reader-API host to the allowlist; keys via `secrets.env` chmod
    600. Carries `webfetch.test.sh` (90) — fix its 3 `mapfile` sites first.
    `myconv`/`myclickup`: per-profile decision.
C2a. **`common/agent-notice.md` — delete the GPU block, do not adapt it.**
    Ported unchanged it is actively wrong here: the title names
    `windows-ai-sandbox`, 8 `/root` occurrences across 5 lines, and roughly
    **lines 134–154 of 188** are a WSL2/CUDA section (`/dev/dxg`, `/usr/lib/wsl`,
    `CUDA_VERSION=12.6.3`, `LD_LIBRARY_PATH`) describing hardware we do not have.
    **`agent-notice.test.sh` passes 13/13 on it in W and will pass here too** —
    its locks are about repo-relative paths and host-side mechanisms, not
    substrate applicability. A green suite is not evidence this file is correct.
C3. Make skill seeding converge, not create-only (`profile.sh:151-158`) —
    ADR-0005 applies verbatim. Port `profile-skills.test.sh`.

### Phase D — multi-agent policy + the hook rules (**UNBLOCKED 2026-08-24**)

**Carries A7 — folded in 2026-08-31.** D is now the only phase that touches the
hook: A7's rule list, its `claude-settings.json` changes and its
`verify-sandbox.sh` probe extension all ship here, with the engine.

W's 0011 merged on 2026-08-24 (`a9c9b6c`, ADR-0007), so the hold is lifted.
Port 0010 + 0011 **as one unit**; porting 0010 alone
reproduces the create-only inconsistency 0011 fixes. Contents when ready:
two-dialect `deny-destructive.sh` engine (`--dialect`, jq adapter, fail-closed
for agy, second name `/usr/local/lib/sandbox-hooks/guardrails.sh` — add to
`hook-tamper` and verify), `sandbox_templates/antigravity/`, `probes/antigravity.py`
(`workspace_hook_shadow` DRIFT applies to M unchanged), `antigravity-parity.test.sh`,
ADR-0006, `converge_agent_policy` + `just converge <p>`, removal of
`reset-settings`-style verbs. All `/root/.gemini` → `/home/agent/.gemini`.
Verify in a *built* image (W's own recorded caveat). opencode (0009) stays out
until W unparks it. Plus everything listed under A7.

**Four asymmetries that look like inconsistencies and are not** (handoff §5.3).
Each one is a hole if "tidied" into symmetry — read this before touching the
engine:

1. **The two failure postures are deliberately OPPOSITE.** Claude fails **open**
   (its static `permissions.deny` sits underneath the hook); antigravity fails
   **closed** (for reads, the hook *is* the control). Claude's pass-through `{}`
   is a **deny** to `agy`, so the antigravity pass must stay an explicit
   `{"decision":"allow"}`.
2. **The ask tier is dialect-branched.** Claude emits
   `permissionDecision:"ask"`; `agy` emits `decision:"force_ask"` — because
   `agy` caches a plain `ask` approval as a permanent Always-Allow grant, so
   `ask` there would mean "prompt once, then delete freely forever".
3. **An unknown `--dialect=` must be fatal** (stderr + exit 2, no stdout). It
   used to coerce to claude — which emits claude-shaped output to a third agent
   and leaves the guardrail installed and **inert**.
4. **The two convergence write modes must stay OPPOSITE.** Claude overwrites
   (its preferences have repo-local files to live in); `agy` merges (it has
   none, and what it stores there is functional state). Unifying them either
   destroys live `agy` state or lets a stale Claude key survive enforcement.

`deny-destructive.test.sh` (207 assertions) locks all four — which is the real
argument for porting it *with* the engine rather than after.

### Phase E — allowlist reconciliation (per profile, never blanket)

W-only blocks worth considering: `[openrouter]`, `[openai]`, `[firecrawl]`,
`[google-fonts]`, `[citation-tools]`. **`[numerai]` is struck** — W closed it by
operator override in `f9b1a39` (2026-08-31, above the anchor; §0.2 carve-out).
Don't re-open upstream of that decision without asking why it was closed.
Add `[web-read]` — but it **travels with the broker (C2), not alone**.
Keep M-only: VS Code
marketplace/unpkg/update (attach flow), `[archive]`, `[github-raw]`,
`[oa-publishers]`, `[paperbridge]`, `[wearables]`. Adopt W's tiered header
(PROJECT-PERSISTENT vs PLANNING-MODE, registries commented by default, `[tag]`
convention) — needed by A4's section parser anyway.

**Parser trap:** the block-open regex is `\[[a-z-]+\]`. A digit or a dot in a
tag makes the block **unopenable** by `with-egress.sh` — it sits in the file
looking correct and never opens. M's current 14 tags are all `[a-z-]`-safe
(verified §1.1); keep it that way when adding blocks.

Also adopt W's **`proxy/gated_blocks_default_off`** probe with its
`ACCEPTED_OPEN_TAGS` set. The handoff files this as a gap in *our* direction:
M's `planning_mode_commented` cannot distinguish a deliberately-open block from
a leak.

## 3. Definition of done (per phase)

- `PROFILE=_test docker compose config` clean; `just --list` parses.
- `scripts/setup.sh <p> --verify` green on at least one live profile on the Mac.
- `config/hooks/deny-destructive.test.sh` and every ported `*.test.sh` green offline.
- Tier-2 audit run and JSON saved; no new DRIFT vs the pre-port baseline.
- CLAUDE.md/AGENTS.md editing checklist walked for each touched invariant.
- Nothing copied from W without passing the §1 substrate table.

**Ordering, easy to get wrong:** capture the tier-2 audit baseline **before
Phase 0**, not after. Phase 0 changes container behaviour, so a baseline taken
afterwards cannot show what Phase 0 moved.

**Phase 0 and Phase D both need a full image rebuild + container recreate** —
seccomp applies at container start and the hook engine is baked into the image,
so a policy-only `converge` carries neither.

## 3.5 Next — the ordered queue

Phase 0 is done (`a623808`). This section is the running "what now", so it is
the thing to update as items land. Everything below is at-or-below the anchor
unless flagged.

**A note on `mapfile`.** §1.1 records the five bash-4 sites as a hard blocker,
and they are — but **they are not a standalone first step, and cannot be.**
Neither `scripts/webfetch.test.sh` nor `scripts/private-names-check.sh` exists
in this repo yet; they arrive with C2 and B respectively. The rewrite is an
adaptation applied *at the moment each file ports*, per the Phase A0 binding.
Do not queue it as its own task — there is nothing here to edit.

**No-VM, can start immediately:**

1. **A3 — `.dockerignore`.** Absent here entirely; we build an unpruned context.
   ~17 lines from W minus `host_setup/`/`win_setup/`, plus `profiles`,
   `temp_audit_package`, `dashboard/.venv`. Smallest real item in the plan.
2. **B1–B3 — repo process.** `AGENTS.md`/`ARCHITECTURE.md` split, `docs/adr/`
   + `docs/incoming/`, archive the two `MACOLIMA_in-transit_*.md` files and the
   stale audit artifacts, port `sibling-repo-relationship.md` with the framing
   flipped, replace `vscode-leakage.md` with W's `vscode-integration-security.md`.
   No runtime risk. B also carries `private-names-check.sh` (+ its 2 `mapfile`
   sites) — our CLAUDE.md and README have the same client-name exposure W wrote
   that check for.

**Needs the VM, highest value:**

3. **A1 — subnet allocator.** The safest real port: W's handoff §4 is verified
   byte-identical to their live allocator. Changes a CLAUDE.md invariant
   ("change all four locations together") and `docs/compose-network-ipam.md`.
   Needs a full `down` + rebuild per profile, not `--force-recreate`.
4. **A2, A4+A6, A5** in that order. A4 carries `with-egress.test.sh` (82); A6
   carries `depaudit.test.sh` (56) **and `ccf27a3` folded in**; A5 carries
   `dockerfile-order.test.sh` (8) and the load-bearing layer order.

**Decided — no longer an open fork:**

5. **A7 — RESOLVED 2026-08-31 (owner): folded into Phase D.** Port the
   two-dialect engine once; **nothing hook-related ships in Phase A.** See A7
   for the cost this accepts and the stopgap if it has to be reopened.

**Sequence late:**

6. **Phase D — now carries A7 as well.** Portable, but not fully verifiable
   while the `agy` sign-in question is punted (§4, item 5). Do not schedule it
   as if it can close. Folding A7 in raised this phase's value without touching
   its blocker, which has a consequence worth naming: **the punted `agy`
   sign-in is now the gate on the Claude-side hook rules too.** If D stalls,
   that sign-in is the thing to un-punt first.

## 3.6 Loose ends — found during Phase 0, none blocking

Recorded here because Phase 0 surfaced them and prose asides get lost. None is
this work item's scope; each needs its own item.

| Finding | Detail | State |
|---|---|---|
| `settings/template_diff` DRIFT | the one non-OK probe in both the pre- and post-Phase-0 audit; live profile settings differ from the repo template on `hooks`, `permissions`, `agentPushNotifEnabled`, `skipAutoPermissionPrompt`, `skipWorkflowUsageWarning` | pre-existing, unexplained — **worth understanding before Phase C3 makes skill/template seeding converge** |
| 10 HIGH CVEs | `brace-expansion` (×2 trees), `ip-address`, npm `tar`, `golang.org/x/mod` — npm/go dependency CVEs, not OS packages | pre-existing, untouched by Phase 0 |
| `.trivyignore.yaml` staleness | five entries `expired_at: 2026-07-21`, ~6 weeks past | triage or re-date; they add noise to every future trivy comparison |
| `temp_audit_package/` | staged into `/Volumes/DataDrive/repo/therapod/` by `stage-audit-package.sh`; that workspace is not a git repo | left in place deliberately; it is the sanctioned output path and A3 adds it to `.dockerignore` |

## 4. What goes back to W

W's `work/0022` exits on our confirmation and `work/0021` is **parked** behind
it, so this is blocking work on their side, not a courtesy. Report:

1. **The handoff's §2 table is HEAD-measured, not anchor-measured** (§0.1a).
   Its §5.1 `profile.sh:1008-1083` and §6 "21 commits" inherit the same slip
   (now 27). Its `seccomp.json` "DIVERGED" row is an artifact — at `eda42dd` the
   files are byte-identical, and the `creat` fix is an above-anchor cherry-pick.
2. **Answer to their §8.3:** `/usr/bin/env bash` here is **3.2.57**. The five
   `mapfile` sites are a hard blocker, not a note.
2a. **Their §3 `ce860b3` row is wrong about us.** "You have this bug today and
   have not reported it" — we do not. `__NR_creat` is undefined on aarch64, so
   `tar -cf` has always worked here; measured pre-change on
   `claude-agent-therapod`. We carried the syscall anyway for x86 portability
   and seccomp byte-identity (§Phase 0a). Worth their knowing, because it means
   **any syscall-level finding they send us needs an arch check first** — the
   ARM64 ABI omits a whole class of legacy syscalls their x86_64 substrate has.
3. **Their §1.1 `/root` table counts lines, not occurrences** — undercounts
   `deny-destructive.sh` (14 → 24) and `agent-notice.md` (5 → 8).
4. **Answer to their §8.2 — verified 2026-08-31, works.** In a repo whose
   `package.json` declares `packageManager: pnpm@9.1.0` against an installed
   pnpm 10.34.5, `pnpm --version` returns **10.34.5, exit 0** — no corepack
   download attempt, so nothing to reach the proxy for. Mechanism:
   `manage-package-manager-versions=false` in `~/.config/pnpm/rc`, seeded by
   `ensure_state` (Dockerfile:96-99). The `5679866` opt-out does what it says.
5. **Their §8.1 (`agy` console sign-in) — PUNTED 2026-08-31 (owner decision).**
   It needs an interactive browser sign-in, so no agent session can answer it,
   and `agy` is not in regular use here. **Send it back to W as explicitly
   deferred, not as untested-by-oversight** — their §9 counts a silent omission
   as a cost. Re-open when `agy` is next actually needed; until then the
   `[antigravity]` allowlist block stays as-is and unverified since `5679866`
   (2026-07-19). Everything else in their §8 is answered.
   **Consequence for Phase D:** its verify step assumes a working `agy`
   sign-in. Phase D can be *ported* without it, but cannot be fully *verified*
   until this is resolved — plan D accordingly rather than discovering it there.
6. **Phase 0 is applied and green** — see the Phase 0 result table. Report the
   audit deltas (none), and **every omission with its reason** — their §9 says a
   silent omission costs them a second comparison run.
7. **A7 is folded into Phase D** (owner decision 2026-08-31), taking their §5.1
   advice. The consequence they need: the Claude-side hook rules will not appear
   in our Phase A at all, and D's verification is gated behind the punted `agy`
   sign-in (item 5). So **`work/0021`'s hook-immutability row will not resolve
   on our side as early as their §9 assumes** — it now waits on Phase D.
