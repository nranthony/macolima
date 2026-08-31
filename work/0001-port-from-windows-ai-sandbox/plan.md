# 0001 — Port stable windows-ai-sandbox work forward to macolima

**Status:** Planned 2026-08-23 from a read-only comparison run on Linux.
**Re-validated and re-anchored 2026-08-31** (§0.1). **Still not started.**
Execution requires the macOS/Colima host — every step below that touches the
image or compose needs `scripts/profile.sh build` + `<p> rebuild` and a `--verify`.

**Shelf life:** delete or archive on merge.

**Source:** `~/repo/sandbox/windows-ai-sandbox` (W).

**RE-ANCHORED 2026-08-31.** This plan originally pointed at `21fdbde`, a HEAD on
W's unmerged `feat/0010-antigravity-guardrails` branch. That pointer is now
meaningless. **The anchor is `W main@eda42dd`** (2026-08-26): everything at or
below it is a port candidate, everything above it is W's ComfyUI/fal branch and
is excluded wholesale (§0.2).

**The re-diff this plan asked for has been done** — see §0.1. Four of its own
measurements moved, `seccomp.json` has DIVERGED where it recorded byte-identity,
and Phase D's stated blocker cleared on 2026-08-24.

**Read [`docs/handoff-to-macolima-port-forward.md`](https://github.com/nranthony/windows-ai-sandbox/blob/main/docs/handoff-to-macolima-port-forward.md)
in W alongside this file** (locally: `~/repo/sandbox/windows-ai-sandbox/docs/handoff-to-macolima-port-forward.md`). It is the executable form of this plan: counted `/root`
substitutions, the five bash-4 sites, per-phase mechanics, and the questions
only this host can answer. This plan stays the strategy; that document is the
procedure.

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

## 0.1 Re-diff, measured 2026-08-31

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

## 0.2 Excluded wholesale

W's 21 commits above `main@eda42dd`: ComfyUI, `[pytorch]`, `[fal]`, `[nvidia]`,
`genmedia` + `ffmpeg` + `libgl1`, CPython 3.12/3.13 baked via uv. A GPU/ML stack
for a 48 GB WSL2 host with `/dev/dxg`. This is a 6 GB VM with no GPU. If we ever
want media tooling it is a fresh item against **this** substrate.

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

## 2. Phases

### Phase 0 — parity hotfix (NEW 2026-08-31, do this FIRST)

Two files, no substrate risk, both closing defects we carry today. Not in the
original plan because both landed in W after it was written.

0a. **`seccomp.json`** — add `creat` to the basic-I/O group. `tar -cf <file>`
    fails EPERM in **every profile** right now and reads as a capability
    problem it is not (W `ce860b3`, W work/0017). Also restores the
    byte-identity that makes every future `diff seccomp.json` meaningful.
    Applies at container START — next `up`, not on write.
0b. **`Dockerfile`** — `apt-get install -y --only-upgrade openssl libssl3t64`
    in the existing install layer, for CVE-2026-45447. Our digest-pinned
    `ubuntu:24.04` ships the vulnerable `ubuntu3.4` and re-pulling the digest
    cannot clear it (W `e6bca33`).

Verify: `tar -cf /tmp/x.tar .` succeeds in a recreated container; trivy no
longer reports CVE-2026-45447.

### Phase A — stable, independent, platform-neutral (first PR)

A1. **Subnet allocator.** Consume W's `docs/handoff-to-macolima-subnet-allocator.md`
    §4 verbatim — **verified 2026-08-31 as byte-identical to W's live
    `profile.sh:1008-1083`** (57 code lines, comments ignored), so it is current
    despite being written 2026-06-09: `SANDBOX_OCTET` drives `172.30.${SANDBOX_OCTET}.0/24`, the three
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
A6. **`depaudit.py` + fixtures + tests**, `profile.sh <p> deps`. Stdlib-only,
    host-side, no sandbox change.
A7. **Hook rules** into `config/hooks/deny-destructive.sh` (Claude dialect only
    for now): `rm-recursive`, `git-hook-tamper`, `cred-read`, `manifest-dep-add`,
    `docs-install-cmd`, `quarantine-weaken/touch/tamper`; log schema
    `{ts,rule,envelope}`. Extend `deny-destructive.test.sh` and the
    `verify-sandbox.sh` probe. `claude-settings.json`: add `ask` tier, `env`
    autoupdater kill, fetch-and-run installer denies, `Read` denies for
    credential stores (paths under `/home/agent`).
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
    `sync-agent-notice.sh` + `common/agent-notice.md` (already bash-3.2-safe).
C2. Skills: refresh `audit-sandbox` (18 lines behind), add `web-read` +
    `bin/webfetch` (add the chosen reader-API host to the allowlist, keys via
    `secrets.env` chmod 600). `myconv`/`myclickup`: per-profile decision.
C3. Make skill seeding converge, not create-only (`profile.sh:151-158`) —
    ADR-0005 applies verbatim. Port `profile-skills.test.sh`.

### Phase D — multi-agent policy (**UNBLOCKED 2026-08-24**)

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
until W unparks it.

### Phase E — allowlist reconciliation (per profile, never blanket)

W-only blocks worth considering: `[openrouter]`, `[openai]`, `[firecrawl]`,
`[google-fonts]`, `[citation-tools]`, `[numerai]`. Keep M-only: VS Code
marketplace/unpkg/update (attach flow), `[archive]`, `[github-raw]`,
`[oa-publishers]`, `[paperbridge]`, `[wearables]`. Adopt W's tiered header
(PROJECT-PERSISTENT vs PLANNING-MODE, registries commented by default, `[tag]`
convention) — needed by A4's section parser anyway.

## 3. Definition of done (per phase)

- `PROFILE=_test docker compose config` clean; `just --list` parses.
- `scripts/setup.sh <p> --verify` green on at least one live profile on the Mac.
- `config/hooks/deny-destructive.test.sh` and every ported `*.test.sh` green offline.
- Tier-2 audit run and JSON saved; no new DRIFT vs the pre-port baseline.
- CLAUDE.md/AGENTS.md editing checklist walked for each touched invariant.
- Nothing copied from W without passing the §1 substrate table.
