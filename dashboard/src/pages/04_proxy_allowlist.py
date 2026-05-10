import os

import streamlit as st

from lib.config_io import ConfigIO
from lib.docker_client import DockerClient

st.set_page_config(page_title="Proxy Allowlist", layout="wide")

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
config_io = ConfigIO(REPO_ROOT)
docker_client = DockerClient()

# Title + Actions live on one row so the buttons sit next to the heading
# instead of pushing block content down. col_status holds the inline
# success/error feedback rendered after Save & Reload (status under the
# buttons, not as a toast — gives the user something to read post-action
# without scrolling).
hdr_l, hdr_r = st.columns([3, 2])
with hdr_l:
    st.title("Proxy Allowlist Editor")
    st.markdown("Manage domains in `proxy/allowed_domains.txt` and reload squid.")

# State banner — sets expectations BEFORE the user clicks Save & Reload.
# Three meaningful states: docker unreachable / no profiles up / N profiles up.
_running = docker_client.get_running_profiles()
with hdr_l:
    if docker_client.client is None:
        st.warning(
            "Docker daemon not reachable. File edits will save, but no "
            "proxies can be reloaded. Start Colima with "
            "`scripts/colima-up.sh`."
        )
    elif not _running:
        st.info(
            "No profiles running. File edits save to disk and take effect "
            "when a profile is next started — squid reads the allowlist "
            "fresh on container startup."
        )
    else:
        st.caption(f"Profiles up: **{', '.join(sorted(_running))}** — "
                   f"reload will hit each one.")


def _pill(text: str, color: str) -> str:
    """Inline coloured status pill rendered via st.markdown(unsafe_allow_html=True)."""
    return (
        f'<span style="background:{color}; color:white; padding:2px 10px; '
        f'border-radius:10px; font-size:0.78em; font-weight:600; '
        f'letter-spacing:0.03em; white-space:nowrap;">{text}</span>'
    )


# Tailwind-ish palette: green-600 / amber-600 / zinc-500.
def PILL_ON(n):    return _pill(f"ON · {n}", "#16a34a")
def PILL_PARTIAL(n, total): return _pill(f"{n}/{total} ON", "#d97706")
PILL_OFF = _pill("OFF", "#71717a")


# --- Callbacks ------------------------------------------------------------
# Using on_change/on_click instead of detect-and-rerun loops eliminates the
# expander-collapse-on-click issue (every prior st.rerun call recreated the
# expander) and lets multi-toggling feel as fast as Streamlit allows.

def _on_dom_toggle(tag: str, domain: str) -> None:
    """User clicked a domain checkbox — sync the underlying entry.

    Reads (does not write) session_state[key], so it doesn't trip
    `check_session_state_rules`. The checkbox owns its widget state;
    we just mirror it into `entries` for serialization on Save.
    """
    new_val = st.session_state[f"dom_{tag}_{domain}"]
    for e in st.session_state.entries:
        if e.block_tag == tag and e.domain == domain:
            e.is_commented = not new_val
            return


def _drop_dom_keys() -> None:
    """Pop every `dom_*` widget key from session_state.

    Used after we mutate `e.is_commented` on multiple entries (block
    toggles, refresh, add). On the next render the checkboxes are
    "new" again, so their `value=not e.is_commented` is honoured —
    and Streamlit's "default value + session_state" warning stays
    silent because the key isn't in session_state when the widget
    is created.
    """
    for k in [k for k in st.session_state.keys() if k.startswith("dom_")]:
        del st.session_state[k]


def _on_block_all(tag: str, enable: bool) -> None:
    """User clicked All on / All off for a block."""
    for e in st.session_state.entries:
        if e.block_tag == tag and e.domain:
            e.is_commented = not enable
    _drop_dom_keys()


def _on_refresh() -> None:
    """User clicked Refresh from File — discard in-memory edits."""
    st.session_state.entries = config_io.read_allowed_domains()
    _drop_dom_keys()


# --- Hydration ------------------------------------------------------------
# Load entries from disk on first run only. Source of truth: each entry's
# `is_commented`. Each checkbox below reads it via `value=` and writes back
# via the on_change callback. We deliberately do NOT pre-populate
# `st.session_state["dom_*"]` — when both a non-None `value=` and an
# existing session_state entry are present, Streamlit logs the "widget
# created with default value but also had its value set via the Session
# State API" warning. Block-toggle and refresh callbacks update
# `is_commented` directly and pop the widget keys (see _drop_dom_keys),
# so the next render reseeds widgets cleanly from `value=`.

