"""§9d allowed_domains.txt review + §9g squid.conf rule order.

White-box check on the staged proxy config. Required-core list, anti-pattern
detection, planning-mode-block-commented check, squid.conf ACL ordering."""
import os
import re

ALLOWED = "/workspace/temp_audit_package/proxy/allowed_domains.txt"
SQUID = "/workspace/temp_audit_package/proxy/squid.conf"

# Leaf hosts that MUST be on the allowlist — agent / Claude Code core paths.
REQUIRED_DOMAINS = [
    # Anthropic family — leaf hosts only, no wildcards (audit M3).
    "api.anthropic.com",
    "console.anthropic.com",
    "statsig.anthropic.com",
    "api.claude.com",
    "platform.claude.com",
    "claude.ai",
    # VS Code Marketplace.
    "marketplace.visualstudio.com",
    "update.code.visualstudio.com",
    ".vscode-unpkg.net",  # documented wildcard exception
]

# Single MS-controlled CDN parent that legitimately rotates subdomains.
# Anything else starting with "." is drift (audit M3 removed parent wildcards).
WILDCARD_EXCEPTION = {".vscode-unpkg.net"}

# Wildcards previously removed (audit M3) — reappearance = regression.
ANTI_WILDCARDS = [".anthropic.com", ".claude.com", ".claude.ai"]

# Section tags for the planning-mode block (commented-by-default in
# autonomous mode; with-egress.sh toggles them temporarily under flock).
PLANNING_TAGS = {"[git]", "[pypi]", "[npm]", "[nodejs]", "[apt]",
                 "[playwright-install]"}

# squid.conf ACL ordering — load-bearing for both M1 and H1.
EXPECTED_ACL_ORDER = [
    "acl Safe_ports port",
    "http_access deny !Safe_ports",            # M1: blocks all methods on non-{80,443}
    "acl SSL_ports",
    "acl CONNECT method",
    "http_access deny CONNECT !SSL_ports",     # H1: blocks CONNECT on anything but 443
    "http_access allow CONNECT SSL_ports",
    "http_access allow allowed_domains",
    "http_access deny all",
]


def _check(name, ok, **details):
    return {
        "section": "proxy",
        "name": name,
        "verdict": "OK" if ok else "DRIFT",
        "details": details,
    }


def run():
    out = []

    if not os.path.isfile(ALLOWED):
        return [{
            "section": "proxy",
            "name": "allowed_domains_present",
            "verdict": "UNKNOWN",
            "details": {"error": f"missing: {ALLOWED}"},
        }]

    with open(ALLOWED) as f:
        lines = f.read().splitlines()

    active = [l.strip() for l in lines
              if l.strip() and not l.strip().startswith("#")]

    # Required core entries — every one must be present.
    missing = [d for d in REQUIRED_DOMAINS if d not in active]
    out.append(_check(
        "required_core_present",
        not missing,
        missing=missing,
        checked=len(REQUIRED_DOMAINS),
    ))

    # Anti-wildcards — must not have been re-introduced.
    found_anti = [w for w in ANTI_WILDCARDS if w in active]
    out.append(_check(
        "no_vendor_wildcards",
        not found_anti,
        found=found_anti,
        rationale="audit M3 removed these; reappearance = regression",
    ))

    # Other wildcards (anything starting with "." that isn't the documented
    # exception). Generic catch — surfaces drift before it bites.
    other_wildcards = [d for d in active
                       if d.startswith(".") and d not in WILDCARD_EXCEPTION]
    out.append(_check(
        "no_other_wildcards",
        not other_wildcards,
        found=other_wildcards,
        allowed_exceptions=sorted(WILDCARD_EXCEPTION),
    ))

    # IP literals or host.docker.internal — re-couples agent to host services.
    suspicious = [
        d for d in active
        if re.match(r"^\d+\.\d+\.\d+", d) or d == "host.docker.internal"
    ]
    out.append(_check(
        "no_ip_or_host_docker_internal",
        not suspicious,
        found=suspicious,
    ))

    # Planning-mode block must be commented in autonomous-mode default.
    # Walk lines; track which tag we're in; flag any non-comment within a
    # planning tag's section.
    in_planning = False
    current_tag = None
    uncommented_planning = []
    for raw in lines:
        s = raw.strip()
        # Tag line look-up — anywhere a planning tag appears in a comment
        # header opens its block.
        m = re.search(r"\[[\w-]+\]", raw)
        if m and m.group(0) in PLANNING_TAGS:
            current_tag = m.group(0)
            in_planning = True
            continue
        # New top-level section header closes any planning block.
        if raw.startswith("# ===") or raw.startswith("# ---"):
            current_tag = None
            in_planning = False
            continue
        if in_planning and s and not s.startswith("#"):
            uncommented_planning.append({"line": raw, "tag": current_tag})

    out.append(_check(
        "planning_mode_commented",
        not uncommented_planning,
        uncommented=uncommented_planning[:10],
        count=len(uncommented_planning),
        rationale=("autonomous mode: planning-mode blocks should all be "
                   "commented; surviving uncommented entry = with-egress.sh "
                   "sentinel may be live (host-side check)"),
    ))

    # Per-profile additions — informational, not a verdict. The audit prompt
    # explicitly tells the agent these are for owner review, not drift.
    extras = [d for d in active if d not in REQUIRED_DOMAINS]
    out.append({
        "section": "proxy",
        "name": "per_profile_additions",
        "verdict": "INFO",
        "details": {"count": len(extras), "domains": extras},
    })

    # squid.conf rule order
    if not os.path.isfile(SQUID):
        out.append({
            "section": "proxy",
            "name": "squid_conf_present",
            "verdict": "UNKNOWN",
            "details": {"error": f"missing: {SQUID}"},
        })
        return out

    with open(SQUID) as f:
        squid_lines = [l.rstrip() for l in f]

    # Find positions of each expected rule (first non-comment match).
    found_positions = []
    for marker in EXPECTED_ACL_ORDER:
        pos = -1
        for i, l in enumerate(squid_lines):
            if l.lstrip().startswith("#"):
                continue
            if marker.lower() in l.lower():
                pos = i
                break
        found_positions.append({"marker": marker, "line": pos})

    positions = [p["line"] for p in found_positions]
    all_present = all(p > 0 for p in positions)
    in_order = all_present and positions == sorted(positions)
    out.append(_check(
        "squid_acl_order",
        in_order,
        positions=found_positions,
        rationale=("H1: deny CONNECT !SSL_ports MUST come before "
                   "allow allowed_domains — otherwise CONNECT host:80 "
                   "tunnels raw TCP on cleartext port 80"),
    ))

    # access_log present (audit L1 — forensic trail).
    has_log = any(
        "access_log " in l and not l.lstrip().startswith("#")
        for l in squid_lines
    )
    out.append(_check(
        "squid_access_log",
        has_log,
        rationale="audit L1: forensic trail of every proxied request",
    ))

    return out


if __name__ == "__main__":
    import json
    import sys
    json.dump(run(), sys.stdout, indent=2)
    print()
