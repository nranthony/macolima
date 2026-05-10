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
cd dashboard
uv run streamlit run src/app.py
```

Bind address is pinned to `127.0.0.1` via `.streamlit/config.toml` — open
<http://127.0.0.1:8501> in your browser.

## Features

- **Proxy allowlist editor** — toggle blocks/domains in
  `proxy/allowed_domains.txt`, save, and restart `egress-proxy` for every
  running profile in one click.

That's it for now. Everything else (lifecycle, logs, verify) stays on the
CLI via `scripts/profile.sh` and `scripts/setup.sh`.