if 'entries' not in st.session_state:
    st.session_state.entries = config_io.read_allowed_domains()

entries = st.session_state.entries

# Helper to get blocks
blocks = {}
for entry in entries:
    if entry.block_tag:
        if entry.block_tag not in blocks:
            blocks[entry.block_tag] = []
        if entry.domain:
            blocks[entry.block_tag].append(entry)

# --- UI Layout ------------------------------------------------------------
# Top-right Actions column (defined alongside the title up top via hdr_r).
# Buttons + inline status here — keeps the workflow's outcome visible
# without making the user hunt for a toast.

with hdr_r:
    st.markdown("#### Actions")
    bcol1, bcol2 = st.columns(2)
    save_clicked = bcol1.button("Save & Reload Proxies", type="primary",
                                use_container_width=True)
    bcol2.button("Refresh from File", on_click=_on_refresh,
                 use_container_width=True)
    # Inline status slot — populated below after the click is handled.
    action_status = st.container()

if save_clicked:
    # File save always runs — even if nothing's up to reconfigure, the next
    # container start will pick up the change. Two-step so the user gets
    # clear feedback on each half.
    config_io.write_allowed_domains(st.session_state.entries)
    # Stash results in session state so the recovery (Recreate Proxy)
    # buttons rendered below survive Streamlit's per-click rerun.
    st.session_state["last_reload_results"] = (
        docker_client.reload_all_proxies()
        if docker_client.client is not None else []
    )
    st.session_state["last_reload_no_docker"] = docker_client.client is None
    st.toast("Saved to proxy/allowed_domains.txt", icon="💾")

# Render the most recent reload outcome (whether from this rerun's click or
# a prior one, since the recreate-recovery buttons trigger reruns of their
# own). Three buckets: no-docker, no-proxies-up, per-profile results.
if "last_reload_results" in st.session_state:
    with action_status:
        if st.session_state.get("last_reload_no_docker"):
            st.info("File saved. Docker daemon not reachable — no proxies "
                    "to reload now.")
        else:
            results = st.session_state["last_reload_results"]
            if not results:
                st.info("File saved. No running egress-proxy containers — "
                        "the new allowlist will load on next "
                        "`scripts/profile.sh <p> up`.")
            else:
                ok = [r for r in results if r["ok"]]
                failed = [r for r in results if not r["ok"]]
                if ok:
                    # Domain count gives positive confirmation that squid
                    # actually loaded something — vs the silent empty-ACL
                    # failure mode (see docker_client._count_active_domains).
                    parts = [
                        f"{r['profile']} ({r['domains']} domains)"
                        if r.get("domains") is not None else r["profile"]
                        for r in ok
                    ]
                    st.success(f"Reconfigured: {', '.join(parts)}")
                for r in failed:
                    # Stale bind mount: squid -k reconfigure exited 0 but
                    # loaded an empty ACL because the host file rewrite
                    # broke the single-file bind mount inode. Recovery is
                    # a force-recreate of the proxy container — offer it
                    # as a one-click button rather than make the user
                    # paste a compose command.
                    if r.get("needs_recreate"):
                        st.error(f"**{r['profile']}**: {r['msg']}")
                        if st.button(
                            f"🔧 Recreate egress-proxy-{r['profile']}",
                            key=f"recreate_{r['profile']}",
                            type="primary",
                        ):
                            with st.spinner(
                                f"Recreating egress-proxy-{r['profile']}…"
                            ):
                                rc = docker_client.recreate_proxy(r["profile"])
                            if rc["ok"]:
                                # Re-run reload to refresh the count + clear
                                # the failed entry from last_reload_results.
                                st.session_state["last_reload_results"] = (
                                    docker_client.reload_all_proxies()
                                )
                                st.toast(
                                    f"egress-proxy-{r['profile']} recreated",
                                    icon="✅",
                                )
                                st.rerun()
                            else:
                                st.error(
                                    f"Recreate failed: {rc['msg']}"
                                )
                    else:
                        # Generic failure — surface squid syntax errors etc.
                        # squid validates before applying, so the OLD config
                        # is still in force.
                        st.error(f"{r['profile']}: {r['msg']}")

# --- Blocks (two columns) -------------------------------------------------
# Distribute blocks across two columns alternating (left, right, left, ...)
# so the visual flow reads top-to-bottom in each column. An odd block count
# leaves the right column one row short — fine.

