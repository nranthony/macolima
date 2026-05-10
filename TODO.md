# TODO

## Agent currently holds DB admin creds — least-privilege split

`db.env` injects `POSTGRES_USER`/`POSTGRES_PASSWORD` and `MONGO_INITDB_ROOT_*` into the `claude-agent` container as ambient env. That's the DB **superuser**, so the agent can DROP tables/databases/collections. Fine for throwaway dev DBs, wrong for anything holding real data.

**Trigger** — execute this plan before this profile starts:

- holding identifiable PII or production data,
- mounting an exported real dataset,
- being shared with another sandbox or host process,
- or anything else where `DROP TABLE` would be more than mildly inconvenient.

Today's DBs are dev throwaway, so the plan below is staged-but-not-executed. The decisions are locked; execute when triggered.

### Already in place (adjacent, NOT a substitute)

The 2026-05-07/08 security audit added two layers around this hole. They reduce blast radius but **do not** close the TODO — the agent still receives superuser creds in env and can still issue `DROP TABLE`/`DROP DATABASE` over a normal SQL connection.

- **`cap_drop: ALL` + minimal `cap_add` on postgres/mongo** (`docker-compose.yml`). Limits what the *DB process* can do at the kernel level if compromised (no `CAP_NET_RAW`, etc.). Orthogonal to who-holds-what-creds.
- **`chmod 600` on `db.env`** auto-asserted by `profile.sh ensure_state` on every `up`. Protects the file at rest on the host filesystem from other host-side processes. Doesn't change what the agent sees inside the container.

### Plan (ready to execute when triggered)

#### Decisions locked in

