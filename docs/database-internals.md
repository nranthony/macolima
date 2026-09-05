# Database sibling containers — internals

User-facing usage lives in `README.md` §Databases. This page covers the editing-time gotchas.

## First-init lock-in

`POSTGRES_USER` / `POSTGRES_PASSWORD` (and `MONGO_INITDB_ROOT_*`) are only consumed by `initdb` on the **first** boot of the DB container, when the named volume is empty. Editing `db.env` afterwards does not change the role inside the running DB. `POSTGRES_DB` is deliberately not set — the default `postgres` database is created automatically, and project databases should be created explicitly with `CREATE DATABASE <name> OWNER agent;`.

To rotate later:
- `ALTER USER ... WITH PASSWORD '...';`, or
- `docker volume rm macolima-<p>_postgres-data` and re-up (destroys data).

## Project-specific DSNs

`WEARDATA_PG_DSN`, `DATABASE_URL`, etc. — define alongside `POSTGRES_*` in `db.env`. The DSN's password component must match `POSTGRES_PASSWORD`; URL-encode reserved chars (`/` → `%2F`, `@` → `%40`, `:` → `%3A`), or sidestep with `openssl rand -hex 24`. Hostname inside the sandbox is `postgres`, never `localhost`.

**`env_file` is read at container *create* only** — adding/editing a var in `db.env` after the agent is up does not propagate on `restart` or plain `up`. Force-recreate the agent:

```bash
COMPOSE_PROFILES=db-postgres PROFILE=<p> docker compose -p macolima-<p> up -d --force-recreate claude-agent
```

Then re-attach VS Code (container ID changes).

## Why named volumes, not bind mounts

Postgres/Mongo do lots of `fsync` / `rename` / `chmod` and rely on UID 999 ownership. Virtiofs bind mounts from macOS get this wrong. For host-visible backups, `pg_dump` / `mongodump` into `/workspace` (the one bind mount that survives VM rebuild).

## Don't connect the sandbox to host DBs

Allowlisting `host.docker.internal` puts a routable path from the agent to services holding real data on your Mac — exactly the coupling the sandbox exists to prevent. If you need real data, dump a subset into the sibling container.

## Postgres 18 mount path

Keep the compose mount as `postgres-data:/var/lib/postgresql:rw` (NOT `.../data`). pg 18+ manages a major-version subdirectory inside `/var/lib/postgresql` for `pg_upgrade --link`; mounting the old `.../data` path makes the entrypoint refuse to start. Wipe a volume initialized under the old path before re-up.

## DB caps are dropped, not default

Both `postgres` and `mongo` services run with `cap_drop: ALL` + `cap_add: [CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID]` — the four the entrypoints actually need (chown the data dir on init, drop privs from root → postgres / mongodb). Don't fall back to the default Docker cap set "for safety"; the default includes `CAP_NET_RAW`, which is never needed here and is a soft landing pad if the agent's superuser creds get misused (the `docs/_future/db-least-privilege-plan.md` split is the upstream fix for that misuse vector).

## `db.env` permissions

Auto-chmod'd to 600 by `profile.sh`'s `ensure_state()` on every `up`. Older profiles created before audit L1 ran with 644 self-heal on next `up`; the file is also re-asserted as 600 every time, so manual edits that loosen perms are corrected. The companion `db.env.example` template stays 644 (it's not a secret). Don't remove the chmod — `db.env` carries the DB superuser password.

## Per-profile API keys

`db.env` is not the only optional `env_file` on the agent. A second one,
`secrets.env`, carries third-party API tokens for tooling baked into the image —
today that means `CLICKUP_TOKEN` for the vendored `myclickup` CLI. It lives at
`/V/.../profiles/<p>/secrets.env`, is seeded as `secrets.env.example` from
`sandbox_templates/common/secrets.env.template` on every `up`, chmod 600'd by
`ensure_state`, and preserved by `wipe`. It is documented here rather than in its
own file because every mechanical property it has is a property `db.env` already
had — including the one below.

```bash
cp sandbox_templates/common/secrets.env.template \
   /Volumes/DataDrive/.claude-colima/profiles/<p>/secrets.env
$EDITOR /Volumes/DataDrive/.claude-colima/profiles/<p>/secrets.env
scripts/profile.sh <p> recreate      # NOT `up` — see the create-only note above
```

The agent never sees the file: it is not bind-mounted anywhere, so only the
variables surface inside the container.

### A key needs a host, and a host needs the right tier

A key with no matching entry in `proxy/allowed_domains.txt` fails as a Squid
`TCP_DENIED`/403. That does not read as "missing allowlist entry" unless you look
at the access log — it reads like a bad token. Add the host in the same change as
the key.

### `SANDBOX_PROFILE` is a contract, not a duplicate of `MACOLIMA_PROFILE`

Compose sets both on the agent, and they answer different questions.
`MACOLIMA_PROFILE` is this repo's own name, read by `scripts/audit/aggregate.py`,
the `audit-sandbox` skill and `run-ephemeral.sh`. `SANDBOX_PROFILE` is the
CROSS-REPO name that vendored tools key on to know they are inside a sandbox.

That is not a convention — it is a literal string comparison in tools this repo
does not own. `myclickup`'s `config.in_sandbox()` is exactly
`"SANDBOX_PROFILE" in env`, and when it returns false the tool merges a repo-root
`.env` beneath the real environment. `/workspace` is agent-writable, so without
this variable a file the agent can create becomes a credential source — precisely
what myclickup's ADR-0003 disables inside a sandbox. This repo set only
`MACOLIMA_PROFILE` until work/0004, so that fallback was live here.

Set both when adding a service. Do not "tidy" one away.

## TODO — least-privilege split

The agent currently holds DB admin creds via `db.env`. See `docs/_future/db-least-privilege-plan.md`.
