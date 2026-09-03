# ADR-0007 — Agent policy converges from the template, for every agent

- **Status:** Accepted (2026-09-03)
- **Deciders:** nranthony + agent

## Context

[ADR-0005](0005-skill-templates-are-source-of-truth.md) made skills converge but
left **policy** create-only, so a profile's `settings.json` could sit
arbitrarily far behind the template with nothing reporting it. Two commands,
`reset-settings` and `reset-skills`, did near-identical work with three
different semantics between them, and the confusion is precisely what let the
policy drift go unnoticed.

Adding a second agent (`agy`, [ADR-0006](0006-antigravity-is-two-layer-like-claude.md))
made the create-only model untenable: there were now two policy files per
profile, in two grammars, seeded once and never reconciled.

## Decision

**Policy templates are the source of truth for every agent**, converged on every
`up`/`recreate`/`rebuild`/`wipe`, and by `profile.sh <p> converge` with no
container involvement.

- **Owned keys are overwritten**: `env`, `hooks`, `permissions`, `sandbox`.
  Anything the convergence displaces is **captured** to
  `claude-home/settings.discarded.json` before it is replaced — so a reverted
  in-session grant is recoverable and visible, not merely gone.
- **Preference keys are preserved, not owned**: `model`, `effortLevel`,
  `agentPushNotifEnabled`, `skipAutoPermissionPrompt`, `skipWorkflowUsageWarning`,
  `tui`, `theme`. A value already in a profile survives every converge; the
  template value only **seeds a profile that lacks the key**. Tier-1 verify does
  not compare them, so a live value differing from the template is the design
  working, not drift.
- `converge --defaults` resets the preserved keys to the template defaults and
  captures what it replaced.
- **A corrupt live policy is left alone.** Its other keys may still be
  recoverable by hand; replacing it is the agent's report to make, not ours.
- `reset-settings` and `reset-skills` were **removed**, not aliased.

## Consequences

- **An in-session permission grant does not survive a converge.** To keep one,
  edit the template. The convergence says so when it reverts.
- A per-repo `.claude/settings.local.json` can **tighten** permissions but can
  never re-allow what the sandbox denies, nor promote an `ask` to `allow`.
- **Annotation keys are stripped before diffing**, which is correct for
  detecting drift and had one sharp edge: a `_comment` key placed *inside*
  `hooks` converged cleanly into every profile and surfaced only as a CLI
  warning a human read. Claude Code validates keys inside `hooks` strictly;
  `permissions` and `sandbox` tolerate annotations. Prose therefore lives at top
  level, and a test locks it.
