# ADR-0012 — A web-read backend gets its READ hosts allowlisted, and nothing else

- **Status:** Accepted (2026-09-03)
- **Deciders:** nranthony + agent

## Context

The whole point of the broker ([ADR-0003](0003-strict-egress-default.md)) is
that arbitrary-URL fetching happens on the vendor's infrastructure so this
sandbox's egress surface does not grow with the pages read.

That property survives only if the allowlisted hosts are *read* endpoints.
TinyFish is the worked example: the same API key that unlocks its Search and
Fetch APIs also unlocks its Agent and Browser APIs and an MCP server — a cloud
browser the model steers. That is a **write surface**: logins, form-fills,
arbitrary POSTs.

## Decision

Only a backend's **read** hosts go in the `[web-read]` block. The broker never
calls the write hosts, and `scripts/webfetch.test.sh` locks **both** facts:
every host the broker names must be an exact live allowlist line, and the
write-surface hosts must not be.

Concretely: `api.search.tinyfish.ai` and `api.fetch.tinyfish.ai` are
allowlisted; `agent.tinyfish.ai` is not.

## Consequences

- **Do not "connect" a broker vendor's MCP server inside a profile** to reach
  the richer APIs. The vendor's own onboarding one-liner is a fetch-and-run form
  the sandbox denies by name, and it also puts the key on argv.
- **Do not add a vendor wildcard.** A wildcard cannot distinguish a read host
  from a write host, which is the entire distinction this ADR rests on.
- Keys travel in headers, never in argv or a URL — Squid logs URLs.
- Adding a backend is therefore three coordinated edits (broker, allowlist,
  test) and the test fails offline if they disagree — rather than surfacing as a
  `TCP_DENIED` that reads like a bad key.
