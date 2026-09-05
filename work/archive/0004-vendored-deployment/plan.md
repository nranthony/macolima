# work/0004 — actually deploying the vendored artifacts

Branch: `dev/0002-vendor-tools` (continues the vendoring track; V4 + V5 of
`work/0002-vendor-tools/plan.md`, which stays the strategic record).

## 0. Anchors, measured 2026-09-02

| | |
|---|---|
| `windows-ai-sandbox` (W) | `52b7c91`, clean |
| depot channel | `/Volumes/DataDrive/repo/nranthony/depot`, HEAD `9aebf07` |
| macolima (M) | `dev/0002-vendor-tools@3a3cff2` |
| channel contents | myclickup 0.7.0 (`eb2b25a4`), myconv 0.7.0 (`d2b3d043`) |

## 1. The problem this closes

`just vendor-tools` mirrors the channel into `sandbox_templates/` and stops
there. Both legs that carry an artifact the rest of the way are missing, so
0.7.0 is in the repo and nowhere else:

```
claude-agent-nranthony      myclickup  <not installed>
claude-agent-jeremy_dahl    myclickup  <not installed>
nranthony    skills/myclickup/SKILL.md   STALE, 29 lines behind template
jeremy_dahl  skills/myclickup/SKILL.md   STALE, 29 lines behind template
```

Both profiles therefore carry a skill instructing the agent to run a command
that does not exist. The wheel leg (V4) fixes the command; the skill leg (V5)
fixes the drift that would put them out of step again on the next bump.

## 2. Five places a verbatim port of W would be wrong

W is the design authority here, but four of its assumptions are W's, not this
repo's. Each was measured, not reasoned about.

**F1. M has no `UV_TOOL_DIR`/`UV_TOOL_BIN_DIR` pins, and needs them more than W
does.** Probed inside `macolima:latest`:

```
uv tool dir        -> /home/agent/.local/share/uv/tools
uv tool dir --bin  -> /home/agent/.local/bin
```

`/home/agent/.local` is a `noexec` tmpfs (`docker-compose.yml:32`) recreated
empty at container start, and `PATH` puts it FIRST (`Dockerfile:364`). An
unpinned install builds green, prints a correct `myclickup 0.7.0` in the build
log, and delivers nothing at runtime. W pins these at its line 181; M must too.

**F2. W's runtime user is root; M's is `agent` (UID 1000).** W's in-layer
`myclickup --version` therefore runs as W's runtime user and is a real check.
The same line in M would prove only that *root* can run it — and root is not
who runs it. M's layer verifies as `agent` as well, which is the check that
actually matches the deployed condition.

