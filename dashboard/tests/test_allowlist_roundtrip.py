#!/usr/bin/env python3
"""Locks the dashboard's allowlist parser against the LIVE proxy/allowed_domains.txt.

This code rewrites the file that decides what the agent can reach, so the
properties below are not style preferences:

  1. read -> write is byte-identical. A parser that drops or reflows a line
     silently rewrites the egress policy the next time someone clicks Save.
  2. No domain is parsed outside a block. The parser recognises a bare dotted
     token as a domain ANYWHERE, so a prose line that happens to be one word
     would become a toggleable "domain" — the same failure shape as the
     open_section() prose bug fixed in with-egress.sh (work/0001 A4). Zero
     orphans today; this says so the moment that stops being true.
  3. No domain inherits a block tag across a bare section divider, which would
     let "All on" for one block uncomment entries under another.
  4. Every live block tag maps to a real category. Unmapped tags fall to
     "Other" by design (a missing mapping must not break the page), so without
     this check they would accumulate there unnoticed.
  5. add_domain inherits the block's comment state. Adding a host to a block
     that is commented out by default (e.g. [pypi], planning-mode) must not
     silently open egress. windows-ai-sandbox's copy of ConfigIO dropped this.

Runs against a COPY for anything that writes. Never mutates the real file.

Usage:  dashboard/.venv/bin/python dashboard/tests/test_allowlist_roundtrip.py
        (or: just test-dashboard)
"""

from __future__ import annotations

import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DASH = os.path.dirname(HERE)
REPO = os.path.dirname(DASH)
sys.path.insert(0, os.path.join(DASH, "src"))

from lib.config_io import ConfigIO                      # noqa: E402
from lib.proxy_categories import category_for           # noqa: E402

PASS = FAIL = 0


def ok(msg: str) -> None:
    global PASS
    PASS += 1
    print(f"  ok   {msg}")


def bad(msg: str, detail: str = "") -> None:
    global FAIL
    FAIL += 1
    print(f"  FAIL {msg}")
    if detail:
        print(f"       {detail}")


def serialize(entries) -> str:
    out = []
    for e in entries:
        if e.domain:
            out.append(("# " if e.is_commented else "") + e.domain + "\n")
        else:
            out.append(e.raw_line)
    return "".join(out)


def main() -> int:
    print("-- dashboard allowlist parser --")
    io = ConfigIO(REPO)
    original = open(io.allowed_domains_path).read()
    entries = io.read_allowed_domains()
    domains = [e for e in entries if e.domain]

    # 1. round-trip
    if serialize(entries) == original:
        ok(f"read->write is byte-identical ({len(domains)} domains, "
           f"{sum(1 for e in domains if e.is_commented)} commented)")
    else:
        import difflib
        d = [l for l in difflib.unified_diff(
            original.splitlines(), serialize(entries).splitlines(), lineterm="", n=0)]
        bad("read->write CHANGED the file", "\n       ".join(d[2:12]))

    # 2. orphans
    orphans = [e.raw_line.rstrip() for e in domains if not e.block_tag]
    if not orphans:
        ok("no domain parsed outside a block")
    else:
        bad(f"{len(orphans)} domain(s) parsed outside any block",
            "; ".join(repr(o) for o in orphans[:5]))

    # 3. tag bleed across a bare divider
    tag = ""
    bleed = []
    for e in entries:
        raw = e.raw_line.rstrip()
        if raw.startswith("# ===") or (raw.startswith("# ---") and "[" not in raw):
            tag = "<divider>"
        elif e.block_tag:
            tag = e.block_tag
        if e.domain and tag == "<divider>":
            bleed.append(raw)
    if not bleed:
        ok("no domain inherits a tag across a bare section divider")
    else:
        bad(f"{len(bleed)} domain(s) inherit a tag across a divider",
            "; ".join(repr(b) for b in bleed[:5]))

    # 4. category coverage
    tags = sorted({e.block_tag for e in entries if e.block_tag})
    unmapped = [t for t in tags if category_for(t) == "Other"]
    if not unmapped:
        ok(f"all {len(tags)} live block tags map to a real category")
    else:
        bad(f"{len(unmapped)} block tag(s) fall into 'Other'",
            "add them to CATEGORY_TAGS in lib/proxy_categories.py: "
            + ", ".join(unmapped))

    # 5. add_domain inherits comment state (writes to a COPY)
    with tempfile.TemporaryDirectory() as td:
        os.makedirs(os.path.join(td, "proxy"))
        shutil.copy(io.allowed_domains_path, os.path.join(td, "proxy", "allowed_domains.txt"))
        tio = ConfigIO(td)
        # pick a block whose domains are ALL commented out
        blocks: dict[str, list] = {}
        for e in tio.read_allowed_domains():
            if e.block_tag and e.domain:
                blocks.setdefault(e.block_tag, []).append(e)
        off_block = next(
            (t for t, es in blocks.items() if es and all(e.is_commented for e in es)),
            None,
        )
        if off_block is None:
            bad("no fully-commented block to test add_domain against",
                "the fixture (the live allowlist) has no OFF block")
        else:
            tio.add_domain("probe.example.com", block_tag=off_block)
            added = [e for e in tio.read_allowed_domains()
                     if e.domain == "probe.example.com"]
            if added and added[0].is_commented:
                ok(f"add_domain inherits comment state (added to [{off_block}] "
                   f"commented, not live)  <-- EGRESS LOCK")
            elif added:
                bad(f"add_domain added a LIVE domain to the commented block "
                    f"[{off_block}] — this silently opens egress",
                    "ConfigIO.add_domain must inherit the block's comment state")
            else:
                bad("add_domain wrote nothing back")

    # 6. the whole app actually renders. Streamlit swallows a view-module
    # exception into an on-page error box, so "it imports" proves very little;
    # AppTest runs the real script and collects what blew up.
    try:
        from streamlit.testing.v1 import AppTest
        at = AppTest.from_file(os.path.join(DASH, "src", "app.py"),
                               default_timeout=60).run()
        if at.exception:
            bad(f"app.py raised {len(at.exception)} exception(s) on render",
                "; ".join(str(e.value) for e in at.exception[:3]))
        elif len(at.tabs) != 2:
            bad(f"expected 2 tabs (Status, Proxy Allowlist), got {len(at.tabs)}")
        elif len(at.checkbox) != len(domains):
            bad(f"rendered {len(at.checkbox)} domain checkboxes, "
                f"parser found {len(domains)} domains",
                "every domain must be reachable in the UI")
        else:
            ok(f"app.py renders clean: 2 tabs, {len(at.checkbox)} domain "
               f"checkboxes, {len(at.metric)} status metrics")
    except ImportError:
        bad("streamlit.testing unavailable — render not verified")

    # the real file must be untouched
    if open(io.allowed_domains_path).read() == original:
        ok("the live allowed_domains.txt was not modified by this test")
    else:
        bad("THIS TEST MODIFIED THE LIVE ALLOWLIST", "restore it from git now")

    print(f"\n  {PASS} passed, {FAIL} failed\n")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
