# IN TRANSIT — Mac verification handoff (glab removal + resource-limit ports)

**Status:** VERIFIED ON MAC 2026-07-02 — rebuilt, recreated, tripwire 24/0/0,
point checks pass (gitstatus=4, pids.max=2048, lsof present, glab absent),
trivy shows the 4 glab CVEs gone + Ubuntu 0. Code changes were authored
**off-Mac (WSL/Ubuntu)** where they could not be runtime-verified; that gap is
now closed.
**Date authored:** 2026-07-01. **Verified:** 2026-07-02 (on-Mac).
**Author context:** cross-check pass against sibling `windows-ai-sandbox`.

---

## 0. What changed this pass (and why you're needed)

Three "safe port" items from `windows-ai-sandbox` plus a scoped removal. All are
static edits — none were run against a live Colima VM, because this work happened
on a Windows/WSL host with no macOS/Colima. Everything below **built clean in
static checks** (`bash -n`, `py_compile`, `docker compose config`, JSON parse)
but has **not** been rebuilt into an image or exercised at runtime.

| # | Change | Files | Verify on Mac by |
|---|---|---|---|
| 1 | `GITSTATUS_NUM_THREADS=4` added | `config/.zshrc` | rebuild image → attach → `echo $GITSTATUS_NUM_THREADS` = 4 |
| 2 | `pids_limit: 512 → 2048` | `docker-compose.yml` | `recreate` → `cat /sys/fs/cgroup/pids.max` inside agent = 2048 |
| 4 | `lsof` added to apt block | `Dockerfile` | rebuild → `command -v lsof` inside agent |
| 3 | **glab / GitLab CLI removed entirely** (GitHub-only now) | see §2 | rebuild → `command -v glab` returns nothing; `trivy` shows no glab CVEs |

(Numbering matches the PORT list in the assessment: 1, 2, 4 applied; 3 = glab,
dropped rather than ported.)

**Not touched by this pass:** `.vscode/settings.json` was already modified in the
working tree before this work started — leave it / handle separately.

---

## 1. Apply + verify sequence (run in repo root on the Mac)

```bash
# Pre-req: Colima up. If the daemon socket errors, run scripts/colima-up.sh.
colima status || scripts/colima-up.sh

# 1+2. Rebuild the shared image AND recreate the profile in one step
#    (Dockerfile + .zshrc changed → rebuild required, NOT just recreate).
#    `rebuild` = `docker compose build claude-agent` + force-recreate.
#    NOTE: build/rebuild both require a profile arg — only `list` is
#    profile-less, so a bare `scripts/profile.sh build` just prints usage and
#    builds nothing. Add --no-cache if a cached layer masks the apt (lsof) /
#    glab change (the changed apt line + deleted glab block auto-invalidate the
#    cache from that layer on, so a plain rebuild is normally enough).
scripts/profile.sh <profile> rebuild   # build shared image + recreate <profile>

# 3. Tripwire — MUST pass unchanged. seccomp/probe invariants were confirmed
#    byte-identical to the sibling before this pass; this proves nothing
#    regressed (SUID set, credential-helper allowlist, egress).
#    verify-sandbox.sh runs INSIDE the container — stage it into the workspace
#    first, then exec it. Running it from the host scans the *host* (UID 501,
#    no /proc, host SSH_AUTH_SOCK) and every check false-fails.
scripts/stage-audit-package.sh <profile>
docker exec claude-agent-<profile> bash /workspace/temp_audit_package/scripts/verify-sandbox.sh
# (clean up after: docker exec claude-agent-<profile> rm -rf /workspace/temp_audit_package)

# 4. Point checks inside the agent. NOTE: GITSTATUS_NUM_THREADS is exported from
#    ~/.zshrc, so a bash shell never sees it — check it via zsh, not bash.
docker exec claude-agent-<profile> zsh -ic 'echo "gitstatus: $GITSTATUS_NUM_THREADS"'  # expect 4
docker exec claude-agent-<profile> bash -c '
  cat /sys/fs/cgroup/pids.max                    # expect 2048
  command -v lsof && echo lsof-present           # expect a path
  command -v glab && echo "GLAB STILL PRESENT — FAIL" || echo "glab absent OK"
'

# 5. Trivy — the 4 glab Go-stdlib CVEs were removed from .trivyignore.yaml.
#    With glab gone they must NOT reappear as findings. If they do, the binary
#    is somehow still in the image (stale layer) — rebuild --no-cache.
scripts/trivy-scan.sh image
```

## 2. Exactly what "glab removed" touched (for your review + rollback map)

Functional (code/config — all done):
- `Dockerfile` — deleted the whole glab install block; left a breadcrumb comment
  where it was, listing everything to restore if GitLab is ever needed again.
