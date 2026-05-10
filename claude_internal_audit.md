# Sandbox isolation audit — in-container procedure

You are running inside `claude-agent-<PROFILE>`, the agent container of a
multi-profile Docker sandbox. This is a **self-audit** — the system is owned
by the user, nothing here targets a third party, no traffic leaves their
machine.

Your job is to **verify** that the sandbox's documented isolation invariants
hold at runtime, and write a report. This is verification, not discovery
from scratch — drift from documented behavior is the interesting finding.

The deterministic probes have been factored out into a structured audit
script. Your value here is **judgment over the JSON output**: distinguishing
real drift from tripwire artifacts, weighing cosmetic vs. functional, and
recommending tight diffs. Don't replicate the script's checks.

## Procedure

### 1. Confirm staging

`/workspace/temp_audit_package/` should exist and contain:

- `CLAUDE.md` — invariants and their rationales (load-bearing)
- `Dockerfile`, `docker-compose.yml`, `seccomp.json`
- `proxy/squid.conf`, `proxy/allowed_domains.txt`
- `config/claude-settings.json`
- `scripts/audit/audit.sh` and the structured probes under `scripts/audit/probes/`
- `scripts/verify-sandbox.sh`

If any of these are missing, stop and tell the user to run
`scripts/stage-audit-package.sh <profile>` from the host.

### 2. Run the structured audit

```sh
mkdir -p /home/agent/.claude/audits
bash /workspace/temp_audit_package/scripts/audit/audit.sh > /tmp/audit.json
```

`audit.sh` runs ~80 deterministic probes (identity, seccomp white-box +
runtime, filesystem, /proc /sys /dev, cgroups, PID namespace, network
egress, DNS, proxy review, settings, environment, VS Code Dev Containers
leakage) and emits one JSON document. Read it:

```sh
jq '.summary, .info' /tmp/audit.json
jq '.results[] | select(.verdict == "DRIFT" or .verdict == "UNKNOWN")' /tmp/audit.json
```

### 3. Run the tripwire as a sanity check

```sh
bash /workspace/temp_audit_package/scripts/verify-sandbox.sh
```

Should be 20 PASS / 0 FAIL on a clean sandbox. Any FAIL is a starting
point for the report — a tripwire FAIL with a corresponding audit.json OK
typically means the tripwire's probe is wrong (cite file:line and propose
the fix). A tripwire FAIL plus an audit.json DRIFT is real drift.

### 4. Read CLAUDE.md (focused)

`/workspace/temp_audit_package/CLAUDE.md` documents the rationale for every
invariant — what each defends against, why it's load-bearing, what historical
regression closed it. Skim if you've seen it; focus on the "Gotchas with
root causes" section for any DRIFT or UNKNOWN you found in audit.json.

### 5. Write the report

Iterate over `audit.json`'s `results`. The verdict semantics are:

| Verdict | What you do |
|---|---|
| `OK` | Don't enumerate. Summarize as "§N — N invariants OK." |
| `DRIFT` | Cross-reference CLAUDE.md. Decide: real regression / tripwire bug / cosmetic. Cite file:line. Propose minimum-diff fix. Tag with audit-letter (H*/M*/L*) when matching a prior round. |
| `WEAK` | Known weak spot. Reference the upstream TODO if there is one (e.g. DB superuser cred → TODO.md "agent_rw split"). Don't elevate. |
| `UNKNOWN` | The probe couldn't disambiguate. May warrant ONE small targeted Python snippet in `/tmp` to disambiguate; cite it. |
| `N/A` | Optional component absent (DB sibling not running, etc.). Note, don't elevate. |
| `INFO` | Descriptive (per-profile additions, env shape). Pass through to the report if user-relevant. |

Group findings by `section` (identity, mac, seccomp_static, seccomp_runtime,
fs, network, proxy, settings, env). For descriptive context that doesn't
appear as a section in the JSON (Colima/VM signals, kernel info), use
the top-level `info` block (`info.uname`, `info.profile`, `info.container`)
plus a sweep of `findmnt | grep lima` if useful.

End with a **"Recommended hardening"** section: concrete diffs (file +
line where possible), prioritized H/M/L, with one-line rationale each.

### 6. Output paths

```sh
STAMP="$(date -u +%Y-%m-%d)"
PROFILE="<resolved profile name from MACOLIMA_PROFILE / hostname>"
REPORT="/home/agent/.claude/audits/${STAMP}-${PROFILE}-report.md"
```

Save the raw audit JSON next to the report for reproducibility:

```sh
cp /tmp/audit.json "/home/agent/.claude/audits/${STAMP}-${PROFILE}-audit.json"
```

Print all paths plus host-side equivalents on completion:

```
Report:    /home/agent/.claude/audits/<stamp>-<profile>-report.md
           host: /Volumes/DataDrive/.claude-colima/profiles/<profile>/claude-home/audits/<stamp>-<profile>-report.md
JSON:      /home/agent/.claude/audits/<stamp>-<profile>-audit.json
           host: /Volumes/DataDrive/.claude-colima/profiles/<profile>/claude-home/audits/<stamp>-<profile>-audit.json
audit.sh:  /workspace/temp_audit_package/scripts/audit/audit.sh
```

## What you do NOT do

- **Don't re-run the deterministic probes individually.** `audit.sh` already
  ran them. If you need to disambiguate an UNKNOWN, run ONE targeted Python
  snippet in `/tmp` and cite it in the report.
- **Don't generate a `commands.sh` log.** `audit.sh` IS the command log;
  cite its absolute path in the report header.
- **Don't flag per-profile additions** to `allowed_domains.txt` as drift.
  Legitimate research / vendor API hosts are expected; the audit script
  tags them `INFO`, not DRIFT.
- **Don't flag domain-scoped `WebFetch(domain:...)` entries** in per-project
  files as drift. Bare `WebFetch` or `WebFetch(*)` IS drift — that's a
  separate check the script already runs.
- **Don't rerun verify-sandbox.sh probes individually.** The full tripwire
  is one bash invocation; treat its output as a unit.

## Ground rules

- **Read-only.** Do not modify files outside `/tmp` and the prescribed
  output dir under `~/.claude/audits/`. Do not install packages. Do not
  change persistent state.
- **No outbound traffic to third parties.** Egress already goes through
  the local Squid allowlist; stay within it. The structured audit's
  `network` probes intentionally test a not-on-allowlist domain
  (`evil.example.invalid:443`) to confirm the proxy blocks it — that's the
  only allowed deviation, and the script already does it.
- **If a finding requires a state-changing action to confirm**, describe
  the test and the expected signal in the report instead of running it.
- **Stop and ask** before anything you're unsure about.

## JSON shape (for orientation)

```jsonc
{
  "info": {
    "stamp":     "2026-05-09T12:34:56Z",
    "profile":   "therapod",
    "container": "claude-agent-therapod",
    "uname":     "Linux ... aarch64"
  },
  "summary": {"OK": 72, "DRIFT": 1, "WEAK": 1, "UNKNOWN": 0,
              "N/A": 5, "INFO": 4},
  "results": [
    {"section": "identity", "name": "uid",
     "verdict": "OK",
     "details": {"expected": 1000, "observed": 1000}},
    // ...
  ],
  "probe_errors": []   // present only if a probe module crashed
}
```

`section` ∈ {`identity`, `mac`, `seccomp_static`, `seccomp_runtime`,
`fs`, `network`, `proxy`, `settings`, `env`}.

The detailed contract (verdict semantics, how to add a probe) lives at
`/workspace/temp_audit_package/scripts/audit/README.md`.
