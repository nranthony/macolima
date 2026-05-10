---
name: audit-sandbox
description: Run a read-only isolation audit of THIS macolima sandbox container — runs the structured audit script (~80 deterministic probes), cross-references findings against documented invariants in CLAUDE.md, and writes a markdown report + raw JSON under ~/.claude/audits/. Use when the user asks to "audit the sandbox", "verify hardening", "check sandbox isolation", "self-audit", or after a known sandbox config change. Requires the host-side helper to have staged the audit package — if /workspace/temp_audit_package/ is missing or out of date, tell the user to run `scripts/stage-audit-package.sh <profile>` from the host first.
---

# audit-sandbox — in-container isolation audit

This skill runs the macolima self-audit. It does **not** duplicate the audit
spec — that lives at `/workspace/temp_audit_package/claude_internal_audit.md`
once the host-side helper has staged it. This skill body is the entry point;
the staged file is the canonical instructions.

The audit is structured around three tiers:

- **Tier 1** (`scripts/verify-sandbox.sh`) — fast tripwire, ~20 pass/fail
  checks. Runs as a sanity check.
- **Tier 2** (`scripts/audit/audit.sh`) — comprehensive structured probes,
  emits one JSON document covering identity / seccomp / fs / network /
  proxy / settings / env (~80 findings).
- **Tier 3** (you) — judgment over the JSON: real drift vs. tripwire bug,
  cosmetic vs. functional, recommended hardening diffs.

## Steps

1. **Prerequisite check.** Confirm `/workspace/temp_audit_package/` exists
   and contains `claude_internal_audit.md` plus
   `scripts/audit/audit.sh`. If either is missing, stop and tell the user:
   "The audit package isn't staged or is out of date. From the host, run
   `scripts/stage-audit-package.sh <profile>` and then re-invoke this skill."
   Do **not** improvise the audit from memory — the staged package is the
   authoritative config snapshot for this profile.

2. **Resolve the profile name.** Use `$MACOLIMA_PROFILE` (set by compose) or,
   as fallback, parse it out of `/etc/hostname` (the agent container is
   `claude-agent-<PROFILE>`). You'll need the profile name to populate
   `<PROFILE>` in the audit prompt and to name the output files.

3. **Read the audit prompt.**
   `Read /workspace/temp_audit_package/claude_internal_audit.md`. It defines
   the procedure (run audit.sh → run tripwire → read CLAUDE.md → write
   report), the verdict semantics, the ground rules, and the output
   contract. Follow it.

4. **Execute.** In summary:
   - `bash /workspace/temp_audit_package/scripts/audit/audit.sh > /tmp/audit.json`
   - `bash /workspace/temp_audit_package/scripts/verify-sandbox.sh`
     (sanity check, treat as a unit — full output, not per-line).
   - Read `/workspace/temp_audit_package/CLAUDE.md` focused on "Gotchas
     with root causes" for any DRIFT/UNKNOWN you saw in the JSON.
   - Write the markdown report to
     `/home/agent/.claude/audits/$(date -u +%Y-%m-%d)-<profile>-report.md`,
     organized by JSON `section`, with judgment over each non-OK finding,
     ending in a "Recommended hardening" section.
   - Save the raw JSON next to the report:
     `/home/agent/.claude/audits/$(date -u +%Y-%m-%d)-<profile>-audit.json`.

5. **Print paths on completion.** Both container paths plus host-side
   equivalents so the user can read them from the Mac without re-attaching:

   ```
   Report:    /home/agent/.claude/audits/<stamp>-<profile>-report.md
              host: /Volumes/DataDrive/.claude-colima/profiles/<profile>/claude-home/audits/<stamp>-<profile>-report.md
   JSON:      /home/agent/.claude/audits/<stamp>-<profile>-audit.json
              host: /Volumes/DataDrive/.claude-colima/profiles/<profile>/claude-home/audits/<stamp>-<profile>-audit.json
   audit.sh:  /workspace/temp_audit_package/scripts/audit/audit.sh
   ```

## Hard rules

- **Read-only.** Do not install packages, change persistent state outside
  `/tmp` and the prescribed output dir, or attempt any container-escape
  probe. The audit prompt's ground rules are non-negotiable.
- **No outbound traffic to third parties.** Egress already goes through
  the Squid allowlist. The structured audit's `network` probes
  intentionally test a not-on-allowlist domain to confirm the proxy
  blocks it — that's the only allowed deviation and the script already
  does it.
- **Don't replicate the script's checks.** Your value here is judgment
  over the JSON output, not re-running probes. If an UNKNOWN needs
  disambiguation, ONE targeted Python snippet in `/tmp` is fine — don't
  recreate the audit ad-hoc.
- **If a finding requires a state-changing test to confirm**, describe
  the test and the expected signal in the report instead of running it.
  Flag it for the user's review.
