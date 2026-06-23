# IN TRANSIT — Resource-limit recommendations for macolima

**Status:** in-transit (staging note — apply deliberately, do not blind-copy)
**Date:** 2026-06-23
**Origin:** ported from a `windows-ai-sandbox` change after a Jupyter kernel
death (`Resource temporarily unavailable`, libzmq `pthread_create` → EAGAIN)
caused by cgroup **PID/thread exhaustion** under multiple VS Code windows.

---

## Why this is here

The Windows repo hit `pids.max` (512) exhaustion: gitstatusd was sizing its
thread pool to the *host* CPU count (16) while the container only had `cpus: 4`
of quota — ~32 idle threads **per shell** — and several VS Code windows piled
Node extension hosts (~230 threads) on top. The fix had three levers. **One is
platform-independent and should be ported here. The RAM/pids numbers are NOT —
macolima is the more constrained substrate and copying them would be actively
harmful.**

## The constraint that makes macolima different

| Layer | macolima (now) | windows-ai-sandbox (new) |
|---|---|---|
| VM | Colima: `--cpu 6 --memory 10 --disk 128` | WSL2: `memory=48GB` (was 32 default) |
| Agent container | `pids_limit: 512`, `mem_limit: 8g`, `cpus: 4` | `pids_limit: 4096`, `mem_limit: 20g`, `cpus: 4` |
| Sidecars in same VM | Squid 2g + postgres 2g + mongo 512m | (host has 48GB to spare) |

**The headline:** macolima's Colima VM is **10GB total**, and the agent alone is
already capped at 8g. Add Squid (2g) and the VM is fully committed before a DB
profile starts. The VM — not `mem_limit` — is the real ceiling, and here it is
*tiny*. Any RAM increase **must start by growing the Colima VM**, which is itself
bounded by the Mac's physical RAM.

---

## Recommendations (scaled to the constrained VM)

### 1. Port the gitstatus thread cap — SAFE, do this first
Pure win, costs no VM headroom. macolima's `cpus: 4` vs Colima `--cpu 6` means
gitstatusd still oversizes (~12 threads/shell vs the 4 it needs). Add to
`config/.zshrc` before the p10k source:
```sh
export GITSTATUS_NUM_THREADS=4   # was auto-sizing to ~2×6 VM CPUs
```
This is a baked-into-image config change — **platform-independent**, identical to
the Windows port, no divergence axis touches it. Rebuild image + recreate profile.

### 2. pids_limit — raise MODESTLY, not to 4096
512 is low, but macolima likely runs fewer concurrent VS Code windows than the
3–4-per-sandbox Windows scenario that justified 4096. On a 10GB VM, start at
**`pids_limit: 2048`** and only go higher if the Jupyter repro (below) still
fails. pids is a fork-bomb ceiling, not a containment boundary — but each live
thread carries a stack, and on a 10GB VM that adds up faster than on 48GB.

### 3. mem_limit — DO NOT copy 20g. Grow the VM first, then size under it.
20g is impossible on a 10GB VM and dangerous even partway. Two-step, same shape
as the Windows fix but scaled to the Mac's physical RAM:
1. **Grow the Colima VM** in `scripts/colima-up.sh` (`--memory N`), leaving macOS
   its own headroom (macOS needs ~4–8GB). Examples:
   - 16GB Mac → `--memory 12`, keep `mem_limit: 8g`
   - 24GB Mac → `--memory 16`, `mem_limit: 12g`
   - 32GB Mac → `--memory 20`, `mem_limit: 14g`
2. **Size `mem_limit` so** `mem_limit + 2g (Squid) + DB profiles + ~1.5g VM
   overhead ≤ --memory`. Never let the agent ceiling alone approach the VM size,
   or one torch/Jupyter leak OOM-kills the whole VM (Squid + every other sandbox)
   before its own cgroup limit bites — the exact failure mode the cap exists to
   prevent.
   Changing `--memory` requires `colima stop && colima start --memory N` (or
   `colima-up.sh`), which restarts every sandbox.

### 4. Disk — `--disk 128` is grow-only and was set at VM creation
Not container-limited; bounded by the Colima qcow2. For reference, the Windows
rootless-docker data dir had grown to **189GB** from accumulated build cache —
that would blow past macolima's 128GB disk. So:
- Prune regularly on the Mac host: `docker buildx prune`, `docker system df`.
- To enlarge: `colima stop && colima start --disk <bigger>` (**grow only** — you
  cannot shrink without recreating the VM).

---

## Divergence flags (per `docs/sibling-repo-relationship.md`)

- macolima is **rootful Docker + non-root `agent` UID 1000**; Windows is rootless
  + container-root. The `.zshrc`/`GITSTATUS_NUM_THREADS` change is in image config
  and is **portable**. The resource *numbers* are not — they were sized for a
  48GB VM with no DB-in-VM pressure.
- macolima has no `.wslconfig` equivalent; the VM-sizing lever lives in
  `scripts/colima-up.sh` (`--cpu/--memory/--disk`), applied at `colima start`.

## How to verify (same repro as Windows)
Inside an attached agent, with a venv that has ipykernel:
```bash
# 1. show the ceiling and current pressure
cat /sys/fs/cgroup/pids.max /sys/fs/cgroup/pids.current 2>/dev/null
# 2. a kernel launch that dies with "Resource temporarily unavailable
#    (src/thread.cpp:241)" == pids exhaustion, NOT a venv/code problem
```
Close stale integrated terminals (each reclaims a gitstatusd) as the quick
mitigation; the config changes above are the durable fix.

---

## Checklist when next on macolima
- [ ] Add `GITSTATUS_NUM_THREADS=4` to `config/.zshrc`; rebuild image.
- [ ] `pids_limit: 512 → 2048` in `docker-compose.yml`.
- [ ] Decide Mac physical RAM → set Colima `--memory` in `colima-up.sh`, then
      size `mem_limit` under it (table above). Recreate VM.
- [ ] Confirm `mem_limit + Squid + DB ≤ --memory`.
- [ ] Prune docker build cache; check `--disk` headroom.
- [ ] Update macolima `CLAUDE.md` Security Posture "Resources" row to match.
- [ ] Re-run the Jupyter repro to confirm the EAGAIN is gone.
