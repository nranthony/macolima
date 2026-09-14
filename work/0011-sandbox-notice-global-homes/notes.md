# 0011 — notes (execution log)

## 2026-09-14 — built, delivered, stripped: the done-check exits 0

Run as three parallel host-side agents for the code (notice + sync script,
scanner, profile.sh + verify), one for the strip, with the docs and ADR
written alongside. Everything below is verified host-side.

**A1/B1–B2.** The neutral notice landed (133 lines; 13/13 on both repos'
notice tests; private-names clean). `sync-agent-notice.sh` detects a block
by the marker **prefix** rather than an enumerated legacy list — the scanner
found two hand-maintained blocks (depot/myclickup, depot/paperbridge) whose
BEGIN comment wraps across four lines, which a list of exact markers would
have missed. `--strip` added. The update and strip paths now write into the
target (`cat tmp > target`) rather than `mv`, after the strip agent found
every stripped `AGENTS.md` had flipped to mode 600 and chmod'd them back; a
mode test locks it. 72/72.

**B4–B5.** Both targets at both call sites; `verify` passes the template's
sha256 as `NOTICE_SHA` on the docker exec — the first host→container value
the streamed check has ever had. The in-container check hashes the region
between the markers; the awk extraction was proven byte-equal to the
template before the check was written. Five branches exercised against a
fake `$HOME`.

**B6.** `NOTICE-IN-REPO` in `workspace-scan.py`, its own enumeration
(root `AGENTS/CLAUDE/GEMINI.md`, untracked included; tracked nested through
`nested_excluded()`); a `Notice` column in the report. 49/49. **The live
scan found ten blocks, not eight**: the two depot members carry the wrapped
hand-maintained variant.

**B7.** ADR-0015; ADR index (0014 stays reserved for work/0010; next free is
0016); the antigravity README's "gated but not briefed" section replaced by
"Briefed from `~/.gemini/config/rules/`"; `extending-a-profile.md` rows;
AGENTS.md invariant and pointer row. Depot handoff delivered to
`depot/inbox/` (gitignored there). Sibling replay drafted.

**C2 (before C1, no dependency).** `converge` on all four profiles; `verify`
green on the three running ones (nranthony 35/0, jeremy_dahl 37/0, therapod
36/0, each with both `sandbox-notice current` lines). fluidmomenta has no
container up; its two host files exist with the neutral marker, so its
verify is green the next time it is up. nranthony's `claude-home/CLAUDE.md`
was migrated in place from the macolima marker: exactly one block after.

**C1.** Ten repos stripped and committed, `git add AGENTS.md` only, nothing
pushed. Six regions were pure boilerplate (two byte-identical to the
sibling's current template, four older). Four carried repo text, relocated
below the markers before the strip:
- ikigai `562c480`: a `## Database (sandbox)` section (DSN never localhost,
  `POSTGRES_*` → `resolve_database_url`, `DATABASE_URL`/`.env` precedence,
  the `psql` recipe). Dropped the dated registry and `uv sync` measurements
  and a duplicate alembic-head line.
- app_blast `bf4730f`: one paragraph into its operating rules — a failing
  backend means switch, trust no written claim of which backend is up, run
  `webfetch backends`. Dropped the July-binary facts.
- depot/myclickup `55c7999`: a golden-rules bullet on version bumps
  (`pyproject.toml`, `__version__`, the editable entry in `uv.lock`).
- depot/paperbridge `ccb1b65`: a golden-rules bullet on dependency edits vs
  `uv.lock`; dropped a `/root/.cache/uv` sentence.
- The rest: project_zenbu `4453fe9`, numerai `99a2fee`, pipeline `8c99790`,
  engine `b186244`, agentic_admin_research_ga `1d233b6`,
  jeremy_dahl_analytics `3340b74`. The two `.vscode/settings.json` dirt files
  were left alone (owner: Peacock rewrites them).

**Done-check:** `workspace-scan.py --fail-on NOTICE-IN-REPO,HARDCODED-VENV-LINUX,OS-VENV-SELECT`
→ **exit 0**. That closes 0008's last line as well.

**Left over from the strip:** three lines of repo prose pointed at "the
notice above" (app_blast `AGENTS.md:163`, pipeline `:12`, ikigai `:119`);
reworded host-side to name `~/.claude/CLAUDE.md`, committed per repo.

**Still open:** A2 — agy loading `~/.gemini/config/rules/sandbox-notice.md`
is documented in its binary, not yet observed; needs
`scripts/profile.sh <p> auth-antigravity` once, then a one-minute test.
`[pypi]` egress stays open by the owner's decision. The depot handoff and
the sibling replay await their reports.
