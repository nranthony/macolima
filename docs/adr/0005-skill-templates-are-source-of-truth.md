# ADR-0005 — Skill templates are the source of truth; the profile copy is a cache

- **Status:** Accepted (2026-09-02)
- **Deciders:** nranthony + agent

## Context

Skills were seeded into a profile **once, at creation**, and never touched
again. Measured on two live profiles: both carried a `myclickup` SKILL.md **29
lines behind** the template, describing a CLI version that was not installed.
Nothing reported it, because create-only seeding has no opinion about what it
already created.

A stale skill is worse than a missing one. It sends an agent to run commands
that do not exist, in a container where it cannot install a fix.

## Decision

`sandbox_templates/skills/` is the source of truth. `claude-home/skills/` is a
**derived cache**, reconciled on every `up` and by `profile.sh <p> converge`.

- A new or edited template skill lands on the next `up`.
- A skill removed from the template is **pruned** from every profile.
- A locally edited copy is **replaced, with a WARN** — reported, never silent.
- **No backups are kept inside `~/.claude/skills/`.** A `<name>.bak.<stamp>`
  there is a second *live* copy, and for a plugin-shaped skill the backup wins
  the name race — `myconv` is exactly that shape
  (`.claude-plugin/plugin.json` plus six nested skills), so a backup would load
  *instead of* the fresh copy.
- Pruning is scoped by a `.sandbox-seeded` manifest to names this repo seeded,
  so a skill an agent authored in a profile (`claude plugin init`) survives.
- The replace is staged through a sibling directory **on the same filesystem**
  as the destination, so a mid-copy failure cannot leave a half-written skill
  after the old one has already been removed.

## Consequences

- **Intentional per-profile variation has a different home**: a per-repo
  `.claude/skills/` in the workspace, or the template itself. Personal scope is
  not a customisation surface.
- **Restart `claude` in the container** to pick a converged skill up.
- The staging detail is not cosmetic. The sibling repo stages through
  `mktemp -d`, which on macOS is a **different device** from the profile tree
  (measured: 16777232 against 16777245), so its `mv` degrades to a copy and the
  atomicity its comment claims is silently gone — after the destination has
  already been deleted. Same-filesystem staging is correct on both platforms.
