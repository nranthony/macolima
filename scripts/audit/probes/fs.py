"""§4 filesystem invariants, §5 /proc & /sys exposure, §6 PIDs, §7 devices, §8 cgroups."""
import json
import os
import stat
import subprocess


def _check(section, name, ok, **details):
    return {
        "section": section,
        "name": name,
        "verdict": "OK" if ok else "DRIFT",
        "details": details,
    }


def _findmnt(target):
    """Return findmnt -no SOURCE,FSTYPE,OPTIONS for `target`, or None."""
    try:
        r = subprocess.run(
            ["findmnt", "-no", "SOURCE,FSTYPE,OPTIONS", target],
            capture_output=True, text=True, timeout=5,
        )
        if r.returncode != 0:
            return None
        parts = r.stdout.strip().split(maxsplit=2)
        return {
            "source":  parts[0] if len(parts) > 0 else "",
            "fstype":  parts[1] if len(parts) > 1 else "",
            "options": parts[2] if len(parts) > 2 else "",
        }
    except Exception:
        return None


def _stat_file(path):
    try:
        st = os.stat(path)
        return {
            "mode": stat.S_IMODE(st.st_mode),
            "uid":  st.st_uid,
            "gid":  st.st_gid,
            "size": st.st_size,
        }
    except OSError as e:
        return {"error": f"{type(e).__name__}: {e}"}


