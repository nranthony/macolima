# `deny-destructive` PreToolUse hook

Source-of-truth for current invariants is `../CLAUDE.md` → "Permissions
posture" and the gotcha "find -delete and the hook self-protection model".
This file is the design-and-maintenance record for the `PreToolUse` hook
that closes a class of deny-list bypasses the prefix matcher cannot see.

## Status (2026-05-14)

**v1 host-side shipped.** Code, settings wiring, in-image install path,
verify-sandbox tripwire, and audit probe all landed. End-to-end runtime
behaviour is pending an image rebuild + per-profile settings refresh.

What exists:

```
config/hooks/
  deny-destructive.sh           # POSIX sh + jq, 10 rules, fail-open trap
  deny-destructive.test.sh      # 35-assertion host-side harness, all green
Dockerfile                      # COPY + chmod 0755 to /usr/local/lib/claude-hooks/
config/claude-settings.json     # top-level "hooks" block (Bash + Edit|Write|MultiEdit)
scripts/verify-sandbox.sh       # tripwire: file invariants + behavioural deny probe
scripts/audit/probes/settings.py # _check_hooks() + REQUIRED_HOOKS (3 new checks)
CLAUDE.md                       # L8 paragraph, new gotcha, checklist + "What NOT to do" entries
```

What's pending:

- `scripts/profile.sh build` (rebuild base image with the hook baked in).
- `scripts/profile.sh <p> rebuild` per running profile (so they pick up the
  new image).
- `scripts/profile.sh <p> reset-settings` per existing profile (so the
  `hooks` block in `config/claude-settings.json` is copied into the live
  per-profile `claude-home/settings.json` — `ensure_state()` only seeds
  if the file is absent, preserving customizations). New profiles pick it
  up automatically on first `up`.
- End-to-end smoke: ask the agent to `find <sentinel> -delete` against a
  sentinel dir in `/tmp` — confirm block reason in transcript; sentinel
  survives.
- In-container `verify-sandbox.sh` run: confirm the new tripwire passes.
- `audit-sandbox` skill run: confirm `hook_present_Bash`,
  `hook_present_Edit_Write_MultiEdit`, `hook_file_immutable` all `OK`.

## Context — why the hook exists

