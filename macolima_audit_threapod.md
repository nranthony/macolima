# macolima sandbox audit — profile `therapod`

**Date:** 2026-04-21
**Container:** `claude-agent-therapod` (compose project `macolima-therapod`)
**Audit basis:** staged config at `/workspace/temp_audit_package/` vs. runtime state observed from inside the container. Read-only probes only.
**Overall:** strong. All non-negotiable invariants from CLAUDE.md verified at runtime. Drift is minor, mostly cosmetic, and almost all is privilege-neutral due to defense-in-depth (caps dropped, NNP=1, seccomp). A few items surfaced that I'd flag for attention — SSH agent socket forwarded in from the host by VS Code, the `verify-sandbox.sh` script's three own bugs, a stray `/home/agent/.gitconfig` left by VS Code Dev Containers, and stock Ubuntu SUID binaries still present (neutralized by NNP but inconsistent with CLAUDE.md's "no suid" invariant).

---

## 1. Identity & privileges

| Invariant | Expected | Observed | Tag |
|---|---|---|---|
| UID/GID | 1000/1000 | `Uid: 1000 1000 1000 1000`; `Gid: 1000 1000 1000 1000` | **OK** |
| CapInh/Prm/Eff/Bnd/Amb | all zero | all `0000000000000000` | **OK** |
| `NoNewPrivs` | 1 | 1 | **OK** |
| sudo installed | no | `/usr/bin/sudo` absent; sudo group empty (`sudo:x:27:`) | **OK** |
| Agent never runs as root | no UID 0 | PID 3171 `/bin/sh` runs as UID 0 — but caps empty, NNP=1, seccomp mode 2 | **DRIFT (cosmetic)** |
| SUID binaries | none | 14 stock Ubuntu SUID/SGID binaries present (`su`, `passwd`, `mount`, `umount`, `chfn`, `chsh`, `newgrp`, `gpasswd`, `ssh-agent`, `ssh-keysign`, etc.) | **DRIFT / WEAK** |
| Ubuntu default `ubuntu` user removed | yes | `/etc/passwd` shows only `root` and `agent` | **OK** |
| PID 1 | tini | `/proc/1/exe → /usr/bin/tini`, cmdline `tini -- sleep infinity` | **OK** (also runs as UID 1000; unusual but fine) |

Notes:
- The root-UID shell (PID 3171) is almost certainly VS Code Dev Containers' post-attach init (`docker exec -u 0 ...`). Its parent died (PPid=0) and it was orphaned. Even so, it inherits the container's security ctx (CapBnd=0 at the container level means no process, regardless of UID, can gain caps). Security impact: nil. Documentation impact: CLAUDE.md line 17's "never root" isn't literally true at runtime.
- SUID bits are inert under `NoNewPrivs=1 + cap_drop: ALL` — SUID can't elevate. But CLAUDE.md line 17 claims "No suid binaries" as an invariant. That claim doesn't hold at the binary level, only at the effective-privilege level.

## 2. Mandatory Access Control

| Invariant | Expected | Observed | Tag |
|---|---|---|---|
| AppArmor/SELinux | some profile | AppArmor `docker-default (enforce)` via `/proc/self/attr/current` (no `/sys/kernel/security/lsm` present but attr enforced) | **OK** |

## 3. Seccomp

### White-box (`seccomp.json`)
- `defaultAction: SCMP_ACT_ERRNO, defaultErrnoRet: 1` (EPERM) — deny-by-default. **OK**
- `clone` — allowed with `SCMP_CMP_MASKED_EQ` against 0x7E020000 (CLONE_NEWUSER|NEWNS|NEWUTS|NEWIPC|NEWPID|NEWNET|NEWCGROUP). Any of those flags → falls through to default ERRNO=EPERM. **OK**
- `clone3` — `SCMP_ACT_ERRNO, errnoRet: 38` (ENOSYS). **OK** — matches CLAUDE.md's critical invariant.
- Required syscalls all present: `getpgid`, `rseq`, `pidfd_open`, `pidfd_send_signal`, `pidfd_getfd`, `close_range`, `mknod`, `mknodat`, full xattr family (`getxattr`/`setxattr`/`lgetxattr`/`fgetxattr`/`listxattr`/`llistxattr`/`flistxattr`/`removexattr`/`lremovexattr`/`fremovexattr`). **OK**
- Blocked via default EPERM: `mount`, `umount2`, `ptrace`, `kexec_load`, `kexec_file_load`, `reboot`, `init_module`, `finit_module`, `delete_module`, `unshare`, `setns`, `pivot_root`, `keyctl`, `add_key`, `request_key`, `bpf`, `userfaultfd`, `perf_event_open`, `personality`, `syslog`, `iopl`, `ioperm`. **OK**

### Runtime spot-checks (`/tmp/seccomp_probe*.py` via libc.syscall)

| Probe | Expected | Observed | Tag |
|---|---|---|---|
| `unshare(CLONE_NEWUSER)` | EPERM | EPERM | **OK** |
| `unshare(CLONE_NEWNS)` | EPERM | EPERM | **OK** |
| `clone3(minimal)` | ENOSYS (38), NOT EPERM | ENOSYS | **OK — critical** |
| `pidfd_open(self)` | SUCCESS (fd≥0) | fd=3 | **OK** |
| `close_range(high, max, 0)` | SUCCESS | ret=0 | **OK** |
| `rseq(NULL,0,0,0)` | EINVAL (allowed; FS-level error) | EINVAL | **OK** |
| `getpgid(0)` | SUCCESS | returned own pgid | **OK** |
| `mkfifo`/`mknodat` (FIFO in /tmp) | SUCCESS | mode `0o10600` created and unlinked | **OK** |
| `setns`, `mount`, `ptrace`, `bpf`, `keyctl`, `perf_event_open`, `init_module`, `reboot`, `kexec_load`, `pivot_root`, `finit_module` | EPERM | all EPERM | **OK** |
| xattr family (`setxattr/getxattr/listxattr/llistxattr/removexattr/lgetxattr`) | allowed at syscall level | all allowed, operate correctly on `/tmp/.xattr_probe` | **OK** |

Also behavioral: `bwrap --ro-bind / / true` fails with "No permissions to create new namespace" — confirming the `unshare(CLONE_NEWUSER)` block also neutralizes bubblewrap (important context: that's why Claude Code's bwrap-based Bash sandbox cannot nest inside this container, which is why the user had to `/sandbox` disable for this audit — the *container* IS the security boundary, so this is by design).

## 4. Filesystem & mounts

Rootfs:

| Invariant | Expected | Observed | Tag |
|---|---|---|---|
| `/` read-only | per compose, **not** read-only (CLAUDE.md line 91 explicitly removed) | `/` is `overlay rw` | **OK (matches compose)** |
| Dockerfile comment line 7 "rootfs read-only at runtime" | — | stale — contradicts CLAUDE.md rationale | **DRIFT (doc)** |
| `verify-sandbox.sh` "rootfs read-only PASS" | — | false positive — script writes to `/` as agent, which fails regardless of rw/ro | **SCRIPT BUG** |

Bind mounts (single-file semantics on Colima virtiofs):

| Path | Expected | Observed | Tag |
|---|---|---|---|
| `/home/agent/.claude.json` | single-file bind, **mode 644**, valid JSON | mode 644, owner agent:agent, 26292 bytes, parses as JSON | **OK** |
| `/home/agent/.claude/.credentials.json` | mode 600 (inside **dir** bind, UID-remap works) | mode 600, owner agent:agent, 470 bytes | **OK** |
| `/home/agent/.config/` | per-profile dir bind; holds `gh/`, `glab-cli/`, `git/config` | present: `git/` and `glab-cli/`. **No `gh/`** (gh not authenticated for this profile) | **OK** (gh/ absent is normal pre-auth) |
| `/home/agent/.gitconfig` | **not mounted** (EBUSY on rename over single-file bind) | not a mountpoint (confirmed against `/proc/self/mounts`); but a **regular file** exists at that path | **DRIFT (see below)** |
| `GIT_CONFIG_GLOBAL` env | `/home/agent/.config/git/config` | set correctly | **OK** |
| `/home/agent/.vscode-server/` | named Docker volume (VM ext4), not virtiofs | `/dev/vdb1` ext4 mount. Named volume for this profile: `macolima-therapod_vscode-server` | **OK** |

Stray `/home/agent/.gitconfig` (regular file, 242B, mode 644, timestamped 2026-04-21 20:04 — container-attach time):
```
[user] name = neilanthony
       email = 16306836+nranthony@users.noreply.github.com
[credential] helper = osxkeychain
             helper =
             helper = /usr/local/share/gcm-core/git-credential-manager
[credential "https://dev.azure.com"] useHttpPath = true
```
This is **VS Code Dev Containers' "share git config with container"** feature writing the host's `~/.gitconfig` into the container on attach. `GIT_CONFIG_GLOBAL` overrides `~/.gitconfig` for anything respecting that env var (i.e. `git` itself), so git won't read it, but:
- It leaks the user's identity + macOS-specific credential helper paths into the overlay FS. Low-sev info leak.
- If any tool reads `~/.gitconfig` directly without honoring `GIT_CONFIG_GLOBAL`, the macOS-only helpers would be invoked and fail. Functionally dormant but present.

Mount options (tmpfs under `/home/agent/`):

| Mount | Expected opts | Observed | Tag |
|---|---|---|---|
| `/home/agent/.npm-global` | tmpfs, `uid=1000,gid=1000,mode=0755` | `tmpfs size=524288k, nosuid,nodev,noexec, mode=755, uid=1000,gid=1000` | **OK** |
| `/home/agent/.local` | tmpfs, `uid=1000,gid=1000,mode=0755` | `tmpfs size=262144k, nosuid,nodev,noexec, mode=755, uid=1000,gid=1000` | **OK** |
| `/tmp` | tmpfs root-owned, `nosuid,nodev,noexec` | `size=1048576k, nosuid,nodev,noexec` | **OK** |
| `/run` | tmpfs, 64m, `nosuid,nodev,noexec` | `size=65536k, nosuid,nodev,noexec` | **OK** |

Virtiofs tags observed (Colima/Lima):
- `lima-8a0b20b5f0e9f521` → `/workspace`
- `lima-d2c9831586512a44` → `/home/agent/.claude`, `.claude.json`, `.cache`, `.config`

Base image digest pin: Dockerfile line 12 pins `ubuntu:24.04@sha256:c4a8d5503dfb2a3eb8ab5f807da5bc69a85730fb49b5cfca2330194ebcc41c7b`. Runtime OS is Ubuntu 24.04.4 LTS (noble) — consistent. Verifying the exact running image digest requires a host-side `docker image inspect macolima:latest` (I can't exec docker from inside). **UNKNOWN — needs host-side check.**

Dockerfile pre-create invariant (CLAUDE.md line 22): `.local` and `.npm-global` are tmpfs mount targets with explicit `uid=1000,gid=1000` options — they don't need pre-creation (tmpfs creates the mount point with the specified uid/gid). But Dockerfile line 74 only pre-creates `.claude`, `.cache`, `.npm`, `.vscode-server`, `.config` — consistent with the invariant as written. **OK.**

## 5. /proc and /sys exposure

| Path | Expected | Observed | Tag |
|---|---|---|---|
| `/proc/kcore` | masked | mount entry `tmpfs /proc/kcore` (Docker default mask); reading yields 0 bytes | **OK** |
| `/proc/sys` | `ro` | mounted `ro,nosuid,nodev,noexec`; write to `/proc/sys/kernel/randomize_va_space` fails `EROFS` | **OK** |
| `/proc/sysrq-trigger`, `/proc/bus`, `/proc/fs`, `/proc/irq` | `ro` | all `ro` | **OK** |
| `/proc/acpi`, `/proc/keys`, `/proc/latency_stats`, `/proc/scsi`, `/proc/timer_list`, `/proc/interrupts` | tmpfs-masked | all `tmpfs` overlays | **OK** |
| `/sys` | `ro,nosuid,nodev,noexec` | as expected | **OK** |
| `/sys/firmware` | masked | tmpfs overlay `ro` | **OK** |
| `/sys/kernel/security` | empty | empty (only `.`, `..`) | **OK** |
| `/sys/fs/cgroup` | `ro` | `cgroup2 ro,nosuid,nodev,noexec`; write to `cgroup.procs` fails `EROFS` | **OK** |
| `/etc/shadow` | not readable by agent | mode 640 root:shadow → agent reads fail | **OK** |

## 6. PID namespace & process visibility

- PID 1 = tini (UID 1000, caps empty, NNP=1, seccomp 2). **OK**
- Total visible PIDs from `/proc`: 33. All are agent-spawned (Claude, VS Code server, pty hosts, fileWatcher, extensionHost, zsh, gitstatusd) except PID 3171 (UID 0, `/bin/sh`, orphaned from VS Code Dev Containers init). **OK** / DRIFT already called out in §1.
- No host/VM processes leaking in. `/proc/self/ns/pid = [4026532537]` (container) vs kernel default would be `4026531836`. We are definitively in a private PID namespace.
- `/proc/self/ns/net`, `ipc`, `mnt`, `cgroup`, `uts` are all container-namespaced. `user` and `time` namespaces are the **host defaults** — Docker default (userns-remap off). Fine given `cap_drop: ALL` at the container level.

## 7. Devices

`/dev` is a 64MB tmpfs. Only standard safe devices: `null`, `zero`, `random`, `urandom`, `full`, `tty`, `ptmx`, `shm`, `mqueue`, `pts/`. **No host block devices** (`/dev/vd*`, `/dev/sd*`, `/dev/nvme*`, `/dev/kvm` absent). **OK**

## 8. Cgroups

Cgroup v2. `/proc/self/cgroup = 0::/`.

| Control | Expected (compose) | Observed | Tag |
|---|---|---|---|
| `pids.max` | 512 | 512 | **OK** |
| `memory.max` | 8 GiB | 8589934592 (= 8 GiB) | **OK** |
| `memory.swap.max` | 0 (`memswap_limit == mem_limit`) | 0 | **OK** |
| `cpu.max` | 4 CPUs | `400000 100000` (4 cores @ 100ms period) | **OK** |
| writability | `ro` | writes to `/sys/fs/cgroup/cgroup.procs` fail `EROFS` | **OK** |

## 9. Network & egress

Interfaces: `eth0` (172.20.0.3/16, MAC `42:ea:fa:13:1e:68`) and `lo`. **Route table has no default gateway** — only the `172.20.0.0/16` local subnet (`/proc/net/route`). Egress without the proxy is routing-level impossible.

`/etc/hosts` lists only `egress-proxy (172.20.0.2)` and self. No other sandbox-internal hosts resolvable.

Egress controls:

| Test | Expected | Observed | Tag |
|---|---|---|---|
| (a) Allowed via proxy: `https://github.com/` | 200 | `http_code=200` | **OK** |
| (b) Disallowed via proxy: `https://example.com/` | Squid 403 | `curl: (56) CONNECT tunnel failed, response 403` | **OK** |
| (c) Direct TCP `1.1.1.1:443` (no proxy) | ENETUNREACH | `OSError [Errno 101] Network is unreachable` | **OK** |
| (c') Direct TCP `github.com:443` (no proxy) | DNS fail or ENETUNREACH | `gaierror [Errno -3] Temporary failure in name resolution` | **OK** |
| (d) Allowlist wildcards | no broad wildcards (`*.microsoft.com` etc.) | all entries are specific hosts or narrow leading-dot subdomains (`.anthropic.com`, `.claude.com`, `.claude.ai`, `.github.com`, `.githubusercontent.com`, `.githubassets.com`, `.gitlab.com`, `.gitlab-static.net`, `.pypi.org`, `.files.pythonhosted.org`, `.astral.sh`, `.registry.npmjs.org`, `.npmjs.com`, `.nodejs.org`, `deb.nodesource.com`, `marketplace.visualstudio.com`, `.vscode-unpkg.net`, `update.code.visualstudio.com`, `statsig.anthropic.com`) | **OK** |
| (e) DB siblings | resolve to `postgres:5432`/`mongo:27017` if up | neither `postgres` nor `mongo` resolves via DNS; TCP probes return `gaierror` | **N/A — DBs not up for this profile** |

`postgres`/`mongo` not up → no `ports:` exposure check needed, no DB env in agent (see §12).

## 10. Colima / VM boundary

Signals observed:
- Kernel: `Linux 6.8.0-100-generic (aarch64)` — VM kernel, not container's.
- `/proc/cmdline`: `BOOT_IMAGE=/vmlinuz-6.8.0-100-generic root=PARTUUID=... ro console=tty1 console=ttyAMA0` (`ttyAMA0` = ARM virtual UART — Lima VM on Apple Silicon).
- Virtiofs tags `lima-*` visible in `/proc/self/mounts` — classic Lima virtiofs pattern.
- `/dev/vdb1` (virtio-blk) used for ext4 bind mounts (`/etc/resolv.conf`, `/etc/hosts`, `/etc/hostname`, `/home/agent/.vscode-server`).
- `/Volumes/DataDrive` is **not** visible from inside the container (host macOS path). Good isolation: the agent sees only the mapped `/workspace`, not the full DataDrive mount. **OK**

No attempt made to cross the VM boundary (per rules).

## 11. Kernel

`Linux 6.8.0-100-generic aarch64 #100-Ubuntu SMP PREEMPT_DYNAMIC Tue Jan 13 16:39:21 UTC 2026`. Out-of-scope per brief. Note: `/proc/self/status Speculation_Store_Bypass: vulnerable` — that's the VM kernel's speculative-exec mitigation state, not something the sandbox controls.

## 12. Secrets hygiene

### Env vars (redacted where credential-like)
- **No** `POSTGRES_*`, `MONGO_*`, `MONGODB_*`, `PG*` — DB env not injected (DBs not up). **OK for this run.** The documented WEAK (CLAUDE.md line 152, ambient DB admin creds when DBs are up) does not apply here.
- No raw `*TOKEN*`, `*SECRET*`, `*PASSWORD*`, `*API_KEY*` env vars. **OK**
- Proxy env set as expected: `HTTP(S)_PROXY=http://egress-proxy:3128`, `NO_PROXY=localhost,127.0.0.1,egress-proxy`.
- `GIT_CONFIG_GLOBAL=/home/agent/.config/git/config` — set. **OK**
- `MACOLIMA_PROFILE=therapod`. **OK**
- `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=delta` — enables Claude Code OTel metrics. If no `OTEL_EXPORTER_OTLP_ENDPOINT` is set (I didn't see one), this is inert. Worth a quick review that no endpoint exfiltrates to an unexpected host (but your proxy allowlist would block anything not in it anyway).

### Credential-like files under `/home/agent`
- `/home/agent/.claude/.credentials.json` — **mode 600, agent:agent**, 470 bytes. **OK** (expected location for Claude OAuth token).
- `/home/agent/.config/glab-cli/config.yml` — mode 600, contains host config for `gitlab.com` but no token (glab `hosts.yml` absent → not yet logged in).
- `/home/agent/.config/gh/` — absent → gh not logged in.
- `/home/agent/.ssh/` — only `known_hosts` (644, 92B). **No private keys.** **OK**
- `/home/agent/.gitconfig` — leaks user name+email (in public noreply form) and macOS credential helper paths. Low-sev info leak; see §4.

### SSH agent forwarding from host (new finding) — WEAK
VS Code Dev Containers is forwarding the host's SSH auth socket into the container:
- `SSH_AUTH_SOCK` is set.
- `REMOTE_CONTAINERS_SOCKETS=["/tmp/vscode-ssh-auth-93682724-ffd4-4fa6-9633-7efca13fbd52.sock"]`.
- Socket files exist: `/tmp/vscode-ssh-auth-*.sock` (mode 600, agent-owned).

Right now `ssh-add -L` returns "The agent has no identities" — no keys loaded on the host side, so the capability is present but dormant. **Risk:** if the user later runs `ssh-add` on the Mac, the agent immediately gains access to those private keys via the forwarded socket — usable through the proxy to `.github.com`, `.gitlab.com`, etc. for any SSH-based auth. This is not sandbox drift (VS Code's default behavior), but it **materially expands the threat model**: the isolation guarantees no longer hold against "anything the user's host SSH identities can reach".

Mitigation options if you want to close this:
- Add `"remote.containers.defaultExtensions": []` isn't the right knob. The correct one is a devcontainer `.json` setting or a VS Code user setting to disable SSH agent forwarding for this dev container. The devcontainer spec has `mounts` for this; alternately VS Code has `remote.SSH.forwardAgent` (for the SSH case) and `dev.containers.copyGitConfig` (for `.gitconfig`, item §4). Specifically: `"dev.containers.copyGitConfig": false` stops the stray `~/.gitconfig`, and forwarding of `SSH_AUTH_SOCK` is controlled by `REMOTE_CONTAINERS` logic — the clean fix is to override with a `.devcontainer/devcontainer.json` that sets `"overrideCommand": true` and excludes the SSH socket mount, OR unset `SSH_AUTH_SOCK` in the container's shell rc.

### Claude Code's own layer (defense-in-depth)

`/home/agent/.claude/settings.json` enables Claude Code's in-process sandbox with:
- `sandbox.enabled: true`, `failIfUnavailable: true`, `allowUnsandboxedCommands: false`
- Filesystem `denyRead`: `/root/.ssh/**`, `/home/agent/.ssh/**`, `**/.env*`, `**/credentials`, `**/*secret*`, `**/*.pem`, `**/*.key`
- Network allowlist (tighter than Squid's): only npm/pypi/anthropic/github/statsig
- Permission denies: `Bash(curl:*)`, `Bash(wget:*)`, `Read(**/.env*)`, `Read(**/*.pem)`, `Read(**/*.key)`

This is your third security layer (container → seccomp/caps/AppArmor; network → Squid allowlist; app → Claude Code sandbox). It was disabled by `/sandbox` for this audit — normally on. **OK — well configured.**

### Host-side check you asked me to describe rather than do
You mentioned checking host-side `profiles/` permissions yourself. On the Mac, from `~/.claude-colima/profiles/therapod/` (or wherever the profile state is staged), run:
```
ls -la /Volumes/DataDrive/.claude-colima/profiles/therapod/
stat -f '%Sp %OLp %Su:%Sg %z %N' /Volumes/DataDrive/.claude-colima/profiles/therapod/db.env 2>/dev/null
```
Expected: `db.env` should be `600` owner=you, and the enclosing profile dir should not be world-readable if it contains secrets. Your `.gitignore` should cover `profiles/`. I can't verify from inside.

---

## Recommended hardening

Concrete, minimal, ordered by impact.

### High impact

1. **VS Code SSH agent forwarding — explicit decision.**
   The host's SSH agent socket is reachable inside the container. If keys are ever loaded on the Mac, the agent can authenticate via SSH to anywhere the proxy allows. Pick one:
   - **Accept.** Document in CLAUDE.md that SSH agent is forwarded when attached via VS Code, and rely on proxy allowlist + no-keys-loaded discipline.
   - **Block.** Add to the container's zsh init (probably `config/.zshrc` that gets copied in via the Dockerfile COPY at line 79):
     ```sh
     # Drop inherited host SSH agent — we use token flow (gh/glab) only.
     unset SSH_AUTH_SOCK
     ```
     That only hides it from shells, not from other processes VS Code spawns. A more thorough fix is a `.devcontainer/devcontainer.json` that disables the forwarding. (This is a VS Code-side setting; not under docker-compose control.)

2. **Fix `verify-sandbox.sh`'s three bugs.** `scripts/verify-sandbox.sh`:
   - **Line 11** — `pass() { printf '...' "$*"; ((PASS++)); }`. `((PASS++))` exits with status 1 when `PASS` was 0 (post-increment of zero). This causes the `&& pass … || fail` chain on line 16 to fire both branches on the very first PASS. Fix: use `PASS=$((PASS+1))` (arithmetic expansion, not `(( ))` command) or append `; :` to force a true exit status:
     ```bash
     pass() { printf '\033[0;32m[PASS]\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
     fail() { printf '\033[0;31m[FAIL]\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
     warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
     ```
   - **Line 19** — rootfs-ro test writes to `/` as agent; that always fails because `/` is root-owned, regardless of mount ro/rw. False positive, AND misaligned with current intent (CLAUDE.md line 91: rootfs is deliberately NOT read-only). Either remove the check, or rewrite it to read the real mount option:
     ```bash
     if awk '$2=="/" {print $4}' /proc/self/mounts | grep -q '^ro'; then
       pass "rootfs read-only"
     else
       warn "rootfs rw (intentional — see CLAUDE.md §Rootfs is NOT read-only)"
     fi
     ```
   - **Line 29** — `grep Seccomp /proc/self/status` matches both `Seccomp:` and `Seccomp_filters:`. Fix:
     ```bash
     SM=$(awk '/^Seccomp:/{print $2; exit}' /proc/self/status)
     ```

3. **Decide on the "no SUID binaries" invariant (CLAUDE.md line 17).** Stock Ubuntu SUID bits on `su`, `passwd`, `mount`, etc. are present. Under NNP+cap_drop they're inert, but the invariant as written is not literally met. Either:
   - Update CLAUDE.md to say "SUID present but neutralized by NNP+CapBnd=0" (honest), or
   - Add a Dockerfile layer to actually strip the bits:
     ```dockerfile
     USER root
     RUN find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true
     USER agent
     ```
     Place after all apt-get steps, before the final `USER agent`. Note: this does break `mount`/`umount`/`su`/`passwd` for all users; fine here since they're pointless inside this sandbox.

### Medium impact

4. **Stop VS Code Dev Containers copying `~/.gitconfig` into the container.** Add to your VS Code user settings (not the container): `"dev.containers.copyGitConfig": false`. Removes the stray `/home/agent/.gitconfig` and the info leak of host credential-helper paths. (Cosmetic — functionally dormant given `GIT_CONFIG_GLOBAL` is set.)

5. **Update Dockerfile comment line 7.** Currently says "Root filesystem is made read-only at runtime (see docker-compose.yml)." — stale; read_only was removed. Replace with a reference to CLAUDE.md §"Rootfs is NOT read-only":
   ```dockerfile
   # - Rootfs is NOT read-only. See CLAUDE.md "Rootfs is NOT read-only" —
   #   it breaks VS Code Dev Containers' /etc/environment patching with no
   #   security gain (non-root + cap_drop: ALL already blocks system writes).
   ```

6. **CLAUDE.md line 17 polish.** After deciding #3, either remove "No suid binaries" or rewrite: "SUID bits on stock Ubuntu tools remain but are neutralized by `cap_drop: ALL` + `no-new-privileges: true`." (This is the kind of thing verify-sandbox.sh could also assert programmatically once #3 is decided.)

### Low impact / hygiene

7. **Explicit verify step for the root `/bin/sh` orphan.** PID 3171 (VS Code Dev Containers init artifact, UID 0, orphaned to PPid=0) is privilege-neutral but surfaces as "root process" in ps. If you'd like CLAUDE.md to stay truthful about "never root", add a note in the Gotchas section explaining it's expected and harmless (caps empty, NNP=1, seccomp enforced).

8. **Verify image digest matches Dockerfile pin on the host.** I couldn't exec docker. On the Mac:
   ```bash
   docker image inspect macolima:latest --format '{{index .RepoDigests 0}}'
   ```
   Expected to include `@sha256:c4a8d5503dfb2a3eb8ab5f807da5bc69a85730fb49b5cfca2330194ebcc41c7b`.

9. **Defense-in-depth sanity.** `.claude/settings.json` is tight — leaves a small window where `sandbox.enabled: true` assumes bwrap works. In a nested container like this it doesn't (user namespaces blocked by design), so any operation that *requires* sandboxing would fail (`failIfUnavailable: true` does enforce that, which is the right default). Worth documenting in CLAUDE.md: "Claude Code's in-process bwrap sandbox cannot activate inside this container; the container itself is the isolation boundary. Toggle via `/sandbox off` if you need to run Bash probes for verification."

### Future / known TODO (carried from CLAUDE.md)

10. **DB least-privilege split.** CLAUDE.md line 152 already tracks this; re-affirmed here as WEAK-by-design. For this profile (no DBs up) it's N/A.

---

## Chronological command log

All run inside `claude-agent-therapod` as UID 1000.

```bash
# 1. Identity
id; hostname; pwd
#   uid=1000(agent) gid=1000(agent) … claude-agent-therapod … /workspace

# 2. Verify script baseline
bash /workspace/temp_audit_package/scripts/verify-sandbox.sh
#   10 passed, 2 failed — both FAILs are script bugs (see Recommendations #2)

# 3. /proc/self/status essentials
grep -E '^(Uid|Gid|Groups|NoNewPrivs|Seccomp|CapInh|CapPrm|CapEff|CapBnd|CapAmb):' /proc/self/status
#   Uid: 1000 1000 1000 1000; Caps all zero; NoNewPrivs 1; Seccomp 2

# 4. MAC
cat /proc/self/attr/current
#   docker-default (enforce)

# 5. Seccomp syscall probes (ctypes-based)
python3 /tmp/seccomp_probe.py
python3 /tmp/seccomp_probe2.py
#   unshare(CLONE_NEWUSER) → EPERM
#   clone3 → ENOSYS (critical)
#   pidfd_open, close_range, getpgid, mkfifo, xattr family → SUCCESS
#   setns/mount/ptrace/bpf/keyctl/perf_event_open/init_module/reboot/
#     kexec_load/pivot_root/finit_module → all EPERM

# 6. Mounts
cat /proc/self/mounts
#   overlay / overlay rw,relatime,...  (NOT ro — matches CLAUDE.md line 91)
#   lima-* /workspace virtiofs
#   lima-* /home/agent/.claude{,.json,/…}
#   tmpfs /home/agent/.local      size=256M  uid=1000,gid=1000,mode=0755
#   tmpfs /home/agent/.npm-global size=512M  uid=1000,gid=1000,mode=0755
#   /dev/vdb1 /home/agent/.vscode-server ext4 (named volume, VM ext4)

# 7. Bind mount file perms
stat -c 'mode=%a owner=%U:%G' /home/agent/.claude.json
#   mode=644 owner=agent:agent
python3 -c 'import json; json.load(open("/home/agent/.claude.json"))'   # valid
stat -c 'mode=%a owner=%U:%G' /home/agent/.claude/.credentials.json
#   mode=600 owner=agent:agent

# 8. SUID sweep
find / -xdev -perm /6000 -type f 2>/dev/null
#   14 stock Ubuntu SUID/SGID binaries present (neutralized by NNP+cap_drop)

# 9. Proc masks
ls -la /proc/kcore                          # tmpfs-masked, 0 bytes
echo 0 > /proc/sys/kernel/randomize_va_space  # EROFS
ls /sys/kernel/security                      # empty
echo 1 > /sys/fs/cgroup/cgroup.procs          # EROFS

# 10. PID ns
cat /proc/1/comm                              # tini
ps auxf                                       # 33 procs, PID 3171 as root (orphan), rest agent

# 11. Cgroups
cat /sys/fs/cgroup/pids.max /sys/fs/cgroup/memory.max \
    /sys/fs/cgroup/memory.swap.max /sys/fs/cgroup/cpu.max
#   512 | 8589934592 | 0 | 400000 100000

# 12. Network
ls /sys/class/net                             # eth0 lo
cat /proc/net/route                           # only 172.20.0.0/16, no default GW

curl -sS -o /dev/null -w '%{http_code}\n' --max-time 8 https://github.com/
#   200 (proxied allowed)
curl -sS -o /dev/null -w '%{http_code}\n' --max-time 8 https://example.com/
#   curl: (56) CONNECT tunnel failed, response 403   (proxied disallowed)

python3 -c 'import socket; s=socket.socket(); s.settimeout(5); s.connect(("1.1.1.1",443))'
#   OSError [Errno 101] Network is unreachable  (direct bypass fails)
python3 -c 'import socket; s=socket.socket(); s.settimeout(5); s.connect(("github.com",443))'
#   gaierror — internal DNS has no external names  (direct bypass fails)

getent hosts postgres; getent hosts mongo    # neither resolves — DBs not up

# 13. Secrets
env | grep -iE '(token|secret|pass|key|cred)'  # no raw creds, SSH_AUTH_SOCK set
ls -la /home/agent/.ssh/                        # known_hosts only (no private keys)
ls /home/agent/.config/glab-cli/ /home/agent/.config/gh/
#   glab-cli present, no hosts.yml (not yet logged in)
#   gh absent (not yet logged in)
SSH_AUTH_SOCK=$SSH_AUTH_SOCK ssh-add -L
#   The agent has no identities — socket forwarded but empty

# 14. Kernel / VM
uname -a
#   Linux … 6.8.0-100-generic … aarch64 GNU/Linux
cat /proc/cmdline
#   … console=ttyAMA0 (Apple Silicon VM)

# 15. bwrap sanity (why Claude Code's bash sandbox can't nest here)
bwrap --ro-bind / / true
#   "No permissions to create new namespace" — expected (CLONE_NEWUSER blocked)
```

---

## Summary count

| Tag | Count |
|---|---|
| **OK** | ~40 checks across all areas |
| **DRIFT** | 3 (stray `.gitconfig`, SUID bits, root-UID orphan — all privilege-neutral) |
| **WEAK** | 2 (SSH agent forwarding, SUID bits under NNP — documentation-vs-reality) |
| **SCRIPT BUG** | 3 inside `verify-sandbox.sh` |
| **UNKNOWN** | 1 (live image digest — needs host docker inspect) |
| **N/A** | DB siblings (not up for this profile) |

No vulnerabilities that breach the stated threat model. The isolation posture matches what the configs describe. Biggest real-world attack-surface concern is the SSH-agent-forward capability from VS Code attach (currently dormant — no keys loaded).
