"""Status tab — Colima VM, profiles, and per-profile squid health.

Moved verbatim out of app.py when the dashboard went to tabs. The logic is
macolima's, not windows-ai-sandbox's: theirs watches a rootless Docker socket
under /run/user/<uid> and profiles under ~/.ai-sandbox. Here the VM itself is a
layer that can be down independently of everything else, which is the single
most common reason the dashboard looks broken, so it gets its own metric.
"""

from __future__ import annotations

import os
from datetime import datetime, timezone

import streamlit as st

from lib.docker_client import DockerClient

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
ALLOWLIST_PATH = os.path.join(REPO_ROOT, "proxy", "allowed_domains.txt")
PROFILES_DIR = "/Volumes/DataDrive/.claude-colima/profiles"
COLIMA_SOCK = "/Volumes/DataDrive/.colima/default/docker.sock"


def render() -> None:
    docker_client = DockerClient()
    colima_up = os.path.exists(COLIMA_SOCK)
    running = sorted(docker_client.get_running_profiles()) if colima_up else []

    # Profiles on disk vs profiles actually up — the gap is informative.
    on_disk = []
    if os.path.exists(PROFILES_DIR):
        on_disk = sorted(
            d for d in os.listdir(PROFILES_DIR)
            if os.path.isdir(os.path.join(PROFILES_DIR, d))
        )

    # Allowlist mtime — single source of "when did the proxy config last change".
    if os.path.exists(ALLOWLIST_PATH):
        mtime = datetime.fromtimestamp(
            os.path.getmtime(ALLOWLIST_PATH), tz=timezone.utc
        ).astimezone()
        mtime_str = mtime.strftime("%Y-%m-%d %H:%M")
    else:
        mtime_str = "—"

    st.subheader("Status")
    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Colima VM", "Running" if colima_up else "Stopped")
    c2.metric("Profiles on disk", len(on_disk))
    c3.metric("Profiles up", f"{len(running)}/{len(on_disk) or '?'}")
    c4.metric("Allowlist saved", mtime_str)

    # One row per running profile, derived from the egress-proxy-<p> container's
    # status + health. Only renders when something is running; an empty state is
    # more honest than a fabricated table.
    if running:
        st.subheader("Egress proxies")
        rows = []
        for p in running:
            proxy_name = f"egress-proxy-{p}"
            try:
                c = docker_client.client.containers.get(proxy_name)
                status = c.status
                health = c.attrs.get("State", {}).get("Health", {}).get("Status", "—")
            except Exception:
                status, health = "missing", "—"
            rows.append({"profile": p, "container": proxy_name,
                         "status": status, "health": health})
        st.dataframe(rows, hide_index=True, width="stretch")
    elif colima_up:
        st.info("Colima is up but no profiles are running. "
                "Start one with `scripts/profile.sh <name> up`.")
    else:
        st.warning("Colima is not running. Start it with `scripts/colima-up.sh` "
                   "(first time / after a delete) or `just colima-up`.")

    st.caption(
        "Deeper checks stay on the CLI: `just health` for cross-profile "
        "container consistency, `just verify <profile>` for the hardening "
        "tripwire (allowlist enforcement + in-container probes)."
    )
