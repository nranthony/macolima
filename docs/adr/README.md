# Architecture Decision Records

Decisions whose *reasoning* has to outlive the commit that implemented them.
Each records the context that forced a choice, so the choice is not
re-litigated from scratch when the context is no longer visible in the code.

Append-only. A decision that changes gets a **new** ADR that supersedes the old
one; the old text stays as written.

| # | Decision |
|---|---|
| [0003](0003-strict-egress-default.md) | Egress is default-deny, and the default stays deny |
| [0004](0004-python-wheels-only.md) | A private CLI reaches the image as a vendored wheel |
| [0005](0005-skill-templates-are-source-of-truth.md) | Skill templates are the source of truth |
| [0006](0006-antigravity-is-two-layer-like-claude.md) | Two agents, one hook engine, two dialects |
| [0007](0007-policy-templates-are-source-of-truth-for-every-agent.md) | Agent policy converges from the template |
| [0008](0008-deletion-is-a-human-step.md) | Deletion is proposed, not performed |
| [0009](0009-public-repo-names-are-searchable-not-absent.md) | A private name is searchable, not absent |
| [0011](0011-web-read-backends-are-peers-with-no-default.md) | Web-read backends are peers; no default |
| [0012](0012-web-read-backends-get-read-hosts-only.md) | A backend gets its READ hosts only |

## Why the numbering starts at 0003, and why 0010 is missing

The numbers are **deliberately aligned with the sibling repo**
(`windows-ai-sandbox`), which adopted this practice first. Six files here
already cited ADR numbers before `docs/adr/` existed — `docs/web-read-broker.md`
(0011, 0012, as live links), `sandbox_templates/antigravity/README.md` (0005),
`antigravity-settings.json` (0006, by path), `claude-settings.json` (0007),
`deny-destructive.sh` (0006) and `scripts/agent-policy.test.sh` (0005) — and
every one assumed the sibling's numbering. Renumbering would have broken all six
to gain nothing.

**Not every `ADR-NNNN` in this tree is ours.** `docs/database-internals.md`
cites *myclickup's* ADR-0003, and the vendored `myconv` skills cite the
`agentic-conventions` repo's ADRs throughout. Check which repo a citation
belongs to before linking it.

0001, 0002 and 0010 are records of the **sibling's own repo history** — its
adoption of the provenance tiers, the scope of its dependency-guardrail work,
and the closing of its `docs/rfcs/` tier. They describe migrations this repo
never went through. The numbers are reserved rather than reused, so that
"ADR-0002" means one thing across both repos.

New decisions here continue from **0013**.

## See also

`work/NNNN-slug/` holds plans and specs — what we are *doing*. An ADR holds why
a door is closed. If a work item's decision section is being cited months later,
it wants to be an ADR.
