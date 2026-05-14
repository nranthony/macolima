# macolima control dashboard — design plan

Source-of-truth for current invariants is `CLAUDE.md`. This file mixes
**shipped scope** (v1) with **deferred scope** (v2/v3) for the host-side
Streamlit dashboard that surfaces status and edits config for the
multi-profile sandbox stack.

## Status (2026-05-14)

**v1 shipped.** Scope landed narrower than the original plan: a
proxy-allowlist editor plus a thin status landing page. Lifecycle, logs,
auth, settings, and verify tabs were deferred — `scripts/setup.sh` and
`scripts/profile.sh` remain the supported surface for everything else.

What exists:

```
dashboard/
  pyproject.toml          # uv-managed; streamlit + docker SDK + loguru + PyYAML + filelock
  .streamlit/config.toml  # pins server.address = 127.0.0.1
  README.md               # short — points users at `uv run streamlit run src/app.py`
  src/
    app.py                # landing page: Colima status, profile counts, egress-proxy health rows
    pages/
      04_proxy_allowlist.py
    lib/
      config_io.py        # allowed_domains.txt parser/serializer (block-aware)
      docker_client.py    # context-aware daemon resolver, reload_proxy w/ stale-mount detection
```

What's deliberately missing relative to the original plan: `ui/`,
`tests/`, `Makefile`, the six other pages, the file-level op lock, the
`secrets.py` existence-checker module. Each of those is reframed under
v2/v3 below — the v1 surface is too small to need them yet.

## Context — why

Today, most operations still go through `scripts/setup.sh` /
`scripts/profile.sh` in a terminal. That works, but allowlist edits in
particular had real friction:

- `proxy/allowed_domains.txt` edits require remembering `docker exec
  egress-proxy-<p> squid -k reconfigure` per running profile, with the
  right `PROFILE` / `COMPOSE_PROJECT_NAME` env vars set.
- Verifying the reload took effect means tailing Squid's access log
  (which needs `docker exec -u proxy …`), or watching a request 403.
- A class of silent-failure mode (stale virtiofs single-file bind mount
  → squid loads an empty ACL on reconfigure, every request 403s) is
  invisible from the CLI without inspecting the in-container file.

v1 collapses *that* loop into one place. The other CLI friction points
(lifecycle, auth, verify) didn't have the same compounding pain, so
they slid to later phases.

## Non-negotiable constraints

These come from the threat model and aren't up for renegotiation in any
phase:

1. **Dashboard runs on the macOS host, never inside a sandbox
   container.** It must talk to `docker`, `colima`, and the host
   filesystem directly. `sandbox-internal` blocks Docker socket access
   by design — putting the dashboard inside a profile would create
   either a chicken-and-egg or a privileged escape hatch.
2. **Bind to `127.0.0.1` only.** Streamlit defaults to `0.0.0.0`;
   `.streamlit/config.toml` pins this. No remote reach to a process
   that can run lifecycle commands or rewrite the allowlist.
3. **Never read secret files.** `.credentials.json`, `db.env`,
   `gh/hosts.yml`, `glab-cli/config.yml` exist or they don't — the
   dashboard checks existence + mtime + size, never contents.
4. **Never auto-widen the proxy.** Allowlist edits are explicit user
   actions in the UI. The dashboard does not infer "you probably want
   to allow this domain" from observed denials.
5. **Per-profile op lock** (for v2+ lifecycle actions). Two browser
   tabs must not fire `recreate` on the same profile simultaneously.
   Lock at filesystem level (`flock` on
   `/Volumes/DataDrive/.claude-colima/profiles/<p>/.dashboard.lock`).
   Not needed in v1 — the allowlist editor is shared-config not
   per-profile, and the reload is idempotent.
6. **No new package installs from inside an active profile.** The
   dashboard's own dependencies are managed in its own `.venv` on the
   host.

## Architecture

