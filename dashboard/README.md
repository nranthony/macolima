# macolima control dashboard

Host-side ops console for the macolima sandbox stack. Runs on macOS, talks to
the Colima Docker daemon and the repo's config files. Not for use inside any
sandbox container.

## Setup

Requires [uv](https://github.com/astral-sh/uv).

```bash
cd dashboard
uv venv
uv pip install -e .
```

## Run

```bash
just dashboard        # from anywhere in the repo
```

or equivalently, from this directory:

```bash
uv run streamlit run src/app.py
```

Bind address is pinned to `127.0.0.1` via `.streamlit/config.toml` — open
<http://127.0.0.1:8501> in your browser. Streamlit reads that file relative to
the **current working directory**, so both forms above start from `dashboard/`
on purpose. `scripts/dashboard.sh` (what `just dashboard` runs) does the `cd`
for you and refuses to start if the config file is missing, rather than silently
falling back to Streamlit's default of binding every interface.

## Layout

```
src/app.py                      two tabs, no logic
src/lib/status_view.py          Status tab — Colima VM, profiles, squid health
src/lib/proxy_allowlist_view.py Proxy Allowlist tab — the editor
src/lib/proxy_categories.py     purpose grouping + accent colours for block tags
src/lib/config_io.py            allowed_domains.txt parse/serialise
src/lib/docker_client.py        Colima socket resolution, reload/recreate proxies
tests/                          `just test-dashboard`
```

## Tests

```bash
just test-dashboard
```

Locks the parser against the live `proxy/allowed_domains.txt`: read→write must
be byte-identical, no domain may be parsed outside a block or inherit a tag
across a section divider, every block tag must map to a category, `add_domain`
must inherit the block's comment state (adding to a commented-out block must not
silently open egress), and `app.py` must render without exceptions. Anything
that writes runs against a copy.

## Features

- **Proxy allowlist editor** — toggle blocks/domains in
  `proxy/allowed_domains.txt`, save, and restart `egress-proxy` for every
  running profile in one click.

That's it for now. Everything else (lifecycle, logs, verify) stays on the
CLI via `scripts/profile.sh` and `scripts/setup.sh`.
