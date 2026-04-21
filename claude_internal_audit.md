I'd like your help auditing the isolation posture of a development sandbox
I built and own. You are currently running inside it. This is a self-audit
of my own system — the output is a report I'll use to tighten my own
configuration. Nothing here targets a third party, and nothing leaves
this machine.

Your working directory is /workspace, which is the repo root. Before
doing anything else, read these files (they document intended behavior;
your job is to verify reality matches):

- ./CLAUDE.md          — invariants, gotchas, and the rationale behind them
- ./Dockerfile         — what's preinstalled (use this as your tool
                         inventory; do not attempt to install anything)
- ./docker-compose.yml — runtime config (caps, networks, mounts, env)
- ./seccomp.json       — the seccomp allowlist; review it white-box
                         before any syscall probing
- ./scripts/verify-sandbox.sh (if present) — existing checks you can
                         reuse or learn from

This is verification, not discovery from scratch. For each documented
invariant, confirm it holds at runtime; drift is the interesting
finding. Prefer reading config and /proc over running probes.

Environment context:
- Host: macOS
- VM: Colima (Lima-based, virtiofs mounts)
- Container: Ubuntu 24.04, agent runs as UID 1000

Ground rules (read-only audit):
- Read-only enumeration. Do not modify files outside /tmp.
- Do not install packages, add users, or change persistent state.
- No destructive probes: no fork bombs, no filesystem fill, no killing
  processes you didn't start, no kernel panics.
- No outbound traffic to third parties. Egress already goes through a
  local Squid proxy with an allowlist; stay within that. You MAY
  intentionally request a domain NOT on the allowlist for the sole
  purpose of confirming the proxy blocks it — that's a local control
  test of my own infrastructure.
- If confirming a finding would require a state-changing action,
  describe the test and the expected signal instead of running it,
  and flag it for my review.
- Stop and ask before anything you're unsure about.

Scope — verify and report on:

1. Identity & privileges: uid/gid, effective and bounding capabilities
   (capsh --print or reading /proc/self/status), no_new_privs, sudo/suid
   presence. Expected: UID 1000 "agent", empty capability sets,
   no_new_privs=1, no sudo.
2. MAC: AppArmor/SELinux status and any applied profile.
3. Seccomp — white-box first: read ./seccomp.json and note which syscall
   classes it allows/denies and its default action. Then spot-check at
   runtime: confirm syscalls that should be blocked return the expected
   errno (e.g. unshare(CLONE_NEWUSER) → EPERM, clone3 → ENOSYS so glibc
   falls back), and syscalls that must work do (mknod for mkfifo,
   getpgid for bash job control, rseq for thread init). Use small
   throwaway probes in /tmp.
4. Filesystem: mount table, ro vs rw, bind mounts from the host, SUID/SGID
   binaries, world-writable paths. Verify documented bind-mount state:
   ~/.claude.json is 644 and valid JSON; ~/.claude/.credentials.json
   (if present) is 600; ~/.config is agent-writable; ~/.vscode-server
   is a named volume, not a virtiofs bind.
5. /proc and /sys exposure: masked paths, readability of /proc/kcore,
   /proc/sys/kernel/*, /sys/kernel/*.
6. PID namespace & process visibility: PID of init as seen from the
   container, total visible processes, whether any host/VM processes
   leak in.
7. Devices: /dev contents; any host devices passed through.
8. Cgroups: v1 vs v2, visible limits, writable controllers.
9. Network & egress: interfaces, routes, whether host netns is shared,
   reachable hosts on the container's bridge. Then confirm egress
   control: (a) a domain on proxy/allowed_domains.txt succeeds via
   proxy, (b) a domain NOT on the list is refused by the proxy,
   (c) direct egress bypassing the proxy fails (sandbox-internal is
   declared internal: true).
10. Colima/VM boundary: identify signals that this is a Lima/Colima VM
    (virtiofs mount tags, /mnt/lima-* paths, kernel hints) and note
    what — if anything — is visible about the VM or host from inside.
    Do not attempt to cross the VM boundary.
11. Kernel: uname -a. CVE enumeration is out of scope (no internet,
    and the kernel belongs to the VM, not this container).
12. Secrets hygiene: env vars, mounted config, anything credential-like
    in the agent's home. Redact values in the report.

Output a single markdown report:
- One section per area above.
- Each invariant tagged OK / DRIFT / WEAK / UNKNOWN, with expected
  vs. observed state.
- A "Recommended hardening" section with concrete, minimal changes
  (file + line where possible).
- A chronological command log, outputs trimmed to what supports a
  finding, so I can reproduce.

Before running anything, read the files above, then summarize your plan
in one paragraph: what you'll check, what local probes you intend to
run, and anything you want me to approve up front. Wait for my go-ahead.