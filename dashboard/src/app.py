import os
from datetime import datetime, timezone

import streamlit as st

from lib.docker_client import DockerClient

st.set_page_config(page_title="macolima Control Dashboard", layout="wide")

# Sidebar header is intentionally minimal — Streamlit auto-appends the page
# nav below it from src/pages/. Keep this short so the nav dominates.
st.sidebar.title("macolima Dashboard")

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ALLOWLIST_PATH = os.path.join(REPO_ROOT, "proxy", "allowed_domains.txt")
PROFILES_DIR = "/Volumes/DataDrive/.claude-colima/profiles"
COLIMA_SOCK = "/Volumes/DataDrive/.colima/default/docker.sock"

st.title("macolima Control Dashboard")

st.markdown(
    "Ops console for the hardened sandbox stack. Use the sidebar to navigate, "
    "or jump straight to **[Proxy allowlist](/proxy_allowlist)**."
)

# --- Status grid ---------------------------------------------------------
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

# --- Per-profile squid health -------------------------------------------
# One row per running profile, derived from the egress-proxy-<p> container's
# status + health. Only renders when there's something running; an empty
# state is more honest than a fabricated table.
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
    st.dataframe(rows, hide_index=True, use_container_width=True)
elif colima_up:
    st.info("Colima is up but no profiles are running. "
            "Start one with `scripts/profile.sh <name> up`.")
else:
    st.warning("Colima is not running. Start it with `scripts/colima-up.sh`.")
