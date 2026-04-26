---
name: audit-sandbox
description: Run a read-only isolation audit of THIS macolima sandbox container — cross-references documented invariants (cap_drop, seccomp, internal network, proxy allowlist, per-profile state, VS Code Dev Containers leakage controls) against live container state and writes report + replayable command log under ~/.claude/audits/. Use when the user asks to "audit the sandbox", "verify hardening", "check sandbox isolation", "self-audit", or after a known sandbox config change. Requires the host-side helper to have staged the audit package — if /workspace/temp_audit_package/ is missing, tell the user to run `scripts/stage-audit-package.sh <profile>` from the host first.
---

# audit-sandbox — in-container isolation audit

This skill runs the macolima self-audit. It does **not** duplicate the audit
spec — that lives at `/workspace/temp_audit_package/claude_internal_audit.md`
once the host-side helper has staged it. This skill body is the entry point,
the staged file is the canonical instructions.

## Steps

1. **Prerequisite check.** Confirm `/workspace/temp_audit_package/` exists and
   contains `claude_internal_audit.md`. If it doesn't, stop and tell the user:
   "The audit package isn't staged. From the host, run `scripts/stage-audit-package.sh <profile>` and then re-invoke this skill." Do **not** improvise the
   audit from memory — the staged package is the authoritative config snapshot
   for this profile.

2. **Resolve the profile name.** Use `$MACOLIMA_PROFILE` (set by compose) or,
   as fallback, parse it out of `/etc/hostname` (the agent container is
   `claude-agent-<PROFILE>`). You'll need the profile name to fill the
   `<PROFILE>` placeholders in the audit prompt and to name the output files.

3. **Read the audit prompt in full.**
   `Read /workspace/temp_audit_package/claude_internal_audit.md`. It defines
   the audit scope (§1–§13), the expected invariants for each area, the
   verify-sandbox.sh tripwire baseline, the ground rules (read-only, no
   destructive probes), and the output contract. Treat every numbered item
   as in scope unless the user narrows it.

4. **Run the tripwire as the first probe.**
   `bash /workspace/temp_audit_package/scripts/verify-sandbox.sh`. A clean
   run is 18/18 PASS. If anything fails, surface it before going deeper —
   most FAILs point at host-side regressions (VS Code settings reverting,
   profile predates a template change, etc.) and the user wants to see them
   immediately.

5. **Plan and confirm.** Per the audit prompt's "Before running anything"
   section, summarize your plan in one paragraph: which areas you'll deepen
   beyond the tripwire, what /tmp probes you intend, and anything you want
   the user to approve up front (especially state-changing tests — describe
   those, do not run them). Wait for go-ahead.

6. **Execute the audit and write the two artifacts.**
   The audit prompt's "Output artifacts" section prescribes the paths and
   format. Recap:

   ```
   mkdir -p /home/agent/.claude/audits
   STAMP="$(date -u +%Y-%m-%d)"
   PROFILE="<resolved profile name>"
   REPORT="/home/agent/.claude/audits/${STAMP}-${PROFILE}-report.md"
   CMDLOG="/home/agent/.claude/audits/${STAMP}-${PROFILE}-commands.sh"
   ```

   - **Report**: one section per audit area, invariants tagged
     **OK / DRIFT / WEAK / UNKNOWN**, compact tables where useful, a
     "Recommended hardening" section with concrete diffs (file + line) at
     the end. Quote only enough output to support each finding.
   - **Command log**: every probe in order, one command per line, no output.
     Headers `# --- <area> ---` between groups. Top of file:
     `#!/usr/bin/env bash` and `set -euo pipefail`. Must be safe to
     `chmod +x` and replay — exclude any state-changing or destructive
     command even if you described it in the report.

7. **Print both paths on completion** so the user can read them from the
   Mac without re-attaching:

   ```
   Report:   /home/agent/.claude/audits/<stamp>-<profile>-report.md
             host: /Volumes/DataDrive/.claude-colima/profiles/<profile>/claude-home/audits/<stamp>-<profile>-report.md
   Commands: /home/agent/.claude/audits/<stamp>-<profile>-commands.sh
             host: /Volumes/DataDrive/.claude-colima/profiles/<profile>/claude-home/audits/<stamp>-<profile>-commands.sh
   ```

## Hard rules

- **Read-only.** Do not install packages, change persistent state outside
  `/tmp` and the prescribed `~/.claude/audits/` artifacts, or attempt any
  container-escape probe. The audit prompt's ground rules are non-negotiable.
- **No outbound traffic to third parties.** Egress already goes through the
  Squid allowlist; stay within it. You MAY intentionally request a
  not-on-allowlist domain to confirm the proxy blocks it (a control test of
  the user's own infrastructure) — that's the only allowed deviation.
- **If a finding requires a state-changing test to confirm**, describe the
  test and the expected signal in the report instead of running it. Flag it
  for the user's review.
