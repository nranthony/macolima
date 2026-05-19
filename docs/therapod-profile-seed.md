# Therapod profile — database setup and pipeline run

Setup steps for the therapod profile's two Postgres databases and the ECG pipeline. Assumes the macolima stack is already running with `COMPOSE_PROFILES=db-postgres`.

All commands below run **inside the agent container** (`scripts/profile.sh therapod attach`) unless marked "host:".

## Prerequisites

- Colima VM running, therapod stack up with postgres:
  ```bash
  # host:
  COMPOSE_PROFILES=db-postgres scripts/profile.sh therapod up
  ```
- `db.env` in place with `POSTGRES_USER=agent`, `POSTGRES_PASSWORD=<hex>`, and the three DSN vars (`WEARDATA_PG_DSN`, `PIPELINE_PG_DSN`, `DATABASE_URL`). See `config/db.env.template` for the shape.
- `.venv-linux` built in both `/workspace/wearable_data_testing` and `/workspace/pipeline`.

## 1. Create project databases

The default `postgres` database exists automatically. Project databases must be created explicitly:

```bash
psql -U agent -d postgres -c 'CREATE DATABASE wearables_ref OWNER agent;'
psql -U agent -d postgres -c 'CREATE DATABASE pipeline OWNER agent;'
```

Verify:
```bash
psql -U agent -d postgres -c '\l'
```

## 2. Wearables reference data (fast — seconds)

Source of truth is CSV files in `wearable_data_testing/data/reference/`. The seeder is idempotent.

```bash
cd /workspace/wearable_data_testing

# Apply schema (creates all tables — must run before seed or migrations)
psql "$WEARDATA_PG_DSN" -f db/schema.sql

# Seed from CSVs (upsert — safe to re-run)
.venv-linux/bin/python -m weardata.reference.seed
```

Sanity check (tables live in the `wearables_ref` schema, not `public`):
```bash
psql "$WEARDATA_PG_DSN" -c 'SELECT count(*) FROM wearables_ref.signals;'
# expect: 62
psql "$WEARDATA_PG_DSN" -c 'SELECT count(*) FROM wearables_ref.devices;'
# expect: ~45
```

**Migrations** (`db/migrations/001_*.sql` through `003_*.sql`) are only needed when upgrading an existing database created from an older `schema.sql`. On a fresh install, `schema.sql` is the consolidated current state and already includes everything the migrations add — running them is a harmless no-op (every ALTER shows `already exists, skipping`).

## 3. Pipeline database schema

Alembic manages the pipeline schema. `DATABASE_URL` must be set in the environment (comes from `db.env`).

```bash
cd /workspace/pipeline
.venv-linux/bin/alembic upgrade head
```

Verify:
```bash
psql "$PIPELINE_PG_DSN" -c '\dt'
# expect: users, sessions, event_log, gold_manifests, live_session_state, etc.
```

## 4. Run the H10 backfill pipeline (slow — minutes)

This replays 24 Polar H10 participants through the full Bronze/Silver/Gold stack. Raw source parquet files live at `raw_data/wearable_data/polar-h10/GalaxyPPG/` (inside `/workspace`, i.e. the therapod repo root).

```bash
cd /workspace/pipeline
.venv-linux/bin/python scripts/run_pipeline_h10.py \
    --participants 1-24 \
    --data-dir data/dev \
    --intent baseline
```

The `--reset` flag drops and recreates tables inside the `pipeline` database before running. Use it for a clean re-run; omit it to append to existing data.

### What the pipeline produces

| Tier | Path | Content |
|------|------|---------|
| Bronze | `data/dev/bronze/user_id=.../session_id=.../date=.../channel=ecg/` | Raw ECG chunks (~3,900 parquet files per 65-min session) |
| Silver | `data/dev/silver/beats/0/session_id=.../` | Per-beat R-peak events (one parquet file per session) |
| Gold | `data/dev/gold/features/0/session_id=.../` | Tumbling-window metrics: RMSSD, SDNN, pNN50, LF/HF, breathing rate, RSA |

Postgres `pipeline` database receives: session rows, event log entries, gold manifest pointers, and live session state UPSERTs.

### Verify

```bash
.venv-linux/bin/python scripts/verify_pipeline_run.py
# checks: SMOKE (artifacts exist), PLAUSIBILITY (medians in healthy bands), THROUGHPUT
```

## Clean wipe and redo (db-reset)

When you need to start fresh — corrupt state, schema drift, or just want a clean baseline:

```bash
# host:
scripts/profile.sh therapod db-reset
```

This wipes the postgres data volume and brings postgres back with a fresh initdb. Then repeat steps 1-4 above from inside the agent container.

To also wipe the parquet output (data plane), remove `data/dev/` from inside the container:
```bash
rm -rf /workspace/pipeline/data/dev
```

## Contracts between the two databases

- `device_id` slugs in `wearables_ref.devices` (e.g. `polar_h10`) must match `pipeline.sessions.device_id`. Don't rename in one without the other.
- Metric names in `wearables_ref.metrics.name` (rmssd, sdnn, pnn50, etc.) must match column semantics in `pipeline.gold_manifests` / gold parquet.

## DSN reference

From `db.env` (password will differ per profile):

| Var | Database | Used by |
|-----|----------|---------|
| `WEARDATA_PG_DSN` | `wearables_ref` | `weardata.reference.seed`, CSV loader, reference queries |
| `PIPELINE_PG_DSN` | `pipeline` | Pipeline storage layer (`pipeline.storage.db`) |
| `DATABASE_URL` | `pipeline` | Alembic (`alembic.ini` reads it), FastAPI app |
