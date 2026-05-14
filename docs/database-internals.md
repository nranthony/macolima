# Database sibling containers — internals

User-facing usage lives in `README.md` §Databases. This page covers the editing-time gotchas.

## First-init lock-in

`POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` (and `MONGO_INITDB_ROOT_*`) are only consumed by `initdb` on the **first** boot of the DB container, when the named volume is empty. Editing `db.env` afterwards does not change the role inside the running DB.

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

Both `postgres` and `mongo` services run with `cap_drop: ALL` + `cap_add: [CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID]` — the four the entrypoints actually need (chown the data dir on init, drop privs from root → postgres / mongodb). Don't fall back to the default Docker cap set "for safety"; the default includes `CAP_NET_RAW`, which is never needed here and is a soft landing pad if the agent's superuser creds get misused (the `TODO.md` least-privilege split is the upstream fix for that misuse vector).

## `db.env` permissions

Auto-chmod'd to 600 by `profile.sh`'s `ensure_state()` on every `up`. Older profiles created before audit L1 ran with 644 self-heal on next `up`; the file is also re-asserted as 600 every time, so manual edits that loosen perms are corrected. The companion `db.env.example` template stays 644 (it's not a secret). Don't remove the chmod — `db.env` carries the DB superuser password.

## TODO — least-privilege split

The agent currently holds DB admin creds via `db.env`. See `TODO.md`.
