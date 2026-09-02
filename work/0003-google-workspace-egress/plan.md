# work/0003 — Google Docs / Sheets API egress

Branch: `dev/0002-vendor-tools` (small, self-contained; not worth its own branch).

## Ask

Allow the agent to reach Google Docs and Sheets **via the API**, under a
properly tagged allowlist block, and fix whatever else in the repo needs to know
about a new block.

## What the hosts actually are

| host | why | state |
|---|---|---|
| `docs.googleapis.com` | Google Docs API v1 | **new** |
| `sheets.googleapis.com` | Google Sheets API v4 | **new** |
| `oauth2.googleapis.com` | OAuth token exchange | **already ALWAYS ON** under `[antigravity]` |
| `www.googleapis.com` | Drive API v3 (`/drive/v3/files`) + discovery | **already ALWAYS ON** under `[antigravity]` |

`docs.googleapis.com` was flagged for checking and is correct — verified
2026-09-02 against the live endpoints rather than assumed:

```
docs.googleapis.com/v1/documents/<id>       -> 401   (exists, needs auth)
sheets.googleapis.com/v4/spreadsheets/<id>  -> 403   (exists, needs auth)
```

Note the distinction from `windows-ai-sandbox`, which lists `docs.google.com`
and `drive.google.com` — those are the **web UIs**, for a human in a browser.
The API surface is the `*.googleapis.com` set above. Different hosts, different
purpose; this repo wants the API ones.

**Only two lines are actually added.** `oauth2` and `www.googleapis.com` are
deliberately NOT repeated in the new block: a duplicate makes a future removal
from one block look effective while the other still permits the host.

## Decisions

**Tag name: `[google-workspace]`.** More general than "google docs", covers
Sheets and Drive as they arrive, and matches the tag W already uses — so the two
repos stay greppable with the same string.

**Tier: PROJECT-PERSISTENT, commented by default.** It needs OAuth credentials
in the profile before it does anything, so it enters the file the way every
other project capability does (`[wearables]`, `[archive]`, `[github-raw]`).
Uncomment for the duration of the work, recomment after.

**No wildcard.** `.googleapis.com` fronts every Google API — Vertex, GCS, IAM,
the lot. Pinned hosts only, per `CLAUDE.md`.

## Work

1. `proxy/allowed_domains.txt` — add the `[google-workspace]` block at the end of
   PROJECT-PERSISTENT, commented, with the note about the two already-present
   hosts.
2. `dashboard/src/lib/proxy_categories.py` — **required, not cosmetic.** A tag
   absent from `CATEGORY_TAGS` falls into "Other", and
   `dashboard/tests/test_allowlist_roundtrip.py` asserts no live tag lands
   there. That check exists precisely so a new block forces a deliberate
   one-line decision instead of accumulating in the junk drawer — so it will
   fail until the tag is mapped. Adds a sixth category, "Productivity &
   Google Workspace" (W's name), which also reserves the slot for `clickup`
   when `myclickup`'s egress lands (work/0002 V7).
3. Verify: `just test-dashboard`, `just test-offline`, and `just verify <p>`
   (the allowlist parsers are locked by `with-egress.test.sh`; the enforcement
   probe re-reads the file).

## Not changing

- `README.md` and `docs/squid-internals.md` — both cover the *why* of the proxy
  config and the edit/reload procedure. Neither enumerates blocks, so neither
  goes stale from adding one.
- `docs/local-wheels.md`, `scripts/depaudit.py` — they match a grep for
  `paperbridge`, but as a *Python package*, not an allowlist tag.
- `CLAUDE.md` — its checklist item ("New allowed domain? Justify with a one-line
  comment above its block") is satisfied by doing the thing, not by editing it.
