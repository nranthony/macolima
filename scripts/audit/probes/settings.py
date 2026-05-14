"""§12 Claude Code settings audit.

- Live settings.json present + parses.
- sandbox.enabled = false (Claude Code's bwrap is correctly disabled).
- No bare WebFetch in user-level allow.
- All required deny categories present (audit H1 + L7 tightening).
- Live vs. template diff (excluding documented user-customization keys).
- Per-project settings.local.json walk for bare/wildcard WebFetch."""
import json
import os
import subprocess

LIVE = "/home/agent/.claude/settings.json"
TEMPLATE = "/workspace/temp_audit_package/config/claude-settings.json"
HOOK_PATH = "/usr/local/lib/claude-hooks/deny-destructive.sh"

# Required PreToolUse hooks. Both matchers must point at the in-image
# deny-destructive.sh; per-profile customisation is intentionally out of
# scope (see docs/deny-destructive-hook-plan.md "Out of scope").
REQUIRED_HOOKS = [
    {"matcher": "Bash",                 "command_endswith": "deny-destructive.sh"},
    {"matcher": "Edit|Write|MultiEdit", "command_endswith": "deny-destructive.sh"},
]

# These three keys are documented user-customization fields seeded after
# first `up` and intentionally not template-mirrored. Strip before diffing.
USER_CUSTOMIZATION_KEYS = {"theme", "model", "effortLevel"}

# Required permissions.deny set — covers audits H1 and L7 tightening.
# Categories are display-only; verification is per-entry membership.
REQUIRED_DENY = {
    "network": [
        "Bash(curl:*)", "Bash(wget:*)", "Bash(socat:*)", "Bash(nc:*)",
        "Bash(ncat:*)", "Bash(netcat:*)", "Bash(telnet:*)",
        "Bash(ssh:*)", "Bash(scp:*)", "Bash(sftp:*)", "Bash(rsync:*)",
    ],
    "vcs": [
        "Bash(git push:*)", "Bash(git clone:*)", "Bash(git fetch:*)",
        "Bash(git pull:*)", "Bash(gh:*)", "Bash(glab:*)",
    ],
    "installers": [
        "Bash(npm install:*)", "Bash(npm ci:*)", "Bash(npx:*)",
        "Bash(pip install:*)", "Bash(pip3 install:*)",
        "Bash(python -m pip:*)", "Bash(python3 -m pip:*)",
        "Bash(uv add:*)", "Bash(uv pip install:*)",
        "Bash(uv tool install:*)", "Bash(uvx:*)", "Bash(pipx:*)",
        "Bash(cargo install:*)", "Bash(go install:*)", "Bash(go get:*)",
    ],
    "shell_escape": [
        "Bash(bash -c:*)", "Bash(sh -c:*)", "Bash(zsh -c:*)",
        "Bash(uv run bash:*)", "Bash(uv run sh:*)", "Bash(uv run zsh:*)",
        "Bash(python -c:*)", "Bash(python3 -c:*)", "Bash(node -e:*)",
        "Bash(perl -e:*)", "Bash(perl:*)", "Bash(ruby:*)", "Bash(lua:*)",
        "Bash(env:*)", "Bash(xargs:*)", "Bash(eval:*)",
    ],
    "L7_vectors": [
        "Bash(awk:*)", "Bash(sed:*)", "Bash(ssh-keygen:*)",
        "Bash(git submodule:*)", "Bash(git config:*)",
    ],
    "destructive": [
        "Bash(rm -rf:*)", "Bash(git reset --hard:*)", "Bash(git rebase:*)",
    ],
    "system": [
        "Bash(docker:*)", "Bash(sudo:*)", "Bash(mount:*)", "Bash(umount:*)",
    ],
    "read_patterns": [
        "Read(**/.env)", "Read(**/.env.*)",
        "Read(**/*.pem)", "Read(**/*.key)",
        "Read(**/.credentials*)",
        "Read(**/id_rsa*)", "Read(**/id_ed25519*)",
    ],
}


def _check(name, ok, **details):
    return {
        "section": "settings",
        "name": name,
        "verdict": "OK" if ok else "DRIFT",
        "details": details,
    }


