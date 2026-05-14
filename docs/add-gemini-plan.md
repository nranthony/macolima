# Adding Gemini CLI to the sandbox — plan

Scope: install Google's `gemini` CLI (`@google/gemini-cli`) alongside Claude Code in the existing agent container. One persistent dir per profile, no parallel profile tree.

Estimated effort: 30–60 min of edits + one image rebuild + per-profile `rebuild`.

## Profile layout (no new tree)

Gemini stores everything under `~/.gemini/`. Slot it into the existing `profiles/<p>/` dir:

```
profiles/<p>/
├── claude-home/        ← existing
├── claude.json         ← existing
├── config/             ← existing (gh/glab/git)
└── gemini-home/        ← NEW — single bind mount
```

Both agents share the same profile dir. No duplicate `workspace`, `config`, etc.

## Edits

### 1. `Dockerfile`

Install the CLI and pre-create the mount point with `agent` ownership (per the CLAUDE.md invariant: any `/home/agent/...` mount point must be pre-created + chowned, otherwise volumes/bind mounts initialize root-owned and the agent can't write).

```dockerfile
RUN npm install -g @google/gemini-cli@latest
RUN mkdir -p /home/agent/.gemini && chown agent:agent /home/agent/.gemini
```

Trusted-on-TLS, same posture as the existing `npm install -g … @latest` lines. Tightening to a checksum'd installer is open hygiene work, not a blocker.

### 2. `docker-compose.yml` — bind mount under `claude-agent`

```yaml
- /Volumes/DataDrive/.claude-colima/profiles/${PROFILE}/gemini-home:/home/agent/.gemini
```

Directory mount (not single-file), so UID remapping works correctly on virtiofs — no chmod 644 dance like `.claude.json` needs.

### 3. `proxy/allowed_domains.txt`

Minimum runtime endpoints. **Pin specific subdomains** — do not wildcard `.googleapis.com` (per the CLAUDE.md allowlist policy: that parent hosts hundreds of services, broad wildcards are exfil channels).

```
# Gemini CLI runtime
generativelanguage.googleapis.com
cloudcode-pa.googleapis.com         # Gemini Code Assist, if used
```

For OAuth login (see auth note below), additionally:

```
accounts.google.com
oauth2.googleapis.com
```

Apply with zero-downtime reconfigure: `docker exec egress-proxy-<p> squid -k reconfigure`.

### 4. `scripts/profile.sh` — `ensure_state()`

Add a `mkdir -p` for the host dir before `up`, same pattern as `claude-home/`:

```bash
mkdir -p "$PROFILE_DIR/gemini-home"
```

Gemini creates its own `settings.json` / token files on first run, so no seeding required. (If it ever complains about a missing file on first start, seed an empty `settings.json` here.)

### 5. Auth — pick one

**Option A: API key (recommended, simplest).** Add to `db.env` (or a new `gemini.env` referenced via `env_file`):

```
GEMINI_API_KEY=<key>
```

Note the CLAUDE.md gotcha: `env_file` is read at container **create** only — after adding the var, force-recreate the agent so it propagates:

```bash
COMPOSE_PROFILES=db-postgres PROFILE=<p> docker compose -p macolima-<p> \
  up -d --force-recreate claude-agent
```

(Re-attach VS Code after — container ID changes.)

**Option B: OAuth.** Hits the same structural problem documented in CLAUDE.md §gh/glab for `gh auth login`: callback is `http://localhost:<port>` inside the container, host browser can't reach it because `sandbox-internal` is `internal: true` with no published ports. Use `--no-browser` if the Gemini CLI supports it, otherwise stick with API key.

## Gotchas that do NOT apply

- No `.gemini.json` single-file bind mount → no chmod 644 dance (cf. `.claude.json`).
- No seccomp additions — it's Node, same runtime as Claude Code.
- No new caps needed.
- VS Code SSH_AUTH_SOCK / git-config-copy injections already neutralized — Gemini inherits.

## One real consideration: autonomy posture

Claude Code's `permissions.allow`/`deny` (in `config/claude-settings.json`) is Claude-specific. Gemini CLI has its own permission model (`--yolo` for blanket auto-accept, per-tool gating in `~/.gemini/settings.json`).

- **Planning-mode use** (human approves each step): trivial — no extra config.
- **Autonomous use** with the same "deny network tools, deny shell-outs" posture built for Claude: separate config in `gemini-home/settings.json`, modeled on `config/claude-settings.json`. Not hard, just not free.

Recommendation: ship **planning-mode + API key auth first** (~10-line change). Add autonomous-mode permissions later if the workflow demands it.

## Apply order

1. Edit Dockerfile, compose, allowlist, profile.sh.
2. Add `GEMINI_API_KEY=…` to `db.env` for the target profile.
3. Rebuild base + per-profile:
   ```bash
   scripts/profile.sh build
   scripts/profile.sh <p> rebuild
   ```
4. `docker exec egress-proxy-<p> squid -k reconfigure` to pick up new allowlist entries.
5. Re-attach VS Code, run `gemini` inside the container.

## Editing-checklist hits (from CLAUDE.md)

- [x] New `/home/agent/...` mount point — pre-created in Dockerfile + chowned.
- [x] New allowed domains — one-line justification comment above the block.
- [x] No new seccomp allowance.
- [x] No new build-time binary download (npm package, not a curl-piped binary).
- [x] No new `permissions.allow` entry (Claude Code matrix unchanged).
- [x] Compose change — validate with `PROFILE=_test docker compose config` before commit.
- [x] Dockerfile change — needs `scripts/profile.sh build` then per-profile `rebuild`.