# Section heading + inline legend on one row. Legend right-aligned so the
# eye lands on "Blocks" first, then picks up the pill key in peripheral
# vision. Pills + captions are rendered as a single HTML span so they sit
# on one line regardless of column width — using st.columns inside the
# right cell would re-introduce the wrap problems we had at the page foot.
bh_l, bh_r = st.columns([1, 2])
bh_l.subheader("Blocks")
_legend_html = (
    f'<div style="text-align:right; padding-top:0.6em; font-size:0.85em; '
    f'color:#52525b;">'
    f'{_pill("ON", "#16a34a")} all enabled &nbsp;·&nbsp; '
    f'{_pill("PARTIAL", "#d97706")} some enabled &nbsp;·&nbsp; '
    f'{_pill("OFF", "#71717a")} all commented out'
    f'</div>'
)
bh_r.markdown(_legend_html, unsafe_allow_html=True)

# `gap="large"` adds visible breathing room between the two block columns;
# without it the rightmost domain checkboxes in the LHS column run right up
# against the LHS edge of the RHS column and the eye can't tell where one
# block ends and the next begins.
block_cols = st.columns(2, gap="large")
for i, (tag, block_entries) in enumerate(blocks.items()):
    with block_cols[i % 2]:
        enabled_count = sum(1 for e in block_entries if not e.is_commented)
        total_count = len(block_entries)

        # Pill colour reflects state at a glance — green/amber/grey.
        if enabled_count == 0:
            pill = PILL_OFF
        elif enabled_count == total_count:
            pill = PILL_ON(total_count)
        else:
            pill = PILL_PARTIAL(enabled_count, total_count)

        # Block header row: name + status pill + on_click-driven on/off buttons.
        h_cols = st.columns([3, 2, 1, 1])
        h_cols[0].markdown(f"**{tag}**")
        h_cols[1].markdown(pill, unsafe_allow_html=True)
        h_cols[2].button(
            "All on", key=f"on_{tag}",
            on_click=_on_block_all, args=(tag, True),
        )
        h_cols[3].button(
            "All off", key=f"off_{tag}",
            on_click=_on_block_all, args=(tag, False),
        )

        # Individual domains. Expander label is STATIC — adding the dynamic
        # count here would change the label on every toggle, which Streamlit
        # treats as a different widget and rebuilds it collapsed. The pill
        # already shows the count.
        with st.expander(f"Domains in {tag}"):
            for e in block_entries:
                label = e.domain if not e.is_commented else f":gray[~~{e.domain}~~]"
                # `value=` is the read path; `on_change` is the write path.
                # Block-toggle / refresh callbacks pop the widget key first
                # (see _drop_dom_keys) so this `value=` actually takes effect
                # on those rerenders — Streamlit otherwise prefers the
                # existing session_state entry over a re-supplied `value`.
                st.checkbox(
                    label,
                    value=not e.is_commented,
                    key=f"dom_{tag}_{e.domain}",
                    on_change=_on_dom_toggle,
                    args=(tag, e.domain),
                )

st.divider()

# --- Add domain (bottom) -------------------------------------------------
# Constrained to the left half of the row so the input doesn't stretch
# across the whole page. Form ensures the text-input + selectbox commit
# together on Enter / Add.

add_l, _add_r = st.columns([1, 1])
with add_l:
    st.subheader("Add New Domain")
    with st.form("add_domain_form"):
        new_domain = st.text_input("Domain (e.g. .github.com)")
        target_block = st.selectbox(
            "Block", options=["ALWAYS ON"] + list(blocks.keys())
        )
        submitted = st.form_submit_button("Add")
        if submitted and new_domain:
            tag = None if target_block == "ALWAYS ON" else target_block
            config_io.add_domain(new_domain, block_tag=tag)
            # Re-read from disk and drop widget state — `value=` will
            # re-seed every checkbox (including the new one) on rerun.
            st.session_state.entries = config_io.read_allowed_domains()
            _drop_dom_keys()
            st.success(f"Added {new_domain}")
            st.rerun()

st.subheader("Current File Content (Preview)")
with st.expander("Show raw content"):
    raw_lines = []
    for entry in entries:
        if entry.domain:
            prefix = "# " if entry.is_commented else ""
            raw_lines.append(f"{prefix}{entry.domain}")
        else:
            raw_lines.append(entry.raw_line.strip())
    st.code("\n".join(raw_lines))

# Legend lives at the top of the Blocks section now (next to the heading)
# rather than at the page foot — see the bh_l / bh_r row above.
