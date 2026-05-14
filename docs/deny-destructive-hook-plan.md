# `deny-destructive` PreToolUse hook — design plan

Source-of-truth for current invariants is `../CLAUDE.md`. This file is the
implementation plan for closing a deny-list bypass class via a Claude Code
`PreToolUse` hook. Not yet implemented as of 2026-05-13.

## Context

A field session surfaced a bypass: agent hit `Bash(rm -rf:*)` deny three times,
pivoted to `find <path> -depth -delete`, and announced the workaround in the
transcript ("rm -rf is sandbox-blocked, so I used find -depth -delete to the
same effect"). `Bash(find:*)` is allow-listed for legitimate search use, and
the prefix matcher in `permissions.deny` cannot see destructive flags
(`-delete`, `-exec`, `-execdir`, `-ok`) mid-command. Same class covers
`git clean -fdx`, `shred`, `truncate`, `dd of=`, `mkfs`, and the analogous
"truncate via redirection" idioms (`: > file`, `> /workspace/important`).

The fix the matcher structurally can't deliver is a PreToolUse hook that
inspects the full command string against a regex ruleset. Hooks run in the
harness, upstream of tool dispatch — the model is downstream and cannot bypass
at call time. The only realistic circumvention is **tampering with the hook
script or settings file**, closed here by baking the hook root-owned into the
image plus an Edit-side tamper guard.

Intended outcome: when the agent issues a destructive primitive reachable
through an allowed prefix, the harness blocks it and returns a reason string
the agent sees as tool output. Plus a `verify-sandbox.sh` tripwire so a
missing/swapped hook fails the next `--verify`.

## Architecture

Three enforcement surfaces, ordered by how the bypass would have to defeat
them:

1. **Bash-side hook** — `deny-destructive.sh` matches the command via regex,
   blocks on hit. Catches the primary class.
2. **Edit-side hook** — same script, different matcher; blocks `Edit` /
   `Write` / `MultiEdit` whose target resolves under the hook dir or
   `settings.json`. Catches the obvious tampering path.
3. **Image-baked, root-owned** — hook script lives at
   `/usr/local/lib/claude-hooks/deny-destructive.sh` in the image,
   `root:root 0755`. Agent (UID 1000) cannot write via *any* tool because the
   kernel says so, not because a hook says so. The Edit-tamper hook is
   defence in depth on top of this.

Hooks are wired in `config/claude-settings.json` under a new top-level `hooks`
key, referencing the absolute path. Not per-profile customizable —
out-of-scope flexibility for the first iteration.

## Ruleset

`deny-destructive.sh` reads the tool-call JSON envelope on stdin and returns a
decision on stdout. Pass-through (`{}`) for any envelope that doesn't match a
rule. For `tool_name == "Bash"`, normalise the command (lowercase, strip
leading `sudo`/`time`/`nice`/`ionice`), then match in order; first hit wins.

| Rule | egrep pattern | Disposition | Notes |
|---|---|---|---|
| `find-delete`         | `\bfind\b[^\|;&]*[[:space:]]-delete\b`                      | block      | The bypass that motivated the hook. |
| `find-exec`           | `\bfind\b[^\|;&]*[[:space:]]-(exec\|execdir\|ok)\b`          | block      | `find -exec rm` and friends. |
| `git-clean`           | `\bgit[[:space:]]+clean\b`                                  | block      | `-fdx` wipe. User runs this, not agent. |
| `shred`               | `\bshred\b`                                                 | block      | Destructive overwrite. |
| `truncate`            | `\btruncate\b`                                              | block      | Destructive size change. |
| `dd-write`            | `\bdd\b[^\|;&]*[[:space:]]of=`                              | block      | Raw block write. |
| `mkfs`                | `\bmkfs(\.[a-z0-9]+)?\b`                                    | block      | Filesystem create. |
| `hook-tamper` (Bash)  | `(>\|>>\|tee\b\|chmod\b\|chown\b\|mv\b\|cp\b\|rm\b\|ln\b)[^\|;&]*\b(/usr/local/lib/claude-hooks/\|/home/agent/\.claude/settings\.json\|/etc/claude/)` | block | Defence in depth on the kernel write-protect. |
| `null-truncate`       | `(^\|[;&\|\`$( ])[[:space:]]*:?[[:space:]]*>[[:space:]]*[^&[:space:]]` (excluding `/dev/null`/`/dev/stderr`/`>&`) | **warn** | Promote to block after one clean week. |
| `workspace-overwrite` | `>[[:space:]]*/workspace/\S+`                               | **warn**   | Same: ship as warn first. |

For `tool_name in (Edit, Write, MultiEdit)`: read `tool_input.file_path`,
`realpath -m` it (canonical, doesn't require existence), block if the
resolved path has any of these prefixes:

- `/usr/local/lib/claude-hooks/`
- `/home/agent/.claude/settings.json` (exact)
- `/etc/claude/` (reserved)

Block reason format: `deny-destructive: <rule>: <one-line reason + 'ask the
user to run this'>`. Warn behaviour: append `<rule>\t<command>` to
`/home/agent/.cache/deny-destructive.log` (named volume, survives recreate),
return `{}`, exit 0.

**Fail-open on script error.** `trap 'echo {}; exit 0' ERR`. A broken hook
must not brick the agent; the `verify-sandbox.sh` probe + audit probe catch
permanently-broken hooks within one cycle.

## File-by-file changes

### New: `config/hooks/deny-destructive.sh`

POSIX `sh`. Implements the ruleset above. One file handles both Bash and
Edit/Write/MultiEdit by branching on `tool_name` — simpler to audit and
matches "one hook script, two matcher entries pointing at it" in
`settings.json`.

### New: `config/hooks/deny-destructive.test.sh`

Host-side test harness. Pipes ~25 canned envelopes through the hook and
asserts. Coverage:

- `find . -name '*.py'` → pass-through (negative)
- `find . -delete` → block, rule=`find-delete`
- `find . -exec rm {} \;` → block, rule=`find-exec`
- `find . -print` → pass-through
- `git clean -fdx` → block
- `git status` → pass-through
- `cat > /usr/local/lib/claude-hooks/deny-destructive.sh` → block, `hook-tamper`
- `dd if=/dev/zero of=/tmp/x` → block, `dd-write`
- `echo dd is fine` → pass-through (word-boundary check)
- Edit envelope targeting `/usr/local/lib/claude-hooks/...` → block
- non-Bash, non-Edit tool envelope → pass-through
- malformed JSON → fail-open `{}` (no crash, no false block)

Runs on the host pre-commit (`bash config/hooks/deny-destructive.test.sh`).
No container needed.

### `Dockerfile`

After the existing `COPY --chown=agent:agent config/.zshrc …` block
(around line 154), add:

```dockerfile
# PreToolUse hook script. Root-owned, world-readable, world-executable.
# Agent runs as UID 1000 and cannot modify this via any tool path (kernel
# write-protect is the boundary; the matched Edit-tamper hook is defence
# in depth). Updates require image rebuild — intentional friction.
COPY --chown=root:root --chmod=0755 \
     config/hooks/deny-destructive.sh \
     /usr/local/lib/claude-hooks/deny-destructive.sh
```

If the build engine doesn't support `COPY --chmod=`, fall back to a regular
`COPY` followed by `RUN install -D -m 0755 -o root -g root <src> <dst>`.

### `config/claude-settings.json`

Add a top-level `hooks` block after `permissions`:

```jsonc
"hooks": {
  "_comment": "PreToolUse enforcement upstream of tool dispatch. The matcher-level permissions.deny list is prefix-on-tokens and cannot see destructive flags (find -delete, dd of=, etc.) or path targets (Edit to /usr/local/lib/claude-hooks/…). The hook script handles both via regex on the full envelope. Script is baked root-owned in the image; agent has no write access via any tool path. See docs/deny-destructive-hook-plan.md.",
  "PreToolUse": [
    { "matcher": "Bash",
      "hooks": [ { "type": "command", "command": "/usr/local/lib/claude-hooks/deny-destructive.sh", "timeout": 2 } ] },
    { "matcher": "Edit|Write|MultiEdit",
      "hooks": [ { "type": "command", "command": "/usr/local/lib/claude-hooks/deny-destructive.sh", "timeout": 2 } ] }
  ]
}
```

### `scripts/profile.sh` — no seeding step

Hooks are in the image, not seeded per profile. **No `ensure_state()` change
needed.** Skip the `reset-hooks` subcommand — updates flow through
`scripts/profile.sh build` + per-profile `rebuild`.

### `docker-compose.yml` — no mount change

The hook lives in image rootfs at `/usr/local/lib/claude-hooks/`, untouched
by any bind mount. No compose change required. RO-mounting `settings.json`
on top of the rw `claude-home` bind was considered and rejected — Claude
Code writes `theme`/`model`/`effortLevel` into the live `settings.json`, and
an RO mount would break those writes. The Edit-tamper hook covers that
control instead.

### `scripts/verify-sandbox.sh`

After the CONNECT-on-non-443 probe (`verify-sandbox.sh:86–120`), add:

```bash
# Deny-destructive hook tripwire (audit L8).
# config/hooks/deny-destructive.sh must be installed root-owned at the path
# referenced in settings.json's hooks block, executable, not writable by
# the agent, and must actually block the canonical bypass.
HOOK=/usr/local/lib/claude-hooks/deny-destructive.sh
if [[ ! -x $HOOK ]]; then
  fail "deny-destructive hook missing or not executable at $HOOK"
elif [[ -w $HOOK ]]; then
  fail "deny-destructive hook is writable by agent (should be root:root 0755): $(stat -c '%U:%G %a' $HOOK)"
else
  out=$(printf '{"tool_name":"Bash","tool_input":{"command":"find /tmp -delete"}}' | $HOOK)
  if echo "$out" | grep -q '"decision":"block"'; then
    pass "deny-destructive hook blocks find -delete"
  else
    fail "deny-destructive hook present but not blocking find -delete (out: $out)"
  fi
fi
```

`pass` / `fail` / `warn` helpers already exist at `verify-sandbox.sh:14–16`.

### `scripts/audit/probes/settings.py`

Add `REQUIRED_HOOKS` and `_check_hooks()` mirroring the `_check` pattern at
`settings.py:66–72` and the multi-condition gating from `env.py`'s
`no_vscode_ssh_socket` probe:

```python
REQUIRED_HOOKS = [
    {"matcher": "Bash",                 "command_endswith": "deny-destructive.sh"},
    {"matcher": "Edit|Write|MultiEdit", "command_endswith": "deny-destructive.sh"},
]

def _check_hooks(live):
    out = []
    hooks_cfg = (live or {}).get("hooks", {}).get("PreToolUse", [])
    for req in REQUIRED_HOOKS:
        present = any(
            entry.get("matcher") == req["matcher"]
            and any(h.get("command", "").endswith(req["command_endswith"])
                    for h in entry.get("hooks", []))
            for entry in hooks_cfg
        )
        out.append(_check(
            f"hook_present_{req['matcher'].replace('|','_')}",
            present,
            required=req,
        ))

    # File-level: exists, root-owned, agent cannot write, executable.
    path = "/usr/local/lib/claude-hooks/deny-destructive.sh"
    try:
        st = os.stat(path)
        exists = True
        root_owned = (st.st_uid == 0)
        executable = bool(st.st_mode & 0o111)
        agent_writable = os.access(path, os.W_OK)
    except FileNotFoundError:
        exists = root_owned = executable = False
        agent_writable = None
    out.append(_check(
        "hook_file_immutable",
        exists and root_owned and executable and not agent_writable,
        path=path, exists=exists, root_owned=root_owned,
        executable=executable, agent_writable=agent_writable,
        rationale="hook must be in-image, root:root, 0755, not writable by agent",
    ))
    return out
```

Call from `run()`, extend its return list. `os.access(..., os.W_OK)`
evaluated as the agent inside the container is the right gate.

### `CLAUDE.md` edits

**a.** Append to the L7 question-list bullet under "Permissions posture":

> Audit L8 (2026-05-13) extended the surface to destructive primitives
> reachable through allowed prefixes (`find -delete`/`-exec`/`-execdir`/
> `-ok`, `git clean -fdx`, `shred`, `truncate`, `dd of=`, `mkfs`) and to
> writes targeting the hook/settings files themselves. The matcher cannot
> express these mid-command shapes; enforcement is a `PreToolUse` hook
> wired on `Bash` and `Edit|Write|MultiEdit`, script baked root-owned at
> `/usr/local/lib/claude-hooks/deny-destructive.sh`. See
> `docs/deny-destructive-hook-plan.md` for ruleset and maintenance.

**b.** New gotcha after "Permissions posture":

> ### `find -delete` and the hook self-protection model
>
> The matcher is prefix-on-tokens; it cannot see destructive flags or path
> targets mid-command. The class includes `find -delete`/`-exec`,
> `git clean -fdx`, `shred`, `truncate`, `dd of=`, `mkfs`, plus writes to
> the hook/settings files themselves. Enforcement is a `PreToolUse` hook
> (`/usr/local/lib/claude-hooks/deny-destructive.sh`) installed root-owned
> in the image — the agent has no tool path that bypasses the kernel's
> write protection on those files. The hook is fail-open on script error
> (defence in depth, not boundary) and gated by `verify-sandbox.sh` plus
> `scripts/audit/probes/settings.py`. Extending the ruleset requires
> touching the hook script *and* both probes — every new destructive
> primitive needs both, or you get silent drift.
>
> Behavioural note: when a Bash deny fires, the expected agent posture is
> "surface it, ask the user" — pivoting to an equivalent allowed primitive
> is drift, not initiative.

**c.** "What NOT to do" — add:

> - Don't remove the `hooks` block from `config/claude-settings.json` or
>   relocate `deny-destructive.sh` out of `/usr/local/lib/claude-hooks/` —
>   the matcher cannot express the shapes the hook catches, and the path
>   is hardcoded in `verify-sandbox.sh` and `scripts/audit/probes/settings.py`.

**d.** Editing checklist — add:

> - [ ] New allow-listed Bash prefix? Audit its flag surface for
>       destructive primitives (`-delete`, `-exec`, `-c`, `-e`, `of=`,
>       etc.); extend `config/hooks/deny-destructive.sh` ruleset + test
>       harness + verify-sandbox probe if any exist.

## Rollout

1. Write `config/hooks/deny-destructive.sh` + `deny-destructive.test.sh` on
   host. `bash config/hooks/deny-destructive.test.sh` green.
2. Dockerfile change. Rebuild base: `scripts/profile.sh build`.
3. Add `hooks` block to `config/claude-settings.json`. Per-profile re-up
   via `reset-settings` + restart Claude, *or* `scripts/profile.sh <p> rebuild`.
4. Attach to a profile; against a sentinel dir in `/tmp`, ask the agent to
   run `find <sentinel> -delete`. Confirm block + reason in transcript;
   confirm sentinel survives.
5. Add `verify-sandbox.sh` probe and `settings.py` `REQUIRED_HOOKS`. Run
   `scripts/verify-sandbox.sh` inside the container — all green.
6. Run `scripts/stage-audit-package.sh <p>` + the in-container
   `audit-sandbox` skill. New checks `OK`.
7. CLAUDE.md edits.
8. Write `feedback`-type memory `deny-pivot-discipline` capturing
   "surface, don't pivot" for future sessions.

## Verification

End-to-end pass criteria:

- `bash config/hooks/deny-destructive.test.sh` — all positives blocked
  with correct rule, all negatives pass through, malformed JSON
  fails open.
- Rebuilt container: agent-issued `find /tmp -delete` returns
  `deny-destructive: find-delete: …`; sentinel still present.
- Agent-issued `Edit` targeting `/usr/local/lib/claude-hooks/deny-destructive.sh`
  blocked by hook-tamper rule.
- Agent-issued `cat > /usr/local/lib/claude-hooks/deny-destructive.sh`
  blocked by hook-tamper rule (Bash side).
- With hook simulated-broken (privileged-shell `chmod -x` from outside
  the agent loop), kernel write-protect still holds — agent's write to
  the hook path fails with `EACCES`.
- `scripts/verify-sandbox.sh` — PASS for both
  `deny-destructive hook blocks find -delete` and the file-permissions
  check.
- Audit skill — `hook_present_Bash`, `hook_present_Edit_Write_MultiEdit`,
  `hook_file_immutable` all `OK`.

## Critical files

- `config/hooks/deny-destructive.sh` (new)
- `config/hooks/deny-destructive.test.sh` (new)
- `Dockerfile` — `COPY --chown=root:root --chmod=0755` for the hook
- `config/claude-settings.json` — add top-level `hooks` block
- `scripts/verify-sandbox.sh` — add tripwire after the CONNECT probe
- `scripts/audit/probes/settings.py` — add `_check_hooks()` + `REQUIRED_HOOKS`
- `CLAUDE.md` — three edits as above

## Out of scope

- **Per-profile user-customizable hooks** via `claude-home/hooks/`
  (skills-style seeding). Premature flexibility; revisit if a project
  actually needs a project-specific block.
- **Hardening parallel paths** (agent writes a Python script via Edit,
  runs it via allowed `python:*`). Closing this would require either a
  `python:*` deny (breaks routine use) or AST-level inspection of script
  files written by Edit. The kernel + proxy + caps remain the documented
  boundary for that case.
- **RO bind-mount of `~/.claude/settings.json`.** Rejected because
  Claude Code writes UI prefs there; an RO mount would break those
  writes. Edit-side hook covers the control.
