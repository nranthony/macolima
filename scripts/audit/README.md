# scripts/audit/

Comprehensive sandbox audit. Runs ~80 deterministic probes inside the agent
container, emits one JSON document. Drives the agent-side report under the
`audit-sandbox` skill.

## Three tiers

| Tier | What | When | Cost |
|---|---|---|---|
| 1 | `scripts/verify-sandbox.sh` | every `up` | ~3s, exit code |
| 2 | `scripts/audit/audit.sh` (this dir) | on demand | ~10s, JSON |
| 3 | agent reads JSON + CLAUDE.md, writes report.md | on demand | ~5k tokens |

Tier 1 is the fast tripwire — minimum viable invariants, breaks on the
common drift patterns. Tier 2 is the comprehensive structured probe.
Tier 3 is the judgment layer — distinguishing real drift from tripwire
artifacts, recommending tight diffs.

## Layout

```
scripts/audit/
├── audit.sh           # entry point — exec's aggregate.py
├── aggregate.py       # imports each probe, emits one merged JSON
├── probes/
│   ├── identity.py        # §1 §2 — uid/gid/caps/seccomp_mode/sudo/SUID/AppArmor
│   ├── seccomp_static.py  # §3a   — white-box on seccomp.json
│   ├── seccomp_runtime.py # §3b   — runtime ctypes probes
│   ├── fs.py              # §4-§8 — files, mounts, /proc, /sys, /dev, cgroups, PIDs
│   ├── network.py         # §9a-c — egress, DNS, DB siblings
│   ├── proxy.py           # §9d §9g — allowed_domains.txt + squid.conf
│   ├── settings.py        # §12   — claude settings + per-project WebFetch
│   └── env.py             # §13   — env, VS Code Dev Containers leakage
└── README.md
```

## Output shape

Each probe's `run()` returns a list of finding dicts:

```python
{
  "section": str,        # identity / mac / seccomp_static / seccomp_runtime /
                         # fs / network / proxy / settings / env
  "name":    str,        # short stable identifier per finding
  "verdict": "OK" | "DRIFT" | "WEAK" | "UNKNOWN" | "N/A" | "INFO",
  "details": dict,       # observed/expected values, errors, etc.
}
```

`aggregate.py` merges into:

```jsonc
{
  "info": {
    "stamp": "2026-05-09T12:34:56Z",
    "profile": "therapod",
    "container": "claude-agent-therapod",
    "uname": "Linux ... aarch64"
  },
  "summary": {"OK": 72, "DRIFT": 1, "WEAK": 1, "UNKNOWN": 0, "N/A": 5, "INFO": 4},
  "results": [/* findings */],
  "probe_errors": [/* only if a probe module crashed */]
}
```

## Verdict semantics

| Verdict | Meaning | What the agent does |
|---|---|---|
| `OK` | invariant holds | summarize, don't enumerate |
| `DRIFT` | documented invariant doesn't hold | cross-reference CLAUDE.md, decide real vs. tripwire bug, propose minimum-diff fix |
| `WEAK` | known weak spot | reference upstream TODO; not new drift |
| `UNKNOWN` | probe couldn't disambiguate | follow up with one targeted /tmp probe |
| `N/A` | optional component absent (e.g. DB sibling not running) | note, don't elevate |
| `INFO` | descriptive, not a verdict (per-profile additions, env shape) | pass through if user-relevant |

## Running

From inside the agent container:

```sh
bash /workspace/temp_audit_package/scripts/audit/audit.sh > /tmp/audit.json
```

From the host (via `profile.sh exec`):

```sh
scripts/stage-audit-package.sh <profile>
scripts/profile.sh <profile> exec bash /workspace/temp_audit_package/scripts/audit/audit.sh
```

For ad-hoc debugging of a single probe, run the module directly:

```sh
python3 /workspace/temp_audit_package/scripts/audit/probes/network.py
```

(Each probe has an `if __name__ == "__main__"` block for this.)

## Adding a new probe

1. Drop a `<name>.py` in `probes/`. Stdlib only.
2. Export a `run() -> list[dict]` returning findings as above.
3. Register the module in `aggregate.py`'s `PROBES` list.
4. Add an `if __name__ == "__main__"` debug block:
   ```python
   if __name__ == "__main__":
       import json, sys
       json.dump(run(), sys.stdout, indent=2)
       print()
   ```

Probes must be:

- **Read-only.** Don't modify state outside `/tmp`.
- **Stdlib only.** No pip installs.
- **Fast.** Each <1s ideally; cap subprocess timeouts at 30s.
- **Idempotent.** Re-running gives the same result.
- **Self-contained.** Don't import other probe modules.
- **Safe on missing inputs.** If a config file isn't staged or a sibling
  isn't up, emit UNKNOWN or N/A — don't crash.

## What this is not

This is not a security audit substitute. It checks the *documented* invariants
hold; it doesn't try to discover new attack paths. The agent's report layer
adds judgment over the deterministic findings; the human (you) closes the
loop on what to do with that.

The real boundary is the proxy + seccomp + non-root + cap_drop. The denylist,
read-pattern blocks, and these probes are defense in depth.
