"""macolima control dashboard — host-side ops console.

Thin shell: two tabs, each rendered by a module under lib/. Everything that
used to live here (the status grid) moved to lib/status_view.py, and the
allowlist editor moved from src/pages/04_proxy_allowlist.py to
lib/proxy_allowlist_view.py — matching windows-ai-sandbox's layout.

Tabs rather than Streamlit's src/pages/ multipage nav: with two views the
sidebar nav costs more screen than it earns, and a tab switch keeps
session_state (the in-memory allowlist edits) on screen instead of behind a
page change.
"""

import os
import sys

import streamlit as st

sys.path.insert(0, os.path.dirname(__file__))

from lib import proxy_allowlist_view, status_view

st.set_page_config(page_title="macolima Control Dashboard", layout="wide")

st.title("macolima Control Dashboard")
st.caption("Ops console for the hardened sandbox stack. Runs on the host, never inside a sandbox.")

tab_status, tab_allowlist = st.tabs(["Status", "Proxy Allowlist"])

with tab_status:
    status_view.render()

with tab_allowlist:
    proxy_allowlist_view.render()
