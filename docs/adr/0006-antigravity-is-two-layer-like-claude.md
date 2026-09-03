# ADR-0006 — Two agents, one hook engine, two dialects that must not converge

- **Status:** Accepted (2026-09-03)
- **Deciders:** nranthony + agent

## Context

This sandbox ships two agents: Claude Code and Antigravity (`agy`). Both need
the same destructive-command guardrail. The obvious implementation — one script,
one output format — is wrong, because the two CLIs put the hook in **different
structural positions**.

Claude Code has a static `permissions.deny` list *underneath* the hook. The hook
is defence in depth: if it fails or returns nothing, the deny list still stands.

`agy` has no such layer for these shapes. There, **the hook IS the control**.

## Decision

One engine (`deny-destructive.sh`), selected by an explicit `--dialect=` flag,
with four asymmetries that are load-bearing and must never be flattened:

1. **Failure posture is opposite.** A malformed envelope **passes** under
   `claude` (fail-open — the deny list is underneath) and **denies** under
   `antigravity` (fail-closed — nothing is underneath). Consequently the
   antigravity pass-through must stay an explicit `{"decision":"allow"}`:
   `{}` is a DENY to `agy`.
2. **The ask tier is dialect-branched.** `permissionDecision:"ask"` for claude,
   `decision:"force_ask"` for antigravity — because `agy` caches a plain `ask`
   approval as a **permanent Always-Allow grant**. Using the same spelling would
   silently convert a per-call confirmation into a standing permission.
3. **An unknown `--dialect=` is FATAL**, never coerced to claude. Coercing would
   turn a typo in a config file into a silently fail-open guardrail on the agent
   that has nothing underneath.
4. **Convergence write modes are opposite.** The claude policy is
   **overwritten**; the agy policy is **merged**, because `agy` has no
   repo-local file to hold its preferences and stores colour scheme, model and
   trusted-workspace state in the same file.

The two policy files are kept in lockstep by `scripts/agent-policy.test.sh`,
which diffs the grammars (`Bash(x:*)` against `command(x)`) in **both**
directions with no exception list. The antigravity file is **regenerated** from
the claude one, never hand-maintained.

## Consequences

- **Do not unify the dialects.** Each of the four asymmetries is a hole if
  flattened, and three of them fail *open* rather than loudly.
- A one-sided policy edit fails offline, before any container sees it.
- `Read(...)` denials have no `command()` equivalent, so the antigravity deny
  list is `command()`-only — locked, so nobody "completes" the conversion.
- On this substrate the hook file is **kernel-write-protected**: it is root-owned
  and the agent is UID 1000. That guarantee does not exist in the sibling repo,
  where the agent is root — so the probe that measures it here measures nothing
  there, and must not be ported blind.
