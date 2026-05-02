# macolima control dashboard — design plan

Source-of-truth for current invariants is `CLAUDE.md`. This file is a deferred
implementation plan for a **Streamlit-based control dashboard** that surfaces
status and runs lifecycle commands against the multi-profile sandbox stack.
Not yet implemented as of 2026-04-27.

## Context — why

Today, every operation goes through `scripts/setup.sh` and `scripts/profile.sh`
in a terminal. That works, but it has friction:

- No at-a-glance view of which profiles exist, which are up, which need re-auth,
  and what their resource usage / state-dir size is.
- Allowlist edits (`proxy/allowed_domains.txt`) require remembering the exact
  `docker compose restart egress-proxy` invocation with `PROFILE` and
  `COMPOSE_PROJECT_NAME` set — and verifying the change took effect means
  tailing Squid's access log, which itself requires `docker exec -u proxy …`.
- Verifying sandbox hardening (`scripts/verify-sandbox.sh`,
  `scripts/setup.sh --verify`, `scripts/trivy-scan.sh`) is a multi-command flow
  whose results scroll past unless captured.
- DB opt-in (`COMPOSE_PROFILES=db-postgres,db-mongo`) is invisible until you
  remember to set the env var.

A single host-side dashboard collapses these into one place without changing
the underlying contract — the dashboard never replaces the scripts, it just
calls them and surfaces their output.

## Non-negotiable constraints

These come straight from the threat model and aren't up for renegotiation
during implementation:

1. **Dashboard runs on the macOS host, never inside a sandbox container.**
   It must talk to `docker`, `colima`, and the host filesystem directly.
   `sandbox-internal` blocks Docker socket access by design — putting the
   dashboard inside a profile would create either a chicken-and-egg or a
   privileged escape hatch.
2. **Bind to `127.0.0.1` only.** Streamlit defaults to `0.0.0.0`; override.
   No remote reach to a process that can `docker compose down` or run
   arbitrary `profile.sh exec`.
3. **Never read secret files.** `.credentials.json`, `db.env`, `gh/hosts.yml`,
   `glab-cli/config.yml` exist or they don't — the dashboard checks
   existence + mtime + size, never contents. Display "authenticated" / "not
   authenticated", never tokens.
4. **Never auto-widen the proxy.** Allowlist edits are explicit user actions
   in the UI with a confirm step + diff preview. The dashboard does not infer
   "you probably want to allow this domain" from observed denials.
5. **Per-profile op lock.** Two browser tabs cannot fire `recreate` on the
   same profile simultaneously. Lock at filesystem level (`flock` on
   `/Volumes/DataDrive/.claude-colima/profiles/<p>/.dashboard.lock`) so even
   a CLI invocation respects it.
6. **No new package installs from inside an active profile.** The dashboard's
   own dependencies are managed in its own `.venv` on the host — it never
   reaches into a profile's `.venv-linux/`.

## Architecture

```
┌─────────────────────────────── macOS host ───────────────────────────────┐
│                                                                          │
│   Browser ──http──> Streamlit (127.0.0.1:8501)                           │
│                       │                                                  │
│                       ├── subprocess ──> scripts/setup.sh                │
│                       ├── subprocess ──> scripts/profile.sh              │
│                       ├── docker SDK ──> Docker daemon (in Colima VM)    │
│                       ├── subprocess ──> colima status / list            │
│                       └── filesystem ──> /Volumes/DataDrive/             │
│                                            ├── repo/<profile>/          │
│                                            └── .claude-colima/profiles/ │
│                                                                          │
│   loguru ──> dashboard/logs/dashboard-YYYY-MM-DD.log (rotating)          │
└──────────────────────────────────────────────────────────────────────────┘
```

The dashboard is a thin orchestration layer. All real work continues to live
in the existing scripts — adding the dashboard does not duplicate the
lifecycle logic, just calls it.

## File layout

New top-level subdir, parallel to `scripts/`:

