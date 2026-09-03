# `sandbox_templates/antigravity/`

The Antigravity (`agy`) half of the sandbox's application-level policy. Both
files are seeded and converged by `scripts/profile.sh` on every `up`; neither
requires a change to `docker-compose.yml`, because
`/Volumes/DataDrive/.claude-colima/profiles/<profile>/gemini-home` is already bind-mounted to
`/home/agent/.gemini`.

| Template | Lands at | Converge mode |
|---|---|---|
| `hooks.json` | `/home/agent/.gemini/config/hooks.json` | whole file, overwritten |
| `antigravity-settings.json` | `/home/agent/.gemini/antigravity-cli/settings.json` | **merged** — see below |

## Why the two files are not converged the same way

`hooks.json` is ours alone: nothing but the sandbox writes it, so it is
replaced wholesale.

`antigravity-cli/settings.json` is **shared with the running agent**. `agy`
writes `colorScheme`, `model`, `enableTelemetry` and `trustedWorkspaces` back
into it during ordinary use. Overwriting it would silently discard the user's
own settings on every `up`, so convergence merges only the two keys the
sandbox owns — `permissions` and `toolPermission` — and leaves every other key
untouched.

The same reasoning applies one level up: `gemini-home/config/` already holds
`config.json`, `mcp_config.json`, `.migrated` and `projects/`, which are live
`agy` state. Convergence there is **file-scoped**, never the directory mirror
used for skills (ADR-0005) — a mirror would delete all four.

## Why the hard denials live in settings.json, not in the hook

Measured, not assumed (`work/0010` Phase 0). `agy` discovers workspace
customizations under `.agents/`, `.agent/`, `_agents/` and `_agent/`, merges
hooks **by name**, and lets the workspace copy outrank the global one. A file
containing `{"sandbox-guardrails": {"enabled": false}}` in any attached
workspace switches the hook off outright — the agent's own writable bind
mount, no privilege needed.

Nothing in a workspace can reach `settings.json`. So the layer that must be
complete is the static `permissions.deny` list, and the hook is
defence-in-depth on top of it — the same shape Claude Code already has, and
the opposite of what this work assumed before it was measured.

The hook still blocks writes to a workspace `hooks.json` (rule
`agy-workspace-hook-tamper`, both the write-tool and the shell route), and
`scripts/audit/probes/antigravity.py` fails if one exists anyway.

## Open: `agy` has the policy but not the guidance

Phase D gave `agy` a real tool policy. It did **not** give it the standing
guidance Claude gets, and that gap is deliberate rather than overlooked.

Claude receives `sandbox_templates/common/agent-notice.md` because
`scripts/profile.sh` syncs it into `claude-home/CLAUDE.md` on every `up` —
Claude Code auto-loads that file in every session. `agy` reuses the `~/.gemini`
home and has no equivalent path this repo has been able to verify from profile
state: there is no global context file in `gemini-home/` to write into, and
guessing one would produce a file nothing reads, which is worse than an
acknowledged gap because it looks solved.

What `agy` **does** read natively is a workspace `AGENTS.md`. So the notice can
reach it today, per workspace:

```bash
scripts/sync-agent-notice.sh /Volumes/DataDrive/repo/<profile>/<repo>
# -> writes the managed block into that repo's AGENTS.md, idempotently
```

This is **not** wired into `up`, and should not be without a decision: it writes
into the operator's own git tree, and a script that edits a user's repository on
every container start is a different kind of thing from one that edits profile
state. The block is marker-delimited and idempotent, so re-running only replaces
the managed region — but the first run creates or modifies a tracked file.

Consequence to hold in mind meanwhile: **`agy` is gated but not briefed.** It
will be stopped by the deny list and the hook, and it will not know *why*, nor
that a denial is a human step rather than something to route around. The policy
is the control; the notice is what stops the agent burning turns on workarounds.