A field session surfaced a bypass: agent hit `Bash(rm -rf:*)` deny three
times, pivoted to `find <path> -depth -delete`, and announced the
workaround in the transcript ("rm -rf is sandbox-blocked, so I used find
-depth -delete to the same effect"). `Bash(find:*)` is allow-listed for
legitimate search use, and the prefix matcher in `permissions.deny`
cannot see destructive flags (`-delete`, `-exec`, `-execdir`, `-ok`)
mid-command. Same class covers `git clean -fdx`, `shred`, `truncate`,
`dd of=`, `mkfs`, and "truncate via redirection" idioms (`: > file`,
`> /workspace/important`).

The fix the matcher structurally can't deliver is a `PreToolUse` hook
that inspects the full command string against a regex ruleset. Hooks run
in the harness, upstream of tool dispatch — the model is downstream and
cannot bypass at call time. The only realistic circumvention is
**tampering with the hook script or settings file**, closed here by
baking the hook root-owned into the image plus an Edit-side tamper
guard.

Behavioural follow-on (worth holding onto separately from the code): the
expected agent posture when a deny fires is "surface it, ask the user."
Pivoting to an equivalent allowed primitive is drift, not initiative.
The original L8 incident was caused by exactly that pivot; the hook
closes the structural gap, but the discipline is the durable fix. This
note is mirrored into `CLAUDE.md` so future agent sessions see it
without needing to read this file.

## Architecture

Three enforcement surfaces, ordered by how the bypass would have to
defeat them:

1. **Bash-side hook** — `deny-destructive.sh` matches the command via
   regex, blocks on hit. Catches the primary class.
2. **Edit-side hook** — same script, different matcher; blocks `Edit` /
   `Write` / `MultiEdit` whose target resolves under the hook dir or
   `settings.json`. Catches the obvious tampering path.
3. **Image-baked, root-owned** — hook script lives at
   `/usr/local/lib/claude-hooks/deny-destructive.sh` in the image,
   `root:root 0755`. Agent (UID 1000) cannot write via *any* tool because
   the kernel says so, not because a hook says so. The Edit-tamper hook
   is defence in depth on top of this.

Hooks are wired in `config/claude-settings.json` under the top-level
`hooks` key, referencing the absolute path. Per-profile customizable
hooks (`claude-home/hooks/`) are deliberately out of scope — see the
"Out of scope" section.

## Hook output contract

The hook follows Claude Code's current `PreToolUse` contract
(`https://code.claude.com/docs/en/hooks.md`):

- **Block**:
  ```json
  {"hookSpecificOutput":{
     "hookEventName":"PreToolUse",
     "permissionDecision":"deny",
     "permissionDecisionReason":"deny-destructive: <rule>: <message>"}}
  ```
- **Allow / pass-through**: `{}` on stdout, exit 0.
- **Fail-open** on any script error: `trap 'printf "{}\n"; exit 0'` —
  a broken hook must not brick the agent. The `verify-sandbox.sh`
  tripwire and the audit probe catch a permanently-broken hook within
  one cycle.

`exit 2` (the older "shortcut block" path that uses stderr as the
reason) is intentionally NOT used — it bypasses JSON, which means
verify-sandbox can't structurally assert the decision. Stick with
JSON-on-stdout.

Don't revert to the legacy `{"decision":"block"}` shape — current
Claude Code expects the `hookSpecificOutput.permissionDecision`
envelope, and `verify-sandbox.sh` greps for exactly that.

## Ruleset

The hook reads the tool-call JSON envelope on stdin and returns a
decision on stdout. Pass-through (`{}`) for any envelope that doesn't
match a rule. For `tool_name == "Bash"`, normalise the command
(lowercase, strip leading `sudo`/`time`/`nice`/`ionice`), then match in
order; first hit wins.

| # | Rule | egrep pattern | Disposition |
|---|---|---|---|
| 1 | `find-delete`         | `\bfind\b[^\|;&]*[[:space:]]-delete\b` | block |
| 2 | `find-exec`           | `\bfind\b[^\|;&]*[[:space:]]-(exec\|execdir\|ok)[[:space:]]+(rm\|mv\|dd\|truncate\|shred\|tee\|chmod\|chown)\b` | block |
| 3 | `git-clean`           | `\bgit[[:space:]]+clean\b` | block |
| 4 | `shred`               | `\bshred\b` | block |
| 5 | `truncate`            | `\btruncate\b` | block |
| 6 | `dd-write`            | `\bdd\b[^\|;&]*[[:space:]]of=` | block |
| 7 | `mkfs`                | `\bmkfs(\.[a-z0-9]+)?\b` | block |
| 8 | `hook-tamper` (Bash)  | `(>\|>>\|\btee\b\|\bchmod\b\|\bchown\b\|\bmv\b\|\bcp\b\|\brm\b\|\bln\b)[^\|;&]*(/usr/local/lib/claude-hooks/\|/home/agent/\.claude/settings\.json\|/etc/claude/)` | block |
| 9 | `null-truncate`       | bare `> file` clobber at command start (excludes `/dev/null`/`/dev/stderr`/`>&`) | **warn** |
| 10 | `workspace-overwrite`| `>[[:space:]]*/workspace/\S+` | **warn** |

For `tool_name in (Edit, Write, MultiEdit)`: read `tool_input.file_path`,
`realpath -m` it (canonical, doesn't require existence), block if the
resolved path has any of these prefixes:

- `/usr/local/lib/claude-hooks/`
- `/home/agent/.claude/settings.json` (exact)
- `/etc/claude/` (reserved)

**Block reason format**: `deny-destructive: <rule>: <one-line reason +
'ask the user to run this'>`.

**Warn behaviour**: append a JSON-line entry to
`/home/agent/.cache/deny-destructive.log` with `{ts, rule, tool_input}`
(timestamp + full envelope, not just the command — required to
evaluate the warn→block promotion review). Return `{}`, exit 0.

### Rule design notes

- **Narrow `find-exec`.** Block only when the executed token is in
  `{rm, mv, dd, truncate, shred, tee, chmod, chown}`. The original draft
  blocked all `-exec`, but `find . -exec grep|wc|file|ls` is benign and
  the agent uses these constantly. Specialist §4 ("surface, don't
  pivot") still applies — for the destructive set, the agent must
  surface to the user.
- **`jq` for parsing**, not hand-rolled grep/sed. Adds ~20–30 ms but
  hand-rolled JSON parsing risks silent bugs (escaped quotes, literal
  `"command":` substrings) that the fail-open trap would mask as
  silent missed blocks. Hook performance stays in the budget.
- **Lowercase normalisation is fine.** Linux paths are case-sensitive,
  so a casing mismatch in a tampered path wouldn't hit the protected
  location anyway.

### Specialist recommendations baked in

Original specialist review (2026-05-14) and how each is reflected:

| § | Recommendation | Status |
|---|---|---|
| 1 | Keep matcher-level denies as primary filter | Yes — `permissions.deny` unchanged; hook is the content-aware secondary layer for shapes the matcher can't express. |
| 2 | Data-driven warn→block transition with timestamps + full envelope | Done — warn log is JSON-line with `ts` + full `tool_input`. Promote only after a clean review week. |
| 3 | Command substitution (`find . $(echo -delete)`) is residual risk | Accepted — kernel + proxy + caps are the final boundary. No regex attempt. |
| 4 | `find-exec` blocks benign reads under the "surface, don't pivot" doctrine | Partially adopted — narrowed to destructive command tokens (see Rule design notes). Pure doctrine adherence would broad-block; we picked precision over purism for ergonomics. |
| 5 | Hook performance — POSIX sh, avoid heavy subshells | Done — POSIX sh + `jq` (already in image for audit probes). One `cat` + a few `jq` invocations + `grep -E` per envelope. |

## File-by-file reference

Pointers to the live code, not duplicated content (which would drift):

- `config/hooks/deny-destructive.sh` — the hook itself.
- `config/hooks/deny-destructive.test.sh` — host-side test harness, 35
  assertions covering negatives, all rule positives, hook-tamper for
  both Bash and Edit paths, malformed JSON / empty stdin robustness,
  and warn-log writes.
- `Dockerfile` — `COPY --chown=root:root config/hooks/deny-destructive.sh
  /usr/local/lib/claude-hooks/deny-destructive.sh` followed by
  `RUN chmod 0755`. Inserted between the `.zshrc` copy block and the
  `USER agent` switch so the file lands root-owned. (Not using
  `COPY --chmod=` to stay portable across non-BuildKit builders.)
- `config/claude-settings.json` — top-level `hooks.PreToolUse` with two
  matcher entries (`Bash`, `Edit|Write|MultiEdit`) both pointing at the
  in-image hook with `timeout: 2`.
- `scripts/verify-sandbox.sh` — tripwire after the CONNECT-on-non-443
  probe. File invariants (`-x`, `! -w`, expects root:root 0755) plus a
  behavioural assertion: pipes a `find /tmp -delete` envelope through
  the live hook and greps for `"permissionDecision":"deny"`.
- `scripts/audit/probes/settings.py` — `REQUIRED_HOOKS` list +
  `_check_hooks()` returning three checks: matcher wiring for `Bash`
  and `Edit|Write|MultiEdit`, plus `hook_file_immutable` (file-level
  invariants checked from the agent UID via `os.access(..., os.W_OK)`).
- `CLAUDE.md` — L8 paragraph in "Permissions posture", new gotcha
  "`find -delete` and the hook self-protection model", editing-checklist
  entry, two new "What NOT to do" entries (one for hook block / path
  relocation, one for output-shape reverts).

## Maintenance

### When extending the ruleset

Every new destructive primitive needs **all three** of the following, or
silent drift creeps in:

1. New rule in `config/hooks/deny-destructive.sh` (block or warn,
   following the `match … && emit_block …` / `warn_log` pattern).
2. New positive + negative assertions in
   `config/hooks/deny-destructive.test.sh`. Run on host pre-commit
   (`bash config/hooks/deny-destructive.test.sh`) — must stay green.
3. If the rule adds a new path constant, an extension to the
   `verify-sandbox.sh` probe and/or `_check_hooks()` so the new
   constant is asserted at runtime, not just in the test harness.

The editing checklist in `CLAUDE.md` includes a bullet that fires
whenever an allow-listed Bash prefix is added — "audit its flag surface
for destructive primitives." That bullet's purpose is to surface this
maintenance need at the right moment.

### Warn-log review (warn → block promotion)

Two rules ship as **warn**: `null-truncate` and `workspace-overwrite`.
Both are high-variance — there are legitimate uses (e.g., `: > file` to
truncate a log the agent owns; `> /workspace/build/output.json` for
build artifacts). Promote to `block` only after one clean review week:

```bash
# Inside an active profile
docker exec claude-agent-<p> cat /home/agent/.cache/deny-destructive.log | jq .
```

Each entry is a JSON-line with `ts`, `rule`, and the full `tool_input`.
Look for any legitimate-looking write that would be falsely blocked. If
zero false positives over a week of active development, flip the
`warn_log` call in the hook to `emit_block`, add the corresponding
positive assertion in the test harness, and rebuild.

### When Claude Code's hook contract changes

The output schema is the most likely fragility. If a Claude Code release
changes the `hookSpecificOutput` envelope shape:

1. Update `emit_block()` in `deny-destructive.sh`.
2. Update the `grep` in `verify-sandbox.sh`'s tripwire.
3. Re-run `bash config/hooks/deny-destructive.test.sh` — the assertion
   greps the `permissionDecision` field, so the test catches schema
   regressions.
4. Add a note to `CLAUDE.md` if the change affects what writers should
   know.

## Verification

End-to-end pass criteria once rollout completes:

- [x] `bash config/hooks/deny-destructive.test.sh` — all 35 assertions
  pass on host (achieved 2026-05-14).
- [ ] Rebuilt container: agent-issued `find /tmp -delete` returns a
  hook deny with `deny-destructive: find-delete: …`; sentinel still
  present.
- [ ] Agent-issued `Edit` targeting
  `/usr/local/lib/claude-hooks/deny-destructive.sh` blocked by
  `hook-tamper`.
- [ ] Agent-issued `cat > /usr/local/lib/claude-hooks/deny-destructive.sh`
  blocked by `hook-tamper` (Bash side).
- [ ] With hook simulated-broken (privileged-shell `chmod -x` from
  outside the agent loop), kernel write-protect still holds — agent's
  write to the hook path fails with `EACCES`.
- [ ] `scripts/verify-sandbox.sh` — PASS for both
  `deny-destructive hook blocks find -delete` and the file-permissions
  check.
- [ ] Audit skill — `hook_present_Bash`,
  `hook_present_Edit_Write_MultiEdit`, `hook_file_immutable` all `OK`.

## Out of scope

- **Per-profile user-customizable hooks** via `claude-home/hooks/`
  (skills-style seeding). Premature flexibility; revisit if a project
  actually needs a project-specific block.
- **Hardening parallel paths** (agent writes a Python script via Edit,
  runs it via allowed `python:*`). Closing this would require either
  a `python:*` deny (breaks routine use) or AST-level inspection of
  script files written by Edit. The kernel + proxy + caps remain the
  documented boundary for that case.
- **RO bind-mount of `~/.claude/settings.json`.** Rejected because
  Claude Code writes UI prefs (`theme`/`model`/`effortLevel`) into the
  live file; an RO mount would break those writes. The Edit-side hook
  rule covers that control instead.
- **Defeating shell-alias bypasses** (`alias fdel='find -delete'`). The
  matcher-level prefix denies in `permissions.deny` are the primary
  filter; the hook is content-aware on the unaliased command string
  the harness sees. If the agent defines an alias and runs it in the
  same Bash invocation, the hook still sees the underlying command.
  Aliases sourced from a shell rcfile are not in scope.
