# work/ — in-flight implementation artifacts

One folder per work item, `NNNN-slug/`, holding `spec.md` (what/why) → `plan.md`
(design + ordered steps) → `notes.md` (execution log). Convention borrowed from
`windows-ai-sandbox` (its ADR-0001, provenance tiers).

**Exit rule:** when a work item's changes merge, delete its folder or move it to
`docs/_archive/`. A stale `plan.md` reads as current intent long after it stopped
being true. The root-level `MACOLIMA_in-transit_*.md` files are the worked example
of what this directory replaces.

## Current items

| # | Item | Status |
|---|---|---|
| [0001](0001-port-from-windows-ai-sandbox/plan.md) | Port stable windows-ai-sandbox work forward to macolima | Planned 2026-08-23, not started — needs macOS host |