- **`agent_rw` is CRUD-only**, not DDL. Migrations and schema changes are one-off operations that should run under a separate elevated role, not the everyday agent role. CRUD covers `SELECT`/`INSERT`/`UPDATE`/`DELETE` on tables and `USAGE`/`SELECT` on sequences. The DDL toggle is documented in the script but commented out.
- **Two env files** (the prior draft's "Option A"). `db.env` holds admin creds, read by postgres/mongo only. `db-agent.env` holds CRUD creds + per-project DSNs, read by claude-agent only. Cleaner than per-key unsetting and less confusing than a "set then unset" pattern.

#### Files to add

```
dbinit/
├── postgres/
│   ├── 01-agent-rw.sh        # initdb-time, runs on first DB boot
│   └── 01-agent-rw.sql       # standalone, for hand-running on existing volumes
└── mongo/
    ├── 01-agent-rw.js        # initdb-time
    └── 01-agent-rw.live.js   # standalone (same content; symlink or duplicate)
```

`01-agent-rw.sh` (postgres):

```bash
#!/bin/bash
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  CREATE ROLE agent_rw LOGIN PASSWORD '$POSTGRES_AGENT_PASSWORD';
  GRANT CONNECT ON DATABASE $POSTGRES_DB TO agent_rw;
  GRANT USAGE ON SCHEMA public TO agent_rw;
  -- CRUD-only on existing + future tables in public schema.
  GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO agent_rw;
  GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO agent_rw;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO agent_rw;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO agent_rw;
  -- DDL toggle (uncomment ONLY if a project genuinely needs migrations
  -- under agent_rw — prefer a separate elevated role for migrations):
  -- GRANT CREATE ON SCHEMA public TO agent_rw;
EOSQL
```

`01-agent-rw.js` (mongo):

```javascript
db = db.getSiblingDB(process.env.MONGO_INITDB_DATABASE || 'app');
db.createUser({
  user: process.env.MONGO_AGENT_USER,
  pwd:  process.env.MONGO_AGENT_PASSWORD,
  roles: [{ role: 'readWrite', db: process.env.MONGO_INITDB_DATABASE || 'app' }],
});
```

#### Compose wiring

```yaml
postgres:
  volumes:
    - postgres-data:/var/lib/postgresql:rw
    - ./dbinit/postgres:/docker-entrypoint-initdb.d:ro
  env_file:
    - profiles/${PROFILE}/db.env       # admin only

mongo:
  volumes:
    - mongo-data:/data/db:rw
    - ./dbinit/mongo:/docker-entrypoint-initdb.d:ro
  env_file:
    - profiles/${PROFILE}/db.env       # admin only

claude-agent:
  env_file:
    - profiles/${PROFILE}/db-agent.env # CRUD + per-project DSNs only
```

#### Env file split

- `db.env` (existing, scope reduced) — admin only:
  `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`,
  `POSTGRES_AGENT_USER`, `POSTGRES_AGENT_PASSWORD`,
  `MONGO_INITDB_ROOT_USERNAME`, `MONGO_INITDB_ROOT_PASSWORD`,
  `MONGO_INITDB_DATABASE`,
  `MONGO_AGENT_USER`, `MONGO_AGENT_PASSWORD`.
  Read by postgres + mongo only.
- `db-agent.env` (new) — CRUD + DSNs only:
  `POSTGRES_AGENT_USER`/`POSTGRES_AGENT_PASSWORD`,
  `MONGO_AGENT_USER`/`MONGO_AGENT_PASSWORD`,
  per-project DSNs (e.g. `DATABASE_URL=postgresql://agent_rw:...@postgres:5432/dev`).
  Read by claude-agent only.

#### Migration script

`scripts/migrate-db-env.sh <profile>` — idempotent one-shot that splits an existing `db.env` into the new pair using `awk`. Backs up the original to `db.env.pre-split`. Run once per pre-split profile when triggered.

#### Required changes elsewhere

- `db.env.example` — split into `db.env.example` (admin) + `db-agent.env.example` (agent). Keep both at chmod 644 (templates aren't secrets).
- `profile.sh ensure_state` — chmod 600 both files; seed both examples on first `up`. If only `db.env` exists from a pre-split profile, point at `migrate-db-env.sh` in the message.
- `README.md §Databases` — update the cp-edit-up flow for the file pair; document that DSNs in `db-agent.env` should reference `agent_rw`, not the superuser.
- `CLAUDE.md §Databases` — flip the "agent currently holds DB admin creds" caveat to "agent holds CRUD-only creds; admin only in db.env consumed by DB containers." Update the "first-init lock-in" note to mention the initdb scripts.

#### First-init lock-in

`/docker-entrypoint-initdb.d/` only runs on the **first** boot of each DB container, when the named volume is empty. Existing profiles with already-initialized postgres/mongo don't get the agent_rw role automatically.

Two migration paths:

1. **Wipe + re-init (clean, lossy)** — default for dev profiles:
   ```
   scripts/profile.sh <p> wipe --all-volumes
   COMPOSE_PROFILES=db-all scripts/profile.sh <p> up
   ```
   Loses all DB data.

2. **Hand-run on the live DB (lossless)** — for profiles already holding data:
   ```
   docker exec -i postgres-<p> psql -U <admin> <db> < dbinit/postgres/01-agent-rw.sql
   docker exec -i mongo-<p> mongosh -u <admin> -p < dbinit/mongo/01-agent-rw.live.js
   ```

Default the README example to (1); flag (2) for anything with data worth keeping.

#### Verification (add to verify-sandbox.sh — DB-up branch)

When DB siblings are up:

- Connect from agent as `$POSTGRES_USER` (admin) — should fail with "role does not exist" or auth failure (the agent's env has the agent_rw user, not the admin).
- Connect as `$POSTGRES_AGENT_USER` and verify `SELECT` works but `CREATE TABLE` / `DROP TABLE` fails with permission denied.
- Mongo: attempt `db.dropDatabase()` as the agent's user — expect refusal.

Makes the least-privilege posture self-asserting on every `--force-recreate`.

#### Estimated effort

~1 hour focused: 30 min for initdb scripts + compose wiring + env split + migrate-db-env.sh, 15 min for verify-sandbox additions, 15 min for docs (README + CLAUDE.md).
