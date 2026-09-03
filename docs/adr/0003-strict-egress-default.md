# ADR-0003 — Egress is default-deny, and the default stays deny

- **Status:** Accepted (2026-09-03; the practice long predates the record)
- **Deciders:** nranthony + agent

## Context

The agent container has no direct network at all: `sandbox-internal` is
`internal: true`, DNS is sinkholed to `127.0.0.1`, and the only reachable host
is the Squid sidecar. Everything the agent can reach is therefore exactly what
`proxy/allowed_domains.txt` names.

That file is a security boundary that reads like a config file, which is the
whole problem. Every host added to it is not only a place the agent can *read*
from — it is a place the agent can **POST to**. An allowlist grown for
convenience is an exfiltration surface grown for convenience, and the growth is
invisible because each individual addition looks reasonable.

## Decision

1. **Default-deny.** A host is unreachable unless a line names it. Package
   registries (PyPI, npm, PyTorch) are **closed by default**, so dependency
   installs fail at the network even where no rule denies the command.
2. **Leaf hosts, not wildcards.** No `.example.com` entries. The sole exception
   is `.vscode-unpkg.net`, a vendor-controlled CDN that legitimately rotates
   subdomains. The audit probe reports any other leading-dot entry as **DRIFT**,
   not INFO.
3. **Every block carries a one-line justification** above it and a `[tag]`
   matching `[a-z-]+` — a dot or digit makes the block invisible to
   `with-egress.sh` while looking correct in the file.
4. **Temporary need gets a window, not a line.** `scripts/with-egress.sh --with
   <tag>` opens a tagged block, hot-reloads Squid, runs one command, restores
   the file verbatim and writes an audit record. Permanent entries are for
   permanent needs.
5. **Reading the file is not reading the policy.** Squid enforces what it was
   last reloaded with. An edit needs `squid -k reconfigure` before it is real.

## Consequences

- **Installs are a human step.** There is no flag the agent can pass and no
  command it can find. The agent notice says so explicitly, because an agent
  that believes a workaround exists will spend turns looking for one.
- **A blocked host is the allowlist working**, not a fault to diagnose. The
  failure presents as a connection error rather than a 404, which reads like a
  bad key — so the notice names that symptom directly.
- **Reading the open web needed a different answer entirely.** Widening the
  allowlist to the dozens of research, news, PDF and UGC domains a verification
  pass wants would have inverted this ADR. The `webfetch` broker exists so the
  arbitrary-URL fetch happens on someone else's infrastructure — see
  [ADR-0011](0011-web-read-backends-are-peers-with-no-default.md) and
  [ADR-0012](0012-web-read-backends-get-read-hosts-only.md).
- **Owner-opened blocks are legitimate and must not read as leaks.** The audit
  probe distinguishes a deliberate always-on opening from drift; without that,
  the check cries wolf on the owner's own working state and gets ignored.