**F3. uv can silently download an interpreter.** `python-downloads` defaults to
automatic, so an unpinned `uv tool install` may fetch a managed CPython into a
root-owned directory the agent cannot read. Pinned to `--python
/usr/bin/python3` (system 3.12.3, satisfies the wheel's `>=3.11`) with
`UV_PYTHON_DOWNLOADS=never`, so a surprise is a hard build failure rather than a
runtime one.

**F4. The layer goes at M's tail, not W's position.** W puts the wheel straight
after its `uv python install`. In M that spot is followed by oh-my-zsh,
powerlevel10k and three plugin clones plus a gitstatusd release download — five
network fetches a wheel bump would re-run. M already has a `USER root`
interlude at the tail (`Dockerfile:357`, for `usermod`); the wheel goes there.
Still root (so `/opt` and `/usr/local/bin` are writable), still after Gate 3,
and a re-vendor now invalidates one trivial layer instead of five downloads.
Same *reason* W gives for its placement, applied to M's actual layout.

**F5. `converge_skills`' staged replace is cross-device on macOS.** W stages
through `mktemp -d` so a mid-copy failure cannot leave a half-written skill.
Measured here:

```
$TMPDIR                     device 16777232
.../profiles/<p>/...        device 16777245
```

Different filesystems, so the `mv` degrades to a copy and the property W's
comment claims is silently gone — after `rm -rf "$dst/$name"` has already run.
M stages in a `.skills-stage.*` sibling under `claude-home/` (same device,
outside the directory Claude Code scans). Strictly better on both platforms;
**send back to W.**

Everything else ports verbatim, including the bash-3.2 space-padded membership
tests W wrote specifically so this function would port unchanged.

## 3. What gets built

### V4 — the wheel layer

`ENV UV_TOOL_DIR=/opt/uv/tools UV_TOOL_BIN_DIR=/usr/local/bin` beside the uv
install, then at the tail:

```
COPY sandbox_templates/wheels/ /tmp/wheels/
RUN  <count wheels: 0 skip, 1 install, 2+ refuse>
```

Four properties, all from W:

1. **Directory copy, not a glob.** A `COPY` matching nothing is a hard build
   failure; the tracked `.gitkeep` keeps the directory in the context so a clone
   without the private payload still builds.
2. **Conditional install.** No wheel ⇒ no myclickup, build still green.
3. **Two wheels is a refusal.** The vendor script rotates the file on every
   bump, so two means a failed rotation; choosing silently would ship the wrong
   version behind a correct-looking `myclickup --version`.
4. **Payload gitignored.** This repo is public, myclickup is not.

Verified end-to-end in `macolima:latest` under `--network none` before writing
any of it: zero-dependency install, `myclickup 0.7.0` as root AND as agent,
executable at `/usr/local/bin/myclickup`, venv on the system interpreter.

`dockerfile-order.test.sh` gains a fifth anchor. W has only four; this is a
deliberate M addition, because F4 gives M a placement rule W does not have.

`.dockerignore`'s header still says the Dockerfile "COPYs exactly three paths,
all under `config/`" — stale since V2 renamed the tree, and now wrong by count.

### V5 — skills convergence (ADR-0005)

`converge_skills` replaces the create-only seeding at `profile.sh:399-409`.
Template tree is the source of truth, profile copy a derived cache, reconciled
on every `up`. Divergence and pruning both WARN. **No backups** — a
`<name>.bak.<stamp>` inside `~/.claude/skills/` is a second live copy, and for a
plugin-shaped skill the backup wins the name race (`myconv` is exactly that
shape: `.claude-plugin/plugin.json` + six nested skills). A `.sandbox-seeded`
manifest scopes pruning to names this repo seeded, so an agent's own
`claude plugin init` output survives.

`reset-skills` keeps its name and becomes "converge without touching the
container". W folded it into a broader `converge` alongside agent-policy
convergence; M has no `converge_agent_policies` yet (work/0002 Phase D), so
renaming now would leave a command named for a thing it does not do.

First run on the two live profiles will WARN and overwrite `myclickup` and
`myconv` — that is the drift in §1, reported rather than silent.

### Tests

`profile-skills.test.sh` ported from W (157 lines): runs the real dispatch path
against a throwaway repo root and HOME. Joins `test-offline`.

## 4. Definition of done

- `just build` bakes the wheel; `myclickup --version` works **as agent** in a
  recreated container
- an empty `wheels/` still builds green; two wheels fails the build
- `just tools-check` green, `VENDORED.lock` committed
- a template skill edit reaches a running profile on the next `up`, with a WARN
- a user-authored profile skill survives convergence untouched
- `test-offline` carries `profile-skills.test.sh`
- `just verify <p>` clean (SUID set unchanged — `uv tool install` adds none)

## 5. V7 — reach and credentials — **DONE 2026-09-03**

Landed after the section below was written, in two owner-directed steps.

**Egress.** One host uncommented: `api.clickup.com`, ALWAYS ON. Read out of
myclickup 0.7.0's source rather than copied from W's block — `client.py` has
exactly two request sites and the API one builds every URL from `API_BASE`
(`/api/v2`) or `API_V3` (same host). `app.clickup.com` is not in the source at
all. The remote-MCP hosts stay shut (`mcpServers` is `{}` in every profile here)
and so do the attachment hosts, including therapod's unverified tenant ID — a
wrong ID there does not fail closed.

**Credentials.** `secrets.env`, ported from W: a second optional `env_file` on
the agent, seeded as `secrets.env.example`, chmod 600 on every `up`, preserved by
`wipe`. This was already specified in `docs/numerai-profile-seed.md` as a
"required compose change" and had simply never been made.

The template is W's with its mechanics intact and its key list cut to what this
repo has a consumer for. W's carries `TAVILY_API_KEY`, `TINYFISH_API_KEY`,
`JINA_API_KEY`, `FIRECRAWL_API_KEY` (the webfetch broker, not ported — work/0002
§4.4), `HF_TOKEN` and `FAL_KEY` (the GPU/ML stack, out of scope — work/0001
§0.2). Copying those over would document keys with no reader: a key whose
consumer does not exist reads as configured and fails as a silence. The template
says so explicitly, so nobody restores them for parity.

**F6, found while doing it.** W sets `SANDBOX_PROFILE=${PROFILE}` on the agent;
this repo set only `MACOLIMA_PROFILE`. That is not a naming preference — it is a
literal string comparison in a tool this repo does not own:
`myclickup.config.in_sandbox()` is `"SANDBOX_PROFILE" in env`, and when it is
false the tool merges a repo-root `.env` beneath the real environment. Since
`/workspace` is agent-writable, a file the agent can create was a credential
source, which is exactly what myclickup's ADR-0003 disables inside a sandbox. The
vendoring pipeline delivered the tool correctly and the container then told it it
was not in a sandbox. Now set on both the compose agent and `run-ephemeral.sh`;
`MACOLIMA_PROFILE` stays, since the audit aggregator, the `audit-sandbox` skill
and `run-ephemeral.sh` all read it.

Still open: `CLICKUP_TOKEN` is plumbed but not set — that needs a real token per
profile and a `recreate`, both owner actions.

## 6. Not in scope

- **V6, the permissions leg.** The manifest proposes 19 allow / 11 ask / 2 deny
  for myclickup. Reporting it is a separate step and applying it is a human
  decision — an artifact must not widen the sandbox by being vendored.
- The content check against `source_commit` (work/0002 V3's stated gap).

## 7. Back to W

1. **F5**, the cross-device staging fix — a portability defect in W's own
   function, latent on WSL, live on macOS.
2. W's depot pointer is still unset (`work/0002` §6.1), so its `just
   tools-check` remains green over a disconnected channel.
