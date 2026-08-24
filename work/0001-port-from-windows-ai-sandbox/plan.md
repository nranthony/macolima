# 0001 — Port stable windows-ai-sandbox work forward to macolima

**Status:** Planned 2026-08-23 from a read-only comparison run on Linux. **Not started.**
Execution requires the macOS/Colima host — every step below that touches the
image or compose needs `scripts/profile.sh build` + `<p> rebuild` and a `--verify`.

**Shelf life:** delete or archive on merge.

**Source:** `~/repo/sandbox/windows-ai-sandbox` (W), HEAD `21fdbde` on
`feat/0010-antigravity-guardrails` (7 commits ahead of `main` at `2ca3485`).
Re-diff before executing — W is in flux (0009 opencode, 0010 agy hooks, 0011
policy convergence).

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

### Phase A — stable, independent, platform-neutral (first PR)

A1. **Subnet allocator.** Consume `docs/handoff-to-macolima-subnet-allocator.md`
    §4 verbatim: `SANDBOX_OCTET` drives `172.30.${SANDBOX_OCTET}.0/24`, the three
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
A9. **Send M's verify checks back to W** (open a W work item, don't do it here):
    non-root UID, external-DNS exfil probe, live CONNECT-on-80 probe, SUID/SGID
    drift, stray UID-0 processes. Also compare `fs.py`/`seccomp_runtime.py`
    check-for-check (M's are larger).

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

### Phase D — multi-agent policy (HOLD until W 0011 lands)

Port 0010 + 0011 **as one unit** once merged in W; porting 0010 alone
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
