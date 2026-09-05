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

## Current items

_None in flight._

## Archived

| # | Item | Merged |
|---|---|---|
| [0001](archive/0001-port-from-windows-ai-sandbox/plan.md) | Port stable windows-ai-sandbox work forward to macolima | 2026-09-02 (`055fa9a`) |
| [0002](archive/0002-vendor-tools/plan.md) | Vendored tools and skills via the depot channel (V1–V3) | 2026-09-04 (`5e0331f`) |
| [0003](archive/0003-google-workspace-egress/plan.md) | `[google-workspace]` allowlist block for the Docs / Sheets APIs | 2026-09-04 |
| [0004](archive/0004-vendored-deployment/plan.md) | Deploying the vendored artifacts — wheel layer, skills convergence (V4–V5) | 2026-09-04 |
| [0005](archive/0005-w-parity-backlog/spec.md) | The windows-ai-sandbox parity backlog (P1–P11) | 2026-09-04 |

**Still live inside an archived item:** `0005` §3 "What W is owed back" (twelve
defects found in the sibling's code) and §8 "Still open" are the current
sibling-parity backlog. They stay there rather than being copied out — the
measurement context around them is what makes them checkable. See
`docs/sibling-repo-relationship.md` → "The live backlog in both directions".