```
macolima/
  dashboard/
    pyproject.toml              # uv-managed deps
    .venv/                      # uv venv (gitignored)
    .python-version             # 3.12 pinned
    src/
      app.py                    # Streamlit entrypoint
      pages/
        01_overview.py          # cross-profile status grid
        02_profile_detail.py    # per-profile drill-in
        03_lifecycle.py         # command runner
        04_proxy_allowlist.py   # allowed_domains.txt editor
        05_settings.py          # claude-settings.json editor
        06_logs.py              # squid + container log tail
        07_verify.py            # verify-sandbox + trivy results
      lib/
        docker_client.py        # docker SDK wrappers (read-only first)
        colima_client.py        # colima status/list parsing
        profile_state.py        # filesystem-driven profile discovery
        scripts_runner.py       # subprocess + streaming + lock
        squid_log.py            # access.log parser + tailer
        config_io.py            # safe read/write for allowed_domains.txt etc.
        secrets.py              # existence checks ONLY — never contents
      ui/
        components.py           # status pill, profile card, diff viewer, etc.
        theme.py                # streamlit-native styling
    tests/
      test_profile_state.py
      test_squid_log.py
      test_scripts_runner.py
    README.md                   # how to run the dashboard
    Makefile                    # `make dev`, `make test`, `make lint`
```

Add to repo `.gitignore`: `dashboard/.venv/`, `dashboard/logs/`,
`dashboard/.streamlit/secrets.toml`.

## Tech stack

- **Streamlit** — fast to build, native multi-page support, good for tables +
  forms + log streams. Limitations (full-page reruns) are acceptable for an
  ops console.
- **uv** — for venv + lockfile. Matches the repo's existing wheel-into-`dist/`
  workflow.
- **loguru** — per global preference. One sink to rotating file, one to
  Streamlit `st.session_state` for in-app log viewer.
- **docker SDK for Python** (`docker>=7`) — direct API for read operations
  (list containers, images, volumes, networks, stats). Lower latency than
  shelling out to `docker ps` and parses cleanly into dicts.
- **subprocess** — for the script layer (`setup.sh`, `profile.sh`,
  `colima-up.sh`, `stage-audit-package.sh`, `trivy-scan.sh`,
  `verify-sandbox.sh`). These are intentionally not behind an API.
- **PyYAML** — for parsing `docker-compose.yml`, `seccomp.json` (it's JSON but
  we already validate adjacent YAML), `.trivyignore.yaml`.
- **filelock** — cross-platform `flock` wrapper for the per-profile op lock.

## Pages

### 1. Overview (cross-profile status grid)

One row per profile. Columns:

- Name, status (up/down/partial), uptime
- Container count (agent + proxy + optional postgres/mongo)
- Workspace path + existence check
- Auth flags: claude / gh / glab / git-identity (each a colored pill,
  derived from existence of credential files — never their contents)
- Disk usage of state dir (`du -sh`)
- Last activity (mtime of newest file under `claude-home/projects/`)
- Action menu: open detail, restart, recreate, attach (terminal handoff)

Bottom strip: Colima VM status (running, CPU/mem/disk allocations, mount
liveness), shared image (`macolima:latest`) age + size, and trivy last-scan
timestamp.

### 2. Profile detail

Drill-in for one profile. Tabs:

- **Containers** — `docker compose ps` with live stats (CPU/mem/PIDs).
  Per-container "logs" button.