def run():
    out = []

    if not os.path.isfile(LIVE):
        return [{
            "section": "settings",
            "name": "live_settings_present",
            "verdict": "DRIFT",
            "details": {"error": f"missing: {LIVE}"},
        }]
    try:
        live = json.load(open(LIVE))
    except Exception as e:
        return [{
            "section": "settings",
            "name": "live_settings_parse",
            "verdict": "DRIFT",
            "details": {"error": f"{type(e).__name__}: {e}"},
        }]

    # sandbox.enabled = false — Claude Code's bwrap can't run inside this
    # container (seccomp blocks user namespaces by design). Container is
    # the boundary; bwrap-inside-container would block Bash entirely.
    sandbox_enabled = (live.get("sandbox", {}).get("enabled") is True)
    out.append(_check(
        "sandbox_enabled_false",
        not sandbox_enabled,
        observed=live.get("sandbox", {}).get("enabled"),
        rationale="Claude Code bwrap is disabled by design; container is the boundary",
    ))

    # No bare WebFetch / WebFetch(*) in user-level allow.
    user_allow = live.get("permissions", {}).get("allow", [])
    bare_or_wild = [
        e for e in user_allow
        if e == "WebFetch" or e == "WebFetch(*)" or
           (e.startswith("WebFetch") and not e.startswith("WebFetch(domain:"))
    ]
    out.append(_check(
        "no_bare_webfetch_user",
        not bare_or_wild,
        found=bare_or_wild,
        rationale=("WebFetch runs server-side on Anthropic infra; bare entry "
                   "is a covert exfil channel since destination logs full URL"),
    ))

    # Required deny categories.
    user_deny = set(live.get("permissions", {}).get("deny", []))
    deny_drift = {}
    for category, expected in REQUIRED_DENY.items():
        missing = [e for e in expected if e not in user_deny]
        if missing:
            deny_drift[category] = missing
    out.append(_check(
        "required_deny_categories",
        not deny_drift,
        drift=deny_drift,
        checked_count=sum(len(v) for v in REQUIRED_DENY.values()),
    ))

    # Live vs. template diff.
    if os.path.isfile(TEMPLATE):
        try:
            template = json.load(open(TEMPLATE))
            live_filtered = {
                k: v for k, v in live.items()
                if k not in USER_CUSTOMIZATION_KEYS
            }
            ok = (json.dumps(live_filtered, sort_keys=True) ==
                  json.dumps(template, sort_keys=True))
            details = {"identical_after_strip": ok,
                       "stripped_keys": sorted(USER_CUSTOMIZATION_KEYS)}
            if not ok:
                diff_keys = set()
                for k in set(live_filtered.keys()) | set(template.keys()):
                    if live_filtered.get(k) != template.get(k):
                        diff_keys.add(k)
                details["differing_top_level_keys"] = sorted(diff_keys)
            out.append(_check("template_diff", ok, **details))
        except Exception as e:
            out.append({
                "section": "settings",
                "name": "template_diff",
                "verdict": "UNKNOWN",
                "details": {"error": f"{type(e).__name__}: {e}"},
            })
    else:
        out.append({
            "section": "settings",
            "name": "template_diff",
            "verdict": "UNKNOWN",
            "details": {"error": f"missing: {TEMPLATE}"},
        })

    # Per-project settings.local.json walk for WebFetch policy.
    try:
        result = subprocess.run(
            ["find", "/workspace", "-name", "settings.local.json",
             "-path", "*/.claude/*",
             "-not", "-path", "*/temp_audit_package/*"],
            capture_output=True, text=True, timeout=10,
        )
        project_files = [p for p in result.stdout.splitlines() if p]
    except Exception:
        project_files = []

    project_drift = []
    project_summary = []
    for path in project_files:
        try:
            j = json.load(open(path))
        except Exception as e:
            project_drift.append({
                "file": path,
                "error": f"{type(e).__name__}: {e}",
            })
            continue
        allow = j.get("permissions", {}).get("allow", [])
        bare = [
            e for e in allow
            if e == "WebFetch" or e == "WebFetch(*)" or
               (e.startswith("WebFetch") and not e.startswith("WebFetch(domain:"))
        ]
        scoped = [e for e in allow if e.startswith("WebFetch(domain:")]
        if bare:
            project_drift.append({"file": path, "bare_or_wildcard": bare})
        project_summary.append({
            "file": path,
            "scoped_count": len(scoped),
            "scoped_domains": [
                e[len("WebFetch(domain:"):-1] for e in scoped
            ],
        })
    out.append(_check(
        "per_project_webfetch_scoped",
        not project_drift,
        drift=project_drift,
        summary=project_summary,
    ))

    # PreToolUse hooks: matcher wiring + on-disk file invariants.
    out.extend(_check_hooks(live))

    return out


def _check_hooks(live):
    """deny-destructive PreToolUse hook checks (audit L8).

    Two surfaces:
      1. settings.json wires both matchers to the in-image hook.
      2. The hook file is in-image, root-owned, executable, and the agent
         (UID 1000 — this probe runs as agent inside the container) has no
         write access. The kernel write-protect is the boundary; the
         matched Edit-tamper rule is defence in depth on top.
    """
    assert os.geteuid() != 0, "audit probe must run as the agent UID, not root"
    out = []
    hooks_cfg = (live or {}).get("hooks", {}).get("PreToolUse", []) or []
    for req in REQUIRED_HOOKS:
        present = any(
            entry.get("matcher") == req["matcher"]
            and any(h.get("command", "").endswith(req["command_endswith"])
                    for h in entry.get("hooks", []))
            for entry in hooks_cfg
        )
        out.append(_check(
            f"hook_present_{req['matcher'].replace('|','_')}",
            present,
            required=req,
        ))

    try:
        st = os.stat(HOOK_PATH)
        exists = True
        root_owned = (st.st_uid == 0)
        executable = bool(st.st_mode & 0o111)
        agent_writable = os.access(HOOK_PATH, os.W_OK)
    except FileNotFoundError:
        exists = root_owned = executable = False
        agent_writable = None
    out.append(_check(
        "hook_file_immutable",
        exists and root_owned and executable and not agent_writable,
        path=HOOK_PATH, exists=exists, root_owned=root_owned,
        executable=executable, agent_writable=agent_writable,
        rationale="hook must be in-image, root:root, 0755, not writable by agent",
    ))
    return out


if __name__ == "__main__":
    import sys
    json.dump(run(), sys.stdout, indent=2)
    print()