```
┌─────────────────────────────── macOS host ───────────────────────────────┐
│                                                                          │
│   Browser ──http──> Streamlit (127.0.0.1:8501)                           │
│                       │                                                  │
│                       ├── docker SDK ──> Docker daemon (in Colima VM)    │
│                       ├── subprocess ──> docker compose (recreate path)  │
│                       └── filesystem ──> /Volumes/DataDrive/             │
│                                            └── repo/.../proxy/           │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

The dashboard is a thin orchestration layer. All real work continues to
live in the existing scripts and the docker SDK — adding the dashboard
does not duplicate lifecycle logic.

## v1 — shipped

### Landing page (`src/app.py`)

Four top-line metrics: Colima VM status, profiles on disk, profiles up,
allowlist mtime. Below: one row per running profile with the
`egress-proxy-<p>` container's status + healthcheck state. Empty/idle
states render explanatory text instead of empty tables (e.g. "Colima is
up but no profiles are running" → suggests the right CLI command).

The Docker daemon connection uses a context-aware resolver
(`_resolve_docker_host` in `lib/docker_client.py`) — the docker SDK only
reads `$DOCKER_HOST`, but on macOS the active socket is whatever
`docker context show` says it is (Colima writes a custom path like
`/Volumes/DataDrive/.colima/default/docker.sock`). The resolver shells
out to the CLI once at construction to get the right URL.

### Proxy allowlist editor (`src/pages/04_proxy_allowlist.py`)

Block-aware editor over `proxy/allowed_domains.txt`. The file's
existing structure (`# === SECTION ===` headers and `# --- Name [tag]
---` block markers, with domains underneath) drives the UI:

- Status banner shows running-profile count, with three meaningful
  states (docker unreachable / no profiles up / N profiles up).
- One card per `[tag]` block. Each shows a coloured pill (`ON · N` /
  `N/total ON` / `OFF`) and per-domain checkboxes inside an expander.
- "All on" / "All off" buttons per block for bulk toggling.
- "Add New Domain" form at the bottom, with a dropdown to pick the
  target block. New domains inherit the comment state of the last
  existing domain in that block (so e.g. adding into `[pypi]`, which is
  commented-out by default for autonomous-mode safety, does NOT
  silently open egress).
- **Save & Reload Proxies** runs `squid -k reconfigure` against every
  running egress-proxy container and reports per-profile results
  inline.

Notable design refinements that landed beyond the original plan:

- **Stale-bind-mount detection.** `docker exec squid -k reconfigure`
  exits 0 even when squid loaded an empty ACL because the included
  file became unreadable (single-file virtiofs bind mounts lose their
  inode binding when the host file is rewritten). The reload path
  reads the in-container allowlist back and counts non-comment lines;
  if it's unreadable, the result is flagged `needs_recreate=True`
  with a recovery hint, and the UI renders a one-click "Recreate
  egress-proxy-<p>" button that runs `docker compose up -d
  --force-recreate egress-proxy` with the right env vars.
- **`on_change`/`on_click` callbacks, not detect-and-rerun.** Earlier
  iterations had every checkbox toggle re-run the whole page, which
  collapsed expanders on every click. The callback model + explicit
  widget-key pruning (`_drop_dom_keys`) keeps expanders open and
  silences Streamlit's "widget created with default value but also had
  session state" warning.
- **Inline action status under the Save button**, not toast-only.
  Persists across reruns via `st.session_state["last_reload_results"]`
  so the recreate-recovery button (which itself triggers a rerun) can
  still see the failed-profile context.

### What v1 deliberately does NOT do

- Lifecycle actions (`up`/`down`/`recreate`/`wipe`).
- Auth status, attach buttons, terminal handoff.
- Settings (`claude-settings.json`) editing.
- Squid access log streaming or container log tailing.
- `verify-sandbox.sh` / Trivy run-and-parse.
- DB toggle / `COMPOSE_PROFILES` management.
- Per-profile op lock (no mutating per-profile actions exist yet).
- Test suite, `Makefile`, audit-history retention.

## v2 — deferred

Roughly in priority order. Each one is independently shippable.

### Lifecycle page

Buttons for the safe non-TTY subset, each streaming output to a console
pane that survives reruns via `st.session_state`:

- `up`, `down`, `restart`, `recreate`, `remove`
- `build` (rebuild shared image — affects all profiles)
- `rebuild` (this profile's containers)
- `clean`, `clean --deep`
- `reset-settings`, `reset-skills`
- `wipe --yes` (gated behind a typed-name confirm step, same as the
  script)

Each invocation captures: command, exit code, stdout/stderr,
start/end timestamp. Persisted to `dashboard/logs/dashboard-YYYY-MM-DD.log`
(loguru, rotating). Per-profile lock acquired before run; if held,
button shows "profile busy — held by `<other-pid>` since `<ts>`". This
is the trigger for the `filelock`-based per-profile op lock from the
constraints section — it isn't worth wiring until there's at least one
mutating per-profile action.

### Profile detail page

Drill-in for one profile. Tabs:

- **Containers** — `docker compose ps` with live stats (CPU/mem/PIDs).
  Per-container "logs" button.
- **State** — tree view of `profiles/<p>/` showing only directories +
  sizes, never file contents. Buttons: `clean`, `clean --deep`,
  `wipe` (with the typed-name confirmation modal mirroring
  `profile.sh`'s behavior).
- **Auth** — claude/gh/glab status pills (existence-of-file checks
  only) + "re-authenticate" buttons routed through the TTY handoff
  path (see below).
- **Databases** — postgres/mongo container status; toggle for
  `COMPOSE_PROFILES`; `db.env` existence (never contents); buttons
  to bring them up/down.

### Logs page

Two streams:

- **Squid access log** — `docker exec -u proxy egress-proxy-<p> tail -f
  /var/log/squid/access.log`. Parsed into columns (time, status,
  method, host, path, bytes). Filterable by status code (allow vs
  deny). Per-profile picker.
- **Container logs** — `docker compose logs -f <service>` for agent /
  proxy / postgres / mongo. Plain stream.

Streamed via background thread → `st.session_state` ring buffer.

### TTY handling — open decision (still)

`auth`, `auth-github`, `auth-gitlab`, `attach`, `exec -it` need a TTY.
Three options:

1. **Read-only / non-TTY only** — no auth or attach buttons. User
   runs `scripts/profile.sh <p> auth` from a terminal as today.
   Lowest risk; auth is once-per-profile anyway.
2. **Terminal handoff** (recommended) — buttons `osascript`-launch
   Terminal.app pre-loaded with the right command. Dashboard process
   never owns the PTY, never sees tokens. Same risk profile as a
   `.command` file on the desktop.
3. **Embedded `ttyd` web terminal** — dashboard spawns `ttyd` bound
   to `127.0.0.1:<random-port>` with its target locked to `docker
   exec -it claude-agent-<p> zsh`. Slicker UX, but adds a
   PTY-spawning service to the dashboard's blast radius. Defer
   unless `attach` becomes a constant operation.

## v3 — deferred further

### Settings editor (`claude-settings.json`)

Per-profile settings under `profiles/<p>/claude-home/settings.json`.
Edits via a structured form (toggles for `defaultMode`,
`sandbox.enabled`, allow/deny pattern lists) with a raw-JSON fallback.
Validates as JSON before writing. After save: prompt to restart the
agent container so the change takes effect. Surfaces the
`config/claude-settings.json` template and `reset-settings` button.

### Verify & audit

- "Run verify-sandbox" — auto-stages audit package, runs the script
  in the container, parses tripwire results into a checklist.
- "Run trivy" — fires `scripts/trivy-scan.sh` (config / secret /
  image / all), shows findings grouped by severity. Parses
  `.trivyignore.yaml` and flags any entry whose `expired_at` is past
  (CLAUDE.md describes this policy).
- History view — last N runs of each, kept under
  `dashboard/audit-history/`.

### Extras worth considering

From experience with secure container ops dashboards:

- **Audit trail / immutable command log** — hash-chain each entry so
  tampering is detectable.
- **Read-only mode toggle** — startup flag that disables every
  mutate button. For when you want a status board for someone else to
  watch without giving them lifecycle control.
- **Squid analytics rollups** — top hosts, denial heatmap, bytes per
  host per hour. Cheap once a squid_log parser exists.
- **Resource time-series** — sample `docker stats` every N seconds,
  plot per-profile CPU/mem in the overview.
- **Diff against git HEAD** — show whether `allowed_domains.txt`,
  `seccomp.json`, `claude-settings.json` template are dirty vs
  committed.
- **Emergency stop** — single button that runs `docker compose down`
  on every profile. Confirms first.
- **Profile clone** — "create new profile from existing", just init
  dirs + prefill `setup.sh` invocation.
- **DB superuser warning banner** — CLAUDE.md notes the agent
  currently holds DB admin creds (TODO: least-privilege split).
  Surface this on the DB tab so it doesn't get forgotten.
- **VS Code attach helper** — show the exact "Attach to Running
  Container" → `claude-agent-<p>` flow as a copy-pasteable hint
  after recreate (which invalidates VS Code's cached container ID
  per CLAUDE.md).
- **"Suggest from denials"** — read the last N denial lines from
  `access.log` and list hostnames the user could *consider* adding.
  Never auto-adds.

## Critical files

### Shipped

- `dashboard/.streamlit/config.toml` — pins `127.0.0.1` binding.
- `dashboard/pyproject.toml` — deps (streamlit, docker, loguru,
  PyYAML, filelock).
- `dashboard/README.md` — host-side run instructions.
- `dashboard/src/app.py` — landing/status page.
- `dashboard/src/pages/04_proxy_allowlist.py` — allowlist editor.
- `dashboard/src/lib/config_io.py` — allowlist parser/serializer.
- `dashboard/src/lib/docker_client.py` — daemon resolver,
  reload+stale-mount detection, recreate path.
- `.gitignore` — covers `dashboard/.venv/`, `dashboard/logs/`,
  `dashboard/.streamlit/secrets.toml`.

### Read-only references (called, not modified)

- `proxy/allowed_domains.txt` (edited by the allowlist page).
- `docker-compose.yml` (used implicitly via `docker compose` calls in
  the recreate-proxy path).

### Reserved for v2+

- `dashboard/src/lib/scripts_runner.py` — subprocess wrapper with
  streaming + per-profile flock.
- `dashboard/src/lib/profile_state.py` — filesystem-driven profile
  discovery (richer than the current `os.listdir`).
- `dashboard/src/lib/squid_log.py` — access.log tailer + parser.
- `dashboard/src/lib/secrets.py` — existence-only checks for cred
  files.
- `dashboard/src/ui/` — shared components (status pill, profile
  card, diff viewer).
- `dashboard/tests/` — first targets are `config_io.py` (allowlist
  parser round-trip on the real file) and `docker_client.py`'s
  stale-mount detection (mockable).

## Verification

### Shipped (v1)

Run from a fresh checkout:

1. `cd dashboard && uv venv && uv pip install -e .` — installs
   cleanly, no proxy widening required (host-side install).
2. `uv run streamlit run src/app.py` → Streamlit starts on
   `127.0.0.1:8501`.
3. `lsof -iTCP:8501 -sTCP:LISTEN` shows `127.0.0.1` only, no
   `*:8501`.
4. Landing page lists Colima status and profile counts matching
   `docker ps` reality.
5. Allowlist page: toggle a domain → save → message reports
   per-profile `(N domains)` count → in-container
   `grep -cvE '^\s*(#|$)' /etc/squid/allowed_domains.txt` matches.
6. Stale-bind-mount recovery: edit `proxy/allowed_domains.txt`
   externally (e.g. `mv … …`) while a profile is up so virtiofs
   loses the inode → click Save & Reload → page surfaces
   `needs_recreate` error with a Recreate button → click it →
   container is recreated, next reload reports a healthy count.
7. Secrets check: `grep -E '(sk-|ghp_|glpat-)' dashboard/logs/*`
   returns nothing.

### Pending until v2 lands

- Concurrency: open the same profile in two browser tabs, click
  `recreate` in both → second shows "profile busy" lock message.
  (Requires the `filelock`-backed scripts_runner from v2.)
- Lifecycle smoke: `up` on a downed profile → output streams →
  profile shows `up` within 30s. `down` reverses.
- Read-only mode: start with `--read-only` flag → every mutate
  button hidden or disabled. (Requires v3 read-only toggle.)

## Open questions to revisit

- **TTY handling** (read-only / terminal handoff / embedded ttyd) —
  decide before the v2 profile-detail page lands.
- **Lock file location** — under `profiles/<p>/` (visible to `wipe`)
  vs `dashboard/locks/` (cleaner but split state). Lean toward the
  former so a CLI `profile.sh` invocation could in theory honor the
  same lock later.
- **Authentication on the dashboard itself** — none for now
  (loopback only), but consider a one-shot session token in
  `.streamlit/secrets.toml` if the host ever has untrusted local
  users.
- **CLAUDE.md / README.md cross-links** — original plan called for
  adding a "Dashboard" section to CLAUDE.md and a one-line pointer
  under Operations in README.md. Not yet added; do this once at
  least one more v2 page has landed, so the doc-vs-code drift
  doesn't compound.
