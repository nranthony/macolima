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

## Briefed from `~/.gemini/config/rules/` (ADR-0015)

Phase D gave `agy` a real tool policy. The standing guidance Claude gets —
`sandbox_templates/common/agent-notice.md` — now reaches `agy` too, by the
same mechanism and on the same verbs: `scripts/profile.sh` writes the notice
into **both** agent homes on every `up`, `recreate`, `rebuild` and `converge`:

| Agent | File in the container | On the host |
|---|---|---|
| Claude Code | `~/.claude/CLAUDE.md` (auto-loaded every session) | `profiles/<p>/claude-home/CLAUDE.md` |
| `agy` | `~/.gemini/config/rules/sandbox-notice.md` | `profiles/<p>/gemini-home/config/rules/sandbox-notice.md` |

The second target follows `agy`'s embedded documentation: `~/.gemini/config/`
is its global customization root ("applies to all projects and workspaces"),
and within any root, rules live under `rules/` as plain markdown. Global rules
are tier three of five, below workspace rules; that ordering settles name
conflicts between skills and plugins only — rules merge and deduplicate, so a
repo's `AGENTS.md` adds to the notice rather than replacing it. The
measurement that `agy` loads the file is recorded in
`work/0011-sandbox-notice-global-homes/notes.md`; until it is, the route is
documented rather than observed, which is the same standing the hooks had
before test G.

The notice is **never written into a repo.** The earlier per-workspace recipe
(sync into a repo's `AGENTS.md`) is retired: blocks placed that way went stale
in every repo that carried one, repo agents may not edit inside the markers,
and two sandboxes writing different markers into one slot stacked blocks
instead of replacing them. `scripts/sync-agent-notice.sh --strip` removes a
block met in the wild, `workspace-scan.py` flags one (`NOTICE-IN-REPO`), and
`verify-sandbox.sh` asserts both home files carry the current template.