- `scripts/setup.sh` — dropped `--gitlab`/`--both` flags, `do_gitlab_auth`, the
  GitLab `verify_git_token` call, and `GIT_HOSTS` now = `github | none`.
- `scripts/profile.sh` — dropped the `auth-gitlab` subcommand and the
  `config/glab-cli/` stage/restore lines in `wipe`.
- `justfile` — dropped the `auth-gitlab` recipe.
- `config/claude-settings.json` — dropped `Bash(glab:*)` from `deny`.
- `scripts/audit/probes/settings.py` — dropped `Bash(glab:*)` from the expected
  deny set (keeps the probe in sync with the settings file — **if you skip this
  the audit probe fails**).
- `proxy/allowed_domains.txt` — dropped the two commented `gitlab.com` lines.
- `.trivyignore.yaml` — dropped the 4 glab Go-stdlib CVE entries.
- `docker-compose.yml` — comment only (gh/glab → gh).

Docs (current reference — done): `CLAUDE.md`, `README.md`,
`docs/sandbox-design-notes.md` (removed the glab build-integrity section),
`docs/vscode-leakage.md`, `docs/permissions-model.md`, `docs/debug-recipes.md`,
`scripts/verify-sandbox.sh` + `scripts/audit/probes/env.py` (comment-only; the
credential-helper matching logic is unchanged — it keys on host-reaching
patterns, never on the tool name).

**Left as historical / not swept** (grep `glab` to see): the point-in-time audit
snapshots `macolima_audit_threapod.md` + `macolima_therapod_audit_sh.json`
(rewriting a dated audit would falsify it), the planning docs
`docs/add-gemini-plan.md` / `docs/control-dashboard-plan.md` / `docs/index.md`,
and `images/macolima_architecture.svg` (the diagram still shows a `glab-cli/`
box and a `gitlab.com` egress label). If you want the SVG accurate, edit those
two text nodes — cosmetic, no functional impact.

## 3. The pids/gitstatus repro (optional but recommended)

Confirms items 1+2 actually fixed the failure mode they target (libzmq
`pthread_create` → EAGAIN under thread-pool + fork pressure). Inside an attached
agent with a venv that has `ipykernel`:

```bash
cat /sys/fs/cgroup/pids.max /sys/fs/cgroup/pids.current   # ceiling vs live
# Open 2-3 VS Code windows on the same container, then launch a Jupyter kernel.
# Pre-change: dies with "Resource temporarily unavailable (src/thread.cpp:...)".
# Post-change: gitstatusd now spawns 4 threads/shell (not ~12), pids ceiling is
# 2048 (not 512) — the kernel should start clean.
```

---

## 4. Still outstanding (NOT done this pass — separate decisions)

These came out of the same cross-check but were deliberately left for the
maintainer; flagged here so they don't get lost:

1. **`docs/sibling-repo-relationship.md` is missing from macolima.** It exists
   only in `windows-ai-sandbox` and is cited as the governing "do-not-blind-copy"
   authority by both repos' porting docs. Port it here, flipping the framing —
   macolima is the **origin**, windows-ai-sandbox is the port.
2. **Colima VM `--memory` / agent `mem_limit` sizing.** The in-transit resource
   note (§3 of `MACOLIMA_in-transit_resource-limits-recommendations.md`, numbers
   now corrected to the real 6GB VM) needs a physical-RAM decision on the actual
   Mac before `--memory` / `mem_limit` are touched. **Do not** copy the sibling's
   `20g` / `4096` — those were sized for a 48GB WSL host with no DB-in-VM
   pressure. Item 2 (pids→2048) is already applied; the RAM lever is the
   remaining, host-specific half.
3. **Deferred ports (need a "does a Mac profile need this?" call):** PDF tooling
   (pandoc + WeasyPrint + fonts), OCR (tesseract + poppler), and the Antigravity
   CLI (`agy`) swap for the Gemini CLI. All portable, none applied — each is a
   product/weight decision, not a safe mechanical port. On Mac the agent runs as
   UID 1000, so the sibling's `UV_TOOL_DIR=/opt` / `/root`-homed paths need
   adapting, not copying.

## 5. If something fails

- **Tripwire fails on SUID or credential-helper:** unlikely from this pass (no
  SUID change; helper logic untouched) — check it's not pre-existing drift.
- **Audit probe `settings` fails:** confirm `Bash(glab:*)` is gone from BOTH
  `config/claude-settings.json` deny AND `scripts/audit/probes/settings.py` — they
  must match.
- **glab CVEs reappear in trivy:** stale image layer still carries the binary →
  `scripts/profile.sh build --no-cache` then `rebuild`.
- **Rollback:** every change is in one commit's diff; `git revert` restores glab
  wholesale, and the Dockerfile breadcrumb lists the pieces to hand-restore if
  you want a partial rollback.