def run():
    out = []

    # ~/.claude.json — virtiofs single-file bind, mode 644, valid JSON.
    # Single-file binds on Colima virtiofs don't UID-remap, so 600 would
    # appear root:root and unreadable to agent.
    info = _stat_file("/home/agent/.claude.json")
    ok = (info.get("mode") == 0o644
          and info.get("uid") == 1000
          and info.get("gid") == 1000)
    if ok:
        try:
            json.load(open("/home/agent/.claude.json"))
        except Exception as e:
            ok = False
            info["json_parse_error"] = f"{type(e).__name__}: {e}"
    out.append(_check(
        "fs", "claude_json", ok,
        expected="mode=644 uid=1000 gid=1000 valid-json",
        **info,
    ))

    # ~/.claude/.credentials.json — mode 600 (inside dir bind, UID-remap path).
    cred = "/home/agent/.claude/.credentials.json"
    if os.path.exists(cred):
        info = _stat_file(cred)
        ok = info.get("mode") == 0o600
        out.append(_check("fs", "credentials_json", ok, expected="mode=600", **info))
    else:
        out.append({
            "section": "fs",
            "name": "credentials_json",
            "verdict": "N/A",
            "details": {"note": "not present (no Claude login on this profile)"},
        })

    # ~/.gitconfig MUST NOT exist (use GIT_CONFIG_GLOBAL → .config/git/config).
    gitcfg_present = os.path.exists("/home/agent/.gitconfig")
    out.append(_check(
        "fs", "no_gitconfig_bindmount", not gitcfg_present,
        expected="absent",
        observed="present" if gitcfg_present else "absent",
    ))
    git_config_global = os.environ.get("GIT_CONFIG_GLOBAL", "")
    out.append(_check(
        "fs", "git_config_global_env",
        git_config_global == "/home/agent/.config/git/config",
        expected="/home/agent/.config/git/config",
        observed=git_config_global or "(unset)",
    ))

    # ~/.vscode-server and ~/.cache MUST be named volumes (ext4), not virtiofs.
    # Virtiofs mishandles utime/chmod during archive/wheel extraction; named
    # volumes live in the VM's ext4 and bypass virtiofs entirely.
    for path in ["/home/agent/.vscode-server", "/home/agent/.cache"]:
        m = _findmnt(path)
        if m is None:
            out.append({
                "section": "fs",
                "name": f"named_volume_{os.path.basename(path)}",
                "verdict": "UNKNOWN",
                "details": {"path": path, "note": "not a mount point"},
            })
            continue
        ok = m["fstype"] == "ext4"
        out.append(_check(
            "fs", f"named_volume_{os.path.basename(path)}", ok,
            expected="ext4 (named volume)",
            **m,
        ))

    # tmpfs under /home/agent/ MUST have uid=1000,gid=1000 — bare tmpfs comes
    # up root:root and shadows the Dockerfile-created agent-owned dir.
    for path in ["/home/agent/.local", "/home/agent/.npm-global"]:
        m = _findmnt(path)
        if m is None:
            continue
        opts = m["options"]
        ok = "uid=1000" in opts and "gid=1000" in opts
        out.append(_check(
            "fs", f"tmpfs_owner_{os.path.basename(path)}", ok,
            expected="uid=1000,gid=1000",
            **m,
        ))

    # /tmp — system tmpfs (root-owned is correct here).
    m = _findmnt("/tmp")
    if m:
        out.append({
            "section": "fs",
            "name": "tmp_tmpfs",
            "verdict": "OK" if m["fstype"] == "tmpfs" else "DRIFT",
            "details": m,
        })

    # /proc/kcore MUST be masked (Docker default — char dev returning EIO).
    try:
        st = os.stat("/proc/kcore")
        # Masked = char device (Docker bind-mounts /dev/null over it).
        masked = stat.S_ISCHR(st.st_mode)
        out.append(_check(
            "fs", "proc_kcore_masked", masked,
            expected="character device (masked)",
            mode_octal=oct(st.st_mode),
        ))
    except OSError as e:
        out.append({
            "section": "fs",
            "name": "proc_kcore_masked",
            "verdict": "UNKNOWN",
            "details": {"error": str(e)},
        })

    # /sys/firmware MUST be empty (Docker MaskedPaths).
    try:
        contents = os.listdir("/sys/firmware")
        out.append(_check(
            "fs", "sys_firmware_masked", not contents,
            expected="empty",
            observed_count=len(contents),
        ))
    except OSError as e:
        out.append({
            "section": "fs",
            "name": "sys_firmware_masked",
            "verdict": "UNKNOWN",
            "details": {"error": str(e)},
        })

    # /dev — host devices MUST NOT be passed through.
    expected_dev = {
        "null", "full", "random", "urandom", "zero", "tty", "ptmx",
        "console", "stdin", "stdout", "stderr", "fd", "core",
        "pts", "shm", "mqueue",
    }
    try:
        actual_dev = set(os.listdir("/dev/"))
        unexpected = sorted(actual_dev - expected_dev)
        out.append({
            "section": "fs",
            "name": "dev_inventory",
            "verdict": "OK" if not unexpected else "DRIFT",
            "details": {
                "expected": sorted(expected_dev),
                "observed": sorted(actual_dev),
                "unexpected": unexpected,
            },
        })
    except OSError as e:
        out.append({
            "section": "fs",
            "name": "dev_inventory",
            "verdict": "UNKNOWN",
            "details": {"error": str(e)},
        })

    # cgroups v2 unified hierarchy, mounted read-only.
    m = _findmnt("/sys/fs/cgroup")
    if m:
        opts = m["options"].split(",")
        ok = m["fstype"] == "cgroup2" and "ro" in opts
        out.append(_check(
            "fs", "cgroups_v2_readonly", ok,
            expected="cgroup2 ro",
            **m,
        ))

    # pids.max — set to a reasonable bound, not "max".
    try:
        with open("/sys/fs/cgroup/pids.max") as f:
            pm = f.read().strip()
        out.append({
            "section": "fs",
            "name": "pids_max",
            "verdict": "OK" if pm not in ("max", "") else "WEAK",
            "details": {"observed": pm},
        })
    except OSError as e:
        out.append({
            "section": "fs",
            "name": "pids_max",
            "verdict": "UNKNOWN",
            "details": {"error": str(e)},
        })

    # §6 PID namespace — total visible PIDs and any UID-0 process besides PID 1.
    # Orphan UID-0 procs typically come from VS Code attach `usermod` runs
    # when devcontainer.json's "updateRemoteUserUID": false isn't set.
    try:
        result = subprocess.run(
            ["ps", "-eo", "pid,user", "--no-headers"],
            capture_output=True, text=True, timeout=5,
        )
        pids = []
        uid_0 = []
        for line in result.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 2:
                pid, user = parts[0], parts[1]
                pids.append(pid)
                if user in ("root", "0") and pid != "1":
                    uid_0.append({"pid": pid, "user": user})
        out.append({
            "section": "fs",
            "name": "pid_namespace",
            "verdict": "OK",
            "details": {
                "total_pids": len(pids),
                "pid1_present": "1" in pids,
            },
        })
        out.append({
            "section": "fs",
            "name": "no_orphan_uid0",
            "verdict": "OK" if not uid_0 else "DRIFT",
            "details": {
                "orphan_count": len(uid_0),
                "orphans": uid_0[:10],
            },
        })
    except Exception as e:
        out.append({
            "section": "fs",
            "name": "pid_namespace",
            "verdict": "UNKNOWN",
            "details": {"error": str(e)},
        })

    return out


if __name__ == "__main__":
    import sys
    json.dump(run(), sys.stdout, indent=2)
    print()
