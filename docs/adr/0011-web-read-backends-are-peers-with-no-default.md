# ADR-0011 — Web-read backends are peers; `--via` is required and there is no default

- **Status:** Accepted (2026-09-03)
- **Deciders:** nranthony + agent

## Context

The `webfetch` broker fronts several hosted reader APIs. The natural design is a
default backend with the others as fallbacks.

That design failed in a live profile. Tavily returned **HTTP 432** — a quota
wall — and because it was the implicit default, the agent read the result as
*the web is unreachable* and stopped. Three other backends were configured and
working at that moment. A vendor's quota wall had become an outage of the whole
capability.

## Decision

**`--via <backend>` is required. There is no default and no automatic
fallback chain.**

- `webfetch backends` lists every backend and whether it is usable in this
  profile.
- The agent picks one, and **on any failure exit code moves to another** before
  concluding a page cannot be read.
- Only when every backend has failed is it a human step — and then the report
  carries the exit codes.

## Consequences

- One vendor's outage, quota wall, missing key or empty result can no longer
  present as "the web is unreachable".
- The cost is one required flag, paid on every call, in exchange for removing a
  failure mode that is invisible precisely when it matters.
- The agent notice states the switch-don't-stop rule explicitly, because the
  correct behaviour is not inferable from an error message.
