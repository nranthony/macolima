# macolima Documentation Index

This directory contains the design plans, operational recipes, and architectural hardening notes for the macolima sandbox.

## 🗺️ Visual Overview
*   **[key-files.html](./key-files.html)**: Color-coded map of the input files (repo) and output state (data drive) that the orchestration scripts actually read/write, weighted by how `bootstrap.sh` / `setup.sh` / `profile.sh` consume them. Open in a browser.

## 🛠️ Operational Guides
*   **[debug-recipes.md](./debug-recipes.md)**: Essential "cheat sheet" for operating, verifying, and troubleshooting sandbox profiles.
*   **[porting-notes.md](./porting-notes.md)**: Guidance for reproducing the macolima hardening posture on WSL2 (Windows) and rootless Docker (Linux).
*   **[local-wheels.md](./local-wheels.md)**: Convention for managing and installing local Python build artifacts (`.whl`) into profiles.

## 🔬 Internals & Gotchas (root-cause deep dives)
*   **[database-internals.md](./database-internals.md)**: Postgres/Mongo sibling internals — first-init lock-in, DSN encoding, named-volume rationale, pg18 mount path, cap dropping.
*   **[squid-internals.md](./squid-internals.md)**: Egress proxy caps, split-phase tmpfs ownership, Safe_ports/CONNECT rules, wildcard policy, hot reload.
*   **[seccomp-notes.md](./seccomp-notes.md)**: Syscalls that must stay allowed, `clone3` → ENOSYS rationale.
*   **[vscode-leakage.md](./vscode-leakage.md)**: Dev Containers leakage hardening — in-container `openssh-client` purge, `remoteEnv`, `ensure_state` scrub, tripwire posture.
*   **[virtiofs-gotchas.md](./virtiofs-gotchas.md)**: Colima virtiofs failure modes — named volumes for `.cache`/`.vscode-server`, `.claude.json` perms, `.gitconfig` EBUSY, tmpfs uid.
*   **[compose-network-ipam.md](./compose-network-ipam.md)**: Why IPAM changes need `down`+`rebuild`, and the DNS-exfil side channel the static subnet closes.
*   **[permissions-model.md](./permissions-model.md)**: Two-phase planning/autonomous workflow, deny list as defense-in-depth, `WebFetch` exfil channel, `with-egress.sh`.
*   **[sandbox-design-notes.md](./sandbox-design-notes.md)**: Background on rootfs writability, disabled bwrap, commit identity workflow, Colima VM lifecycle, gh/glab integrity pinning, bash 3.2 compat.

## 🚀 Active Implementation Plans
*   **[deny-destructive-hook-plan.md](./deny-destructive-hook-plan.md)**: `PreToolUse` hook closing command-bypass holes the prefix matcher can't see (`find -delete`, `dd of=`, `git clean -fdx`, hook/settings tamper). v1 host-side shipped 2026-05-14; image rebuild + per-profile `reset-settings` pending.
*   **[add-gemini-plan.md](./add-gemini-plan.md)**: Strategy for integrating the Google Gemini CLI alongside Claude Code in the sandbox.
*   **[control-dashboard-plan.md](./control-dashboard-plan.md)**: Design for a host-side Streamlit dashboard to manage profile lifecycle and proxy settings.

## 🧬 Profile Seeds & Templates
*   **[numerai-profile-seed.md](./numerai-profile-seed.md)**: Hardening and setup guidance for a Numerai tournament research profile.
*   **[therapod-profile-seed.md](./therapod-profile-seed.md)**: Database setup (wearables_ref + pipeline), H10 backfill pipeline run, and db-reset protocol.

## ⏳ Future & Deferred Plans
*   **[_future/overlay-project-plan.md](./_future/overlay-project-plan.md)**: Architectural design for per-profile image customization (overlays) to handle heavy dependencies.

---
*For core system invariants and security boundaries, always refer to [CLAUDE.md](../CLAUDE.md) in the project root.*
