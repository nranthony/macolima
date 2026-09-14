# work/ — in-flight implementation artifacts

One folder per work item, `NNNN-slug/`, holding `spec.md` (what/why) → `plan.md`
(design + ordered steps) → `notes.md` (execution log). Convention borrowed from
`windows-ai-sandbox` (its ADR-0001, provenance tiers).

**Exit rule:** when a work item's changes merge, move its folder to
`work/archive/` (never delete it — an archived plan is explicitly historical,
a deleted one leaves dangling `work/NNNN` citations across `docs/`). A stale
`plan.md` left active reads as current intent long after it stopped being
true. Anything durable it holds is distilled first: decision rationale → an
ADR, reference knowledge → `docs/` or a skill.

Numbering continues from the highest archived item.

**Unqualified `work/NNNN` citations inside code ported from windows-ai-sandbox
name *its* items, not ours.** `work/0008 item 1` (the Python dependency gates,
in `verify-sandbox.sh`, `depaudit.*`, `with-egress.*`), `work/0009` (opencode)
and `work/0010` (the agy guardrails) in `deny-destructive.*` and the antigravity
templates are W's. They were kept verbatim so parity diffs against the sibling
stay clean. This repo's 0008, 0009 and 0010 are the items below. ADR numbers, by
contrast, are shared on purpose: both repos number the same decision the same way.

## Current items

| # | Item | State |
|---|---|---|
| [0006](0006-pnpm-11-12-upgrade/spec.md) | pnpm 10 → 12 upgrade (config relocation is the real cost) | spec only, not scheduled |
| [0008](0008-venv-per-environment/spec.md) | One venv per environment — `.venv-sandbox` in every sandbox, `.venv` on every host | switch live in all four profiles; every flagged repo migrated by 2026-09-14; done-check blocked only on a sibling notice block in one repo → 0011 C1 |
| [0009](0009-agent-files-and-settings-hygiene/spec.md) | AGENTS.md as source + CLAUDE.md stub, and no committed local settings, across every repo | done 2026-09-12 — nine repos migrated, one recorded exception |
| [0010](0010-paperbridge-delivery/spec.md) | paperbridge delivery — one route for the library (git source vs hand-copied `dist/` wheel vs the unused channel wheel), and whether the image carries the CLI its skill describes | spec + plan; §4 unblock done 2026-09-13 (wearable_data_testing on paperbridge 0.3.0) |
| [0011](0011-sandbox-notice-global-homes/spec.md) | The sandbox notice — one neutral text, written into each agent's global home on every `up`/`converge`, never into a repo; strip the eight stale sibling blocks | spec + plan, checked 2026-09-14; C1 (the strip) is what closes 0008's last done-check line |

## Archived

| # | Item | Merged |
|---|---|---|
| [0001](archive/0001-port-from-windows-ai-sandbox/plan.md) | Port stable windows-ai-sandbox work forward to macolima | 2026-09-02 (`055fa9a`) |
| [0002](archive/0002-vendor-tools/plan.md) | Vendored tools and skills via the depot channel (V1–V3) | 2026-09-04 (`5e0331f`) |
| [0003](archive/0003-google-workspace-egress/plan.md) | `[google-workspace]` allowlist block for the Docs / Sheets APIs | 2026-09-04 |
| [0004](archive/0004-vendored-deployment/plan.md) | Deploying the vendored artifacts — wheel layer, skills convergence (V4–V5) | 2026-09-04 |
| [0005](archive/0005-w-parity-backlog/spec.md) | The windows-ai-sandbox parity backlog (P1–P11) | 2026-09-04 |
| [0007](archive/0007-agent-port-access/spec.md) | Host access to ports inside a profile — `ports:` is a no-op under `internal: true`; docs only | 2026-09-08 |

**Still live inside an archived item:** `0005` §3 "What W is owed back" (twelve
defects found in the sibling's code) and §8 "Still open" are the current
sibling-parity backlog. They stay there rather than being copied out — the
measurement context around them is what makes them checkable. See
`docs/sibling-repo-relationship.md` → "The live backlog in both directions".
