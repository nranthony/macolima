# Squid egress proxy — internals

User-facing allowlist edits: see `proxy/allowed_domains.txt` and `README.md` §Updating. This page covers the why behind the config.

## Caps

Squid starts as root then drops to the `proxy` user — needs `SETUID` / `SETGID`. Without them: crash-loop exit 134. `NET_BIND_SERVICE` is NOT needed (port 3128 is unprivileged). Also `pinger_enable off` in `squid.conf` — ICMP pinger wants `CAP_NET_RAW` we don't grant.

## Split-phase tmpfs ownership

Root opens `/run/squid.pid` and `cache.log`; proxy user uid 13 writes `access.log` and the cache disk.

| tmpfs | owner/mode | why |
|---|---|---|
| `/var/spool/squid` | `proxy:proxy 0750` | Written only post-drop. |
| `/var/log/squid` | `root:proxy 0775` | `cache.log` opened by root, `access.log` by proxy — both need to write. |
| `/run` | default (root:root) | `/run/squid.pid` created by root. Don't add `uid=13` here or PID write fails. |

Changes only re-apply on `--force-recreate` (not restart). Symptoms map to phase: `Cannot open '...access.log'` = log tmpfs wrong; `failed to open /run/squid.pid` = `/run` was made non-root-writable.

## Port-restrict non-CONNECT methods

`acl Safe_ports port 80 443` + `http_access deny !Safe_ports`. Without that, `http_access allow allowed_domains` forwards GET/POST to **any** port on allowed hosts (e.g. `GET http://api.anthropic.com:22/`). For a different non-443 port, add it to `Safe_ports`, not just to `allowed_domains.txt`.

## CONNECT restricted to port 443

The rule order:

```
http_access deny !Safe_ports                  # blocks every method on non-{80,443}
http_access deny CONNECT !SSL_ports           # blocks CONNECT on anything but 443 (audit H1)
http_access allow CONNECT SSL_ports allowed_domains
http_access allow allowed_domains
http_access deny all
```

The `deny CONNECT !SSL_ports` line is load-bearing. Without it, the `allow allowed_domains` rule (which doesn't bind on method) would match `CONNECT api.anthropic.com:80` and tunnel raw TCP on cleartext port 80 — the bug surfaced by audit H1. **Do not delete that line.** `verify-sandbox.sh` includes a probe that POSTs `CONNECT … :80/` through the proxy and expects 4xx; a regression here trips it.

## Avoid wildcards under vendor parents you don't control

Default autonomous-mode allowlist lists specific subdomains (`api.anthropic.com`, `console.anthropic.com`, `statsig.anthropic.com`, `api.claude.com`, `claude.ai`) rather than `.anthropic.com` / `.claude.ai`. Wildcards are an exfil channel any time a vendor adds a user-controllable subdomain (status pages, marketing, hosted docs). When a new subdomain 403s, tail the access log to find it.

`.vscode-unpkg.net` stays a wildcard because the VS Code extension fetcher legitimately rotates across many subdomains under that single MS-controlled parent.

## Access log

Tmpfs-backed `proxy:proxy 0640` — forensic trail of every request, resets on `--force-recreate`. Read as the proxy user (see `docs/debug-recipes.md`). For long-term retention, add a second `access_log` directive pointing at a host-bind-mounted file with `proxy` write access.

## Hot reload

Allowlist changes — preferred path is `docker exec egress-proxy-<p> squid -k reconfigure` (zero-downtime; squid validates the new config and keeps the old one running if it has a syntax error). The dashboard (`dashboard/`) and `scripts/with-egress.sh` both use this. Fall back to `COMPOSE_PROJECT_NAME=macolima-<p> PROFILE=<p> docker compose restart egress-proxy` only when the container is unhealthy.

**Caveat — `reconfigure` exit 0 is not proof the allowlist was read.** It
validates *syntax*, not that the ACL file was reachable: an unreadable
`allowed_domains.txt` logs `ERROR: Can not open file` + `WARNING: empty ACL` and
**still exits 0**. Check the log output, not the exit code. The directory mount
below removes the usual cause; this caveat remains because the exit code is
still not a reliable signal on its own.

## Allowlist is a DIRECTORY mount, not a file mount (work/0001 A2)

`proxy/` is mounted at `/etc/squid/host/`, and `squid.conf` reads the allowlist
from `/etc/squid/host/allowed_domains.txt`. This is load-bearing, not tidiness.

**The failure it prevents.** A single-file bind mount resolves to an inode
**once**, at container start. Anything that replaces the host file rather than
truncating it in place — `git checkout`/`merge`/`pull`/`stash`, `vim`, `sed -i`
— leaves the container pinned to the old, orphaned inode. From then on the
container cannot see host edits at all, and the repo's allowlist is **advisory,
not authoritative**: tightening it in git has no effect on the running proxy.

**It is silent, which is the dangerous part.** Reproduced here 2026-08-31
before the fix, by renaming a new file over the old one:

```
ERROR: Can not open file /etc/squid/allowed_domains.txt for reading
WARNING: empty ACL: acl allowed_domains dstdomain "/etc/squid/allowed_domains.txt"
```

…and `squid -k reconfigure` **still exited 0**. The documented reload procedure
reports success while the proxy is running on a config it could not read.

**Both failure directions are possible, and one is much worse:**

| Shape | Result |
|---|---|
| Mount breaks entirely (rename, as reproduced here) | empty `dstdomain` ACL matches nothing → **fails closed**, all egress dies. Loud, but only once someone tries to use it. |
| Stale inode still holds the older file (W's two incidents) | proxy keeps enforcing the **older, more permissive** allowlist → **fails open**. A domain you gated in git is still tunnelling. |

**Why it stayed hidden here:** the dashboard writer opens the file with `"w"` —
truncate in place, inode preserved — so the most frequent editor of the
allowlist never trips it. Git operations, which are rarer and more
consequential, do.

**Rules.** Mount at a **sub-path**; never overmount `/etc/squid` wholesale, the
image keeps `errorpage.css` and `conf.d/` there. If you change the in-container
path, change the mount target in `docker-compose.yml` in the same commit — they
are the only two places that spell it.

**Verification that the mount is live** (not a stale inode): edit the host file
by replacement, then read it back from inside the container without restarting.

```sh
{ cat proxy/allowed_domains.txt; echo "# probe"; } > /tmp/ad && mv /tmp/ad proxy/allowed_domains.txt
docker exec egress-proxy-<p> grep -c '^# probe' /etc/squid/host/allowed_domains.txt   # must be 1
```
