# Porting macolima's hardening model to other host environments

Source-of-truth for the design and current invariants is `CLAUDE.md` at the
repo root. This file captures **only** the bits that don't apply on macOS +
Colima but matter when reproducing the same posture on another host —
specifically, WSL2 + rootless Docker on Windows, or rootless Docker on Linux.
It started as §4 + part of §7 of an earlier `sandbox-hardening-package.md`
that was otherwise duplicated by the audit reports and `CLAUDE.md`.

The VS Code Dev Containers leakage findings (SSH agent forwarding, host
`.gitconfig` copy, IPC credential helper, orphan UID-0 attach shell) and
their fixes are **platform-independent** — VS Code's behaviour is the same on
macOS, Linux, and Windows. The settings keys, the `devcontainer.json`
`remoteEnv`/`updateRemoteUserUID` trick, and the in-container `unset
SSH_AUTH_SOCK` all transfer verbatim. See CLAUDE.md → "VS Code Dev Containers
leakage hardening" for the current canonical fixes.

What changes per host environment is below.

---

## Rootless Docker (Linux host, or WSL2 with rootless setup)

Rootless Docker runs the daemon as a non-root user and uses
`newuidmap`/`newgidmap` to give it a subuid/subgid range (typically
`100000–165535`). That shifts the threat model in a few relevant ways:

1. **Container UID 0 maps to an unprivileged host UID** (e.g. host UID
   100000), not host root. The "orphan root shell at attach" finding from
   the macolima audit is materially less scary here — worst case it can
   scribble on an ephemeral overlay, and even that runs as a host-subuid
   user. Still worth fixing because drift is drift, but the blast radius
   is smaller than under rootful Docker.
2. **seccomp still applies identically.** The filter is enforced by the
   kernel regardless of daemon ownership. All the syscall-level invariants
   (`clone3 → ENOSYS`, `unshare(CLONE_NEWUSER)` blocked, `getpgid`/`rseq`/
   `pidfd_*`/xattr family allowed, etc.) hold unchanged.
3. **`cap_drop: ALL` still applies** — but the capabilities available to
   the daemon's user namespace are already reduced, so some of the caps
   being dropped were never held anyway. Doesn't hurt to drop them
   explicitly; keeps the compose file portable.
4. **User namespaces are already in use** for the daemon's own remapping.
   The seccomp filter blocking `unshare(CLONE_NEWUSER)` means the
   container *can't create nested* user namespaces inside its own
   sandbox, which is what you want.

Net: the macolima compose stack imports cleanly onto rootless Docker. No
syscall changes needed. The `user: "1000:1000"` directive maps to a host
subuid, not real UID 1000 — file ownership semantics on bind mounts may
look different than on rootful Docker, so test bind-mount writes early.

## WSL2 (Windows host)

1. **Filesystem.** Containers' overlay lives on the WSL2 distro's ext4 —
   fast, POSIX-compliant. Bind-mounting paths from `/mnt/c/...` (Windows
   NTFS via 9p) is slow and has UID/permission quirks analogous to
   virtiofs on macOS — **prefer bind mounts from the Linux filesystem**
   (`/home/<user>/...`) for the agent's state dir, workspace, and cache.
   The `.vscode-server` named-volume workaround macolima uses (because
   virtiofs mishandles `utime()` during VS Code server tarball
   extraction) isn't strictly necessary under WSL2 — ext4 handles utime
   fine — but doesn't hurt and gives identical semantics across hosts.
2. **Network.** WSL2 containers reach out through the WSL2 VM's NAT.
   Create the agent's network as `internal: true` the same way — Docker's
   network driver behaves identically. The egress proxy pattern transfers
   unchanged.
3. **`/Volumes` equivalent: n/a.** Use `/home/<user>/sandbox-profiles/`
   or similar on the Linux side. Don't put state under `/mnt/c/`.
4. **No Colima layer.** WSL2 *is* the VM. Skip any Colima-specific
   steps (`colima-up.sh`, `colima.yaml` flags). The Docker daemon runs
   directly inside the WSL2 distro.

## Minimum compose-file invariants for any host

If starting from scratch on another host rather than translating macolima's
compose file, these are the non-negotiables:

```yaml
services:
  agent:
    image: <your-image>
    user: "1000:1000"             # match the in-image non-root user
    cap_drop: [ALL]
    security_opt:
      - no-new-privileges:true
      - seccomp=./seccomp.json    # use macolima's seccomp.json verbatim
    tmpfs:
      - /tmp:size=1g,noexec,nosuid,nodev
      - /home/agent/.npm-global:size=512m,noexec,nosuid,nodev,uid=1000,gid=1000,mode=0755
      - /home/agent/.local:size=256m,noexec,nosuid,nodev,uid=1000,gid=1000,mode=0755
    pids_limit: 512
    mem_limit: 8g
    networks: [sandbox-internal]
    environment:
      - HTTP_PROXY=http://egress-proxy:3128
      - HTTPS_PROXY=http://egress-proxy:3128
      - NO_PROXY=localhost,127.0.0.1,egress-proxy
      - GIT_CONFIG_GLOBAL=/home/agent/.config/git/config
    command: ["sleep", "infinity"]   # required for VS Code Dev Containers attach

  egress-proxy:
    image: ubuntu/squid:latest
    cap_drop: [ALL]
    cap_add: [SETUID, SETGID]        # Squid drops privs at startup
    networks: [sandbox-internal, sandbox-external]

networks:
  sandbox-internal:
    driver: bridge
    internal: true                   # LOAD-BEARING — the egress cutoff
  sandbox-external:
    driver: bridge
```

`internal: true` on `sandbox-internal` is what makes the whole model work.
Without it, the proxy is a suggestion, not an enforcement point.

---

## Anti-patterns (apply on every host)

- **Don't re-enable Claude Code's in-process `bwrap` sandbox.** It needs
  unprivileged user namespaces, which the seccomp filter blocks. The
  container is the boundary; the in-process sandbox is redundant at best
  and a confusion vector at worst (every Bash call would fail with
  "No permissions to create new namespace").
- **Don't install `bubblewrap`, `socat`, or `openssh-client` in the
  image.** First was for the disabled in-process sandbox. Second was a
  raw-TCP exfil channel that bypasses Squid's HTTP-only egress. Third is
  the tool surface that weaponises VS Code's `SSH_AUTH_SOCK` forwarding
  — purging the package physically closes the SSH exfil path even if the
  env var or socket leaks in.
- **Don't widen the proxy allowlist to include `host.docker.internal` or
  equivalents** so the container can reach host services. That's the exact
  coupling the sandbox exists to prevent. If the agent needs real data,
  dump it into a sibling container on `sandbox-internal`.
- **Don't bind-mount `~/.gitconfig` as a single file.** `git config
  --global` writes via atomic `rename()`. Single-file bind mounts return
  EBUSY on `rename()` across the mount boundary on virtiofs (macOS) and
  have similar quirks on WSL 9p. Use `GIT_CONFIG_GLOBAL` pointing to a
  file inside a **directory** bind mount instead.
- **Don't set `read_only: true` on the agent container.** It breaks VS
  Code Dev Containers' environment setup (writes to `/etc/environment`).
  The security gain is zero given non-root + `cap_drop: ALL` already
  blocks system-dir writes.
