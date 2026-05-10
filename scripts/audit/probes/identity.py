"""§1 identity, privileges, SUID inventory, plus §2 MAC.

Stdlib only. Self-targeted reads of /proc and a single `find` for SUID."""
import os
import stat
import subprocess

# The stock Ubuntu 24.04 SUID/SGID set baked into the base image. Anything
# outside this set is drift. Maps to CLAUDE.md §"Non-negotiable invariants".
EXPECTED_SUID = {
    "chage", "chfn", "chsh", "expiry", "gpasswd", "mount", "newgrp",
    "pam_extrausers_chkpwd", "passwd", "su", "umount", "unix_chkpwd",
}


def _proc_status():
    fields = {}
    try:
        with open("/proc/self/status") as f:
            for line in f:
                if ":" in line:
                    k, v = line.split(":", 1)
                    fields[k.strip()] = v.strip()
    except OSError:
        pass
    return fields


def _which(cmd):
    for d in os.environ.get("PATH", "").split(":"):
        p = os.path.join(d, cmd)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return ""


def _check(section, name, ok, **details):
    return {
        "section": section,
        "name": name,
        "verdict": "OK" if ok else "DRIFT",
        "details": details,
    }


def run():
    out = []
    s = _proc_status()

    # uid / gid — agent container runs as 1000:1000.
    uid, gid = os.getuid(), os.getgid()
    out.append(_check("identity", "uid", uid == 1000, expected=1000, observed=uid))
    out.append(_check("identity", "gid", gid == 1000, expected=1000, observed=gid))

    # CapEff/Prm/Inh/Bnd/Amb all zero — cap_drop: ALL.
    cap_eff = s.get("CapEff", "")
    out.append(_check(
        "identity", "capabilities",
        cap_eff == "0000000000000000",
        expected="0000000000000000",
        observed=cap_eff,
    ))

    # NoNewPrivs — SUID neutralization.
    nnp = s.get("NoNewPrivs", "")
    out.append(_check(
        "identity", "no_new_privs",
        nnp == "1",
        expected="1", observed=nnp,
    ))

    # Seccomp mode 2 (filter active). The /proc/self/status `Seccomp` line
    # is just `Seccomp: 2`; `Seccomp_filters` is a separate line we ignore.
    seccomp_mode = (s.get("Seccomp", "").split() or [""])[0]
    out.append(_check(
        "identity", "seccomp_mode",
        seccomp_mode == "2",
        expected="2", observed=seccomp_mode,
    ))

    # sudo — must be absent.
    sudo = _which("sudo")
    out.append(_check(
        "identity", "sudo_absent",
        not sudo,
        expected="(absent)", observed=sudo or "(absent)",
    ))

    # SUID/SGID inventory — drift = something outside the stock set.
    try:
        result = subprocess.run(
            ["find", "/", "-xdev", "-perm", "/6000", "-type", "f"],
            capture_output=True, text=True, timeout=30,
        )
        actual = {os.path.basename(p) for p in result.stdout.splitlines() if p}
        unexpected = sorted(actual - EXPECTED_SUID)
        missing = sorted(EXPECTED_SUID - actual)
        out.append({
            "section": "identity",
            "name": "suid_inventory",
            "verdict": "OK" if (not unexpected and not missing) else "DRIFT",
            "details": {
                "expected": sorted(EXPECTED_SUID),
                "observed": sorted(actual),
                "unexpected": unexpected,
                "missing": missing,
            },
        })
    except Exception as e:
        out.append({
            "section": "identity",
            "name": "suid_inventory",
            "verdict": "UNKNOWN",
            "details": {"error": f"{type(e).__name__}: {e}"},
        })

    # §2 MAC — AppArmor profile (Docker-default in enforce mode is the
    # baseline). SELinux not present on Ubuntu hosts.
    apparmor = ""
    try:
        with open("/proc/self/attr/current") as f:
            apparmor = f.read().strip()
    except OSError:
        pass
    selinux_present = os.path.isdir("/sys/fs/selinux")
    apparmor_ok = "docker-default" in apparmor and "(enforce)" in apparmor
    out.append({
        "section": "mac",
        "name": "apparmor_profile",
        "verdict": "OK" if apparmor_ok else "WEAK",
        "details": {
            "observed": apparmor,
            "selinux_present": selinux_present,
        },
    })

    return out


if __name__ == "__main__":
    import json
    import sys
    json.dump(run(), sys.stdout, indent=2)
    print()