- **State** — tree view of `profiles/<p>/` showing only directories + sizes,
  never file contents. Buttons: `clean`, `clean --deep`, `wipe` (with the
  typed-name confirmation modal mirroring `profile.sh`'s behavior).
- **Auth** — claude/gh/glab status pills + "re-authenticate" buttons that
  use the chosen TTY-handling path (see open question below).
- **Databases** — postgres/mongo container status; toggle for
  `COMPOSE_PROFILES`; `db.env` existence (never contents); buttons to bring
  them up/down.
- **Verify** — one-click run of `setup.sh --verify` + `verify-sandbox.sh`
  (after auto-staging the audit package). Results parsed into
  pass/warn/fail rows.

### 3. Lifecycle (command runner)

Buttons for the safe non-TTY subset, each streaming output to a console
pane that survives reruns via `st.session_state`:

- `up`, `down`, `restart`, `recreate`, `remove`
- `build` (rebuild shared image — affects all profiles)
- `rebuild` (this profile's containers)
- `clean`, `clean --deep`
- `reset-settings`, `reset-skills`
- `wipe --yes` (gated behind a typed-name confirm step, same as the script)

Each invocation captures: command, exit code, stdout/stderr, start/end
timestamp. Persisted to `dashboard/logs/dashboard-YYYY-MM-DD.log` for the
audit trail. Per-profile lock acquired before run; if held, button shows
"profile busy — held by `<other-pid>` since `<ts>`".

### 4. Proxy allowlist editor

Loads `proxy/allowed_domains.txt`. Two-pane diff editor:

- Left: current contents.
- Right: editable buffer.
- Diff preview before save.
- Validation: each line is either blank, comment (`#…`), or a valid
  hostname / `.subdomain.tld` pattern. Reject inline `#` (Squid breaks).
- "Save & restart egress-proxy" runs the save, then
  `docker compose restart egress-proxy` for **every running profile** (one
  shared file across all profiles — invariant from CLAUDE.md). Streams
  output for each.
- Post-save: link to the Squid log tail page so the user can verify the
  next request resolves correctly.

Optional helper: "Suggest from denials" reads the last N denial lines from
`access.log` and lists hostnames the user could *consider* adding. Never
auto-adds.

### 5. Settings editor (`claude-settings.json`)

Per-profile settings under `profiles/<p>/claude-home/settings.json`.
Edits the JSON via a structured form (toggles for `defaultMode`,
`sandbox.enabled`, allow/deny pattern lists), with a raw-JSON fallback.
Validates as JSON before writing. After save: prompt to restart the agent
container so the change takes effect.

Also surfaces the `config/claude-settings.json` template and
`reset-settings` button.

### 6. Logs

Two streams:

- **Squid access log** — `docker exec -u proxy egress-proxy-<p> tail -f
  /var/log/squid/access.log`. Parsed into columns (time, status, method,
  host, path, bytes). Filterable by status code (allow vs deny).
  Per-profile picker.
- **Container logs** — `docker compose logs -f <service>` for agent /
  proxy / postgres / mongo. Plain stream.

Streamed via background thread → `st.session_state` ring buffer → page
render. No WebSocket needed; Streamlit's auto-rerun on session state
update is sufficient at the volumes Squid generates here.

### 7. Verify & audit

- "Run verify-sandbox" — auto-stages audit package, runs the script in
  the container, parses tripwire results into a checklist.
- "Run trivy" — fires `trivy-scan.sh` (config / secret / image / all),
  shows findings grouped by severity. Parses `.trivyignore.yaml` and
  flags any entry whose `expired_at` is past (CLAUDE.md describes this
  policy).
- History view — last N runs of each, kept under `dashboard/audit-history/`.

## TTY handling — open decision

`auth`, `auth-github`, `auth-gitlab`, `attach`, and arbitrary `exec -it`
need a TTY. The non-TTY subset covers ~80% of operations and includes
every lifecycle action. Three options to revisit:

1. **Read-only / non-TTY only** — no auth or attach buttons in the UI.
   User runs `scripts/profile.sh <p> auth` from a terminal as today.
   Lowest risk; auth is a once-per-profile flow anyway.
2. **Terminal handoff** (recommended for v1) — buttons `osascript`-launch
   Terminal.app pre-loaded with the right command. Dashboard process
   never owns the PTY, never sees tokens. Risk profile is identical to
   a `.command` file on the desktop.
3. **Embedded `ttyd` web terminal** — dashboard spawns `ttyd` bound to
   `127.0.0.1:<random-port>` with its target locked to
   `docker exec -it claude-agent-<p> zsh`. Slicker UX, but adds a
   PTY-spawning service to the dashboard's blast radius. Defer until
   v2 unless `attach` becomes a constant operation.

## Scope phasing — open decision

To revisit before implementation. Default phasing:

**v1 (MVP, ~1–2 weeks of work):**
- Pages 1, 2, 3, 6 (overview, profile detail, lifecycle, logs).
- TTY option 2 (terminal handoff).
- Read-only `allowed_domains.txt` viewer (no editor yet).

**v2:**
- Page 4 (allowlist editor with diff + validation).
- Page 5 (settings editor).
- Page 7 (verify & audit integration).

**v3:**
- Embedded ttyd if `attach` UX becomes important.
- Resource graphs over time (currently just point-in-time).
- Profile clone / template-from-existing.
- Cross-profile diff (compare two profiles' settings, dist contents, etc.).

## Things "others ask for" worth considering later

From experience with secure container ops dashboards:

- **Audit trail / immutable command log** — already covered by the per-day
  log file; consider hashing each entry (chained hash) so tampering is
  detectable.
- **Read-only mode toggle** — startup flag that disables every mutate
  button. For when you want a status board for someone else to watch
  without giving them lifecycle control.
- **Squid analytics rollups** — top hosts, denial heatmap, bytes per host
  per hour. Cheap once `squid_log.py` exists.
- **Resource time-series** — sample `docker stats` every N seconds, plot
  per-profile CPU/mem in the overview.
- **Diff against git HEAD** — show whether `allowed_domains.txt` /
  `seccomp.json` / `claude-settings.json` template are dirty vs the
  committed copy.
- **Emergency stop** — single button that runs `docker compose down` on
  every profile. Confirms first.
- **Profile clone** — "create new profile from existing", just init dirs +
  prefill `setup.sh` invocation.
- **DB superuser warning** — CLAUDE.md notes the agent currently holds DB
  admin creds (TODO: least-privilege split). Surface this as a banner on
  the DB tab so it doesn't get forgotten.
- **VS Code attach helper** — show the exact "Attach to Running Container"
  → `claude-agent-<p>` flow as a copy-pasteable hint after recreate
  (which invalidates VS Code's cached container ID per CLAUDE.md).

## Critical files (modified or created)

Created:
- `dashboard/` (entire subtree above)

Modified:
- `.gitignore` — add `dashboard/.venv/`, `dashboard/logs/`,
  `dashboard/.streamlit/secrets.toml`.
- `CLAUDE.md` — add a short "Dashboard" section pointing at this plan +
  noting the dashboard runs on the host, bound to `127.0.0.1`, never
  reads secrets, holds a per-profile op lock.
- `README.md` — one-line pointer under Operations section.

Read-only references (the dashboard calls these but does not modify):
- `scripts/setup.sh`, `scripts/profile.sh`, `scripts/colima-up.sh`,
  `scripts/stage-audit-package.sh`, `scripts/trivy-scan.sh`,
  `scripts/verify-sandbox.sh`
- `proxy/allowed_domains.txt` (page 4 will eventually edit this)
- `config/claude-settings.json` (template)
- `docker-compose.yml`, `seccomp.json`, `Dockerfile`

## Verification plan

End-to-end checks once v1 lands, run from a fresh checkout:

1. `cd dashboard && uv venv && uv pip install -e .` — installs cleanly,
   no proxy widening required (host-side install).
2. `make dev` → Streamlit starts on `127.0.0.1:8501`.
3. `lsof -iTCP:8501 -sTCP:LISTEN` shows `127.0.0.1` only, no `*:8501`.
4. Overview page lists all directories under
   `/Volumes/DataDrive/.claude-colima/profiles/`. Status pills match
   `docker ps` reality.
5. Lifecycle: click `up` on a downed profile → output streams → profile
   shows `up` within 30s. Click `down` → reverse.
6. Concurrency: open the same profile in two browser tabs, click `recreate`
   in both. Second click shows "profile busy" lock message.
7. Log viewer: while profile is up, run a `curl` from inside the agent
   to an allowed domain — line appears in the squid log pane.
8. Disable mutate (start with `--read-only`): every mutate button is
   either hidden or disabled.
9. Secrets check: grep dashboard logs for tokens
   (`grep -E '(sk-|ghp_|glpat-)' dashboard/logs/*` returns nothing).

## What this plan does NOT do

- Replace `scripts/setup.sh` / `scripts/profile.sh` — they remain the
  source of truth and the supported CLI surface.
- Run inside any sandbox container.
- Provide remote access — bound to `127.0.0.1`, no auth layer.
- Touch the Colima VM provisioning step (`scripts/colima-up.sh`) — it
  surfaces status only.
- Edit `seccomp.json`, `Dockerfile`, or `docker-compose.yml` — these are
  invariant-bearing and changed by hand.
- Manage container OAuth tokens — the existing `gh auth login` /
  `glab auth login` / `claude login` flows are the only path.

## Open questions to revisit

- TTY handling choice (read-only vs terminal handoff vs embedded ttyd).
- v1 scope confirmation (default proposed above).
- Should the dashboard write its own `.streamlit/config.toml` to enforce
  `127.0.0.1` binding, or rely on a `make dev` flag? (Probably both —
  defense in depth.)
- Lock file location — under `profiles/<p>/` (visible to `wipe`) vs
  under `dashboard/locks/` (cleaner but split state). Lean toward the
  former so a CLI `profile.sh` invocation could in theory honor the same
  lock later.
- Authentication on the dashboard itself — none for now (loopback only),
  but consider a one-shot session token in `.streamlit/secrets.toml` if
  the host ever has untrusted local users.
