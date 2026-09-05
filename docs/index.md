# macolima Documentation Index

This directory contains the design plans, operational recipes, and architectural hardening notes for the macolima sandbox.

## 🗺️ Visual Overview
*   **[key-files.html](./key-files.html)**: Color-coded map of the input files (repo) and output state (data drive) that the orchestration scripts actually read/write, weighted by how `bootstrap.sh` / `setup.sh` / `profile.sh` consume them. Open in a browser.

## 📜 Decisions
*   **[adr/](./adr/README.md)**: Architecture Decision Records — why a door is closed. Read before proposing to reopen one. Numbering is aligned with the sibling repo; the index says why.

## 🛠️ Operational Guides
*   **[extending-a-profile.md](./extending-a-profile.md)**: Where a capability has to LIVE — the three durability classes, the two gates, a decision table, and a portable brief for an agent outside this repo.
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
*   **[deny-destructive-hook-plan.md](./deny-destructive-hook-plan.md)**: The `PreToolUse` hook's ruleset and maintenance record — the file the hook script, the settings template and the audit probe all cite. Shipped; kept here because extending the ruleset starts from it.
*   **[permissions-model.md](./permissions-model.md)**: Two-phase planning/autonomous workflow, deny list as defense-in-depth, `WebFetch` exfil channel, `with-egress.sh`.
*   **[web-read-broker.md](./web-read-broker.md)**: The `webfetch` broker — why the agent reads the web through a hosted reader API instead of a wider allowlist, the backends, and key handling.
*   **[sibling-repo-relationship.md](./sibling-repo-relationship.md)**: `windows-ai-sandbox` — what is shared, what diverges, and which rows cause a flaw if copied across. Includes the bash 3.2 filter every ported script must pass.
*   **[sandbox-design-notes.md](./sandbox-design-notes.md)**: Background on rootfs writability, disabled bwrap, commit identity workflow, Colima VM lifecycle, gh/glab integrity pinning, bash 3.2 compat.

## 🚀 Plans
*   **[control-dashboard-plan.md](./control-dashboard-plan.md)**: Design for the host-side Streamlit dashboard that manages profile lifecycle and proxy settings (`just dashboard`).
*   **[../work/](../work/README.md)**: In-flight implementation items, one folder each (`spec.md` → `plan.md` → `notes.md`). Merged items move to `work/archive/`; the README indexes both.

## 🧬 Profile Seeds & Templates
*   **[numerai-profile-seed.md](./numerai-profile-seed.md)**: Hardening and setup guidance for a Numerai tournament research profile.
*   **[profile-seed-database.md](./profile-seed-database.md)**: Worked example of seeding a profile's databases — schema setup, a backfill pipeline run, and the db-reset protocol.

## ⏳ Future & Deferred Plans
*   **[_future/db-least-privilege-plan.md](./_future/db-least-privilege-plan.md)**: Staged, decisions locked, not executed — split the agent off the DB superuser creds it holds via `db.env`. Execute before a profile holds real data.
*   **[_future/overlay-project-plan.md](./_future/overlay-project-plan.md)**: Architectural design for per-profile image customization (overlays) to handle heavy dependencies.

## 🗄️ Archive
*   **[_archive/](./_archive/)**: Shipped plans and closed handoffs, kept for provenance — the Gemini CLI plan (superseded by `agy`), the two `MACOLIMA_in-transit_*` port-forward handoffs (verified 2026-07-02), and an April 2026 in-container audit report. Nothing here is current intent.

---
*For core system invariants and security boundaries, always refer to [CLAUDE.md](../CLAUDE.md) in the project root.*
