# work/0007 — host access to ports inside a profile

Status: **DONE 2026-09-08 — documentation only.** Raised while debugging a Vite
dev server in `therapod` that was reachable inside the container and not from
the Mac.

**Outcome: no code change was needed.** The access path already works —
`http://127.0.0.1:5173` on the Mac serves the container's dev server today, over
VS Code's forwarding. The defect was purely that three documents pointed at a
mechanism (`ports:`) that cannot fire here, sending users to debug a working
setup. Fixing the documents closes it.

## The defect

Three places told users to reach a container port by uncommenting or adding a
`ports:` block. All three are dead as written, and they fail silently:

| where | claim |
|---|---|
| `README.md` "Web UIs" | "For non-VS Code use, add a loopback port to the `claude-agent` service: `ports: ["127.0.0.1:8501:8501"]`" |
| `README.md` DB section | "For host GUI access (TablePlus, Compass), uncomment the `ports:` block on the relevant service" |
| `docker-compose.yml` (postgres, mongo) | "Uncomment to expose to host GUI tools" |

`sandbox-internal` is `internal: true` and every one of those services is
attached to it and nothing else. **Docker discards a published port on a
container attached only to an internal network** — no host binding, no warning,
no error.

## Measurement (2026-09-08)

Two identical containers, same image, same `-p 127.0.0.1:PORT:8000`:

| network | `docker ps` ports column | curl from the Mac |
|---|---|---|
| normal bridge (control) | `127.0.0.1:18174->8000/tcp` | **200** |
| `--internal` | `8000/tcp` — no mapping | connection refused |

The control also proves Colima forwards a published VM port through to Mac
loopback, so the VM layer was never the problem.

## Why the VS Code path works when `ports:` cannot

VS Code's attached-container forwarding does not use Docker networking at all.
It tunnels over the `docker exec` channel, so `internal: true` is not in the
path. Confirmed live: `lsof` shows `Code Helper` holding `127.0.0.1:5173` on the
Mac while `claude-agent-therapod` (172.30.0.2) serves Vite on `0.0.0.0:5173`,
with `172.30.0.2:5173` unreachable from the Mac.

Two corollaries the README now states:

- A `127.0.0.1` bind inside the container IS reachable by VS Code (the forwarder
  runs inside the container). `0.0.0.0` is advice for reliable AUTO-DETECTION,
  not a hard requirement. It is a hard requirement for `docker -p`, which is
  what makes the two cases easy to confuse.
- Fix the port. VS Code forwards the port you named, so a server that slides
  from 5173 to 5174 when the port is busy forwards nothing — the same symptom as
  a broken mapping.

Also worth recording, because it misleads: **`Attach to Running Container` never
reads a repo's `.devcontainer/devcontainer.json`** (already in README "VS Code
integration"). Permanent forwarding goes in the host-side attached-container
configuration file, which does support `forwardPorts`.

## The working non-VS Code option: a dual-homed relay

Verified working 2026-09-08 against the live Vite server: a relay container on
BOTH `sandbox-internal` and a normal bridge, publishing `127.0.0.1:18175:8080`
and forwarding to `172.30.0.2:5173`, returned 200 from the Mac.

Why this is not a hole: the relay carries **ingress only**. The agent stays
`internal: true` and gains no outbound path — it cannot dial the relay's bridge
side, and the relay initiates nothing on the agent's behalf. Compare attaching
a second network to `claude-agent` itself, which would hand the agent direct
internet and break the core invariant. Never do that.

## What was fixed

- `README.md` DB section — points at "Web UIs" and says why the commented blocks
  do not work.
- `README.md` "Web UIs" — the `ports:` advice replaced with the no-op warning,
  the measurement, the relay option, and the `0.0.0.0` / `strictPort` nuances.
- `docker-compose.yml` postgres + mongo — the "Uncomment to expose" comments now
  say the toggle is not sufficient and what it would actually take. The `ports:`
  blocks stay commented and unchanged.

## Closed, not open

An earlier draft of this item held the relay open as a possible compose profile
(`COMPOSE_PROFILES=relay`) with a `justfile` pass-through. **Not doing it.**
`127.0.0.1:5173` works from the Mac right now with no compose change at all, so
a relay service would add a container, an image decision, a port variable and a
lifecycle verb to duplicate a path that already works. It stays where it is —
a documented, measured pattern in the README for the day something needs host
access without VS Code attached. Reopen this item if that day arrives.
