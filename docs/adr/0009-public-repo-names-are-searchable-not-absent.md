# ADR-0009 — In a public repo, a private name is searchable, not absent

- **Status:** Accepted (2026-09-03)
- **Deciders:** nranthony + agent

## Context

This repo is public. Profile names are not neutral tokens — they are clients,
projects and people. A profile name reaching a commit is not merely untidy: it
is published, and it stays published in the history after it is removed from the
tip.

The names cannot be listed in the repo that must not contain them. Any check has
to read its subject list from somewhere untracked.

## Decision

`scripts/private-names-check.sh` reads `.private-names.local` — untracked, one
name per line — and fails the offline suite if any name appears in a tracked
file **or in a tracked path**.

- **Paths are scanned, not just contents.** A tracked filename is at least as
  searchable as a line inside a file, and a per-profile compose overlay named
  after its profile is the obvious way to leak one.
- **Absent config SKIPs loudly and exits 0**, printing the command to create the
  file. A silent skip would mean the check never runs on a fresh clone and
  nobody notices; a hard failure would mean every contributor without the file
  is blocked.

## Consequences

- The gate found **13 surfaces on its first run** — evidence that the
  no-private-names practice had been followed by intent rather than by
  enforcement.
- `.private-names.local` must stay untracked, and the check must never print the
  names it is looking for into any output that could be committed.
- Per-profile compose overlays are currently scoped **out** of the check, with
  the reason recorded rather than silently excluded. Whether to keep tracking
  them at all is still open.
