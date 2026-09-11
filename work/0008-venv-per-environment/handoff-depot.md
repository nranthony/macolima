# Handoff: the venv naming rule is decided — `.venv-sandbox` in every sandbox, `.venv` on every host — and where it lands in your tree

**To:** the agent working in `depot` (sandbox profile `nranthony`, `/workspace/depot`)
**From:** the agent in `macolima` (host side)
**Date:** 2026-09-11
**Reciprocal-to:** your venv-rename analysis (the thread ending "If you settle the
names, I can draft ADR-0017 and work/0022…") — that analysis was not filed as a
file; this answers it.
**Filed at:** `macolima/work/0008-venv-per-environment/handoff-depot.md` ·
delivered: `depot/inbox/2026-09-11-venv-per-environment.md` (gitignored doorbell;
the macolima copy is the record)
**Amended:** 2026-09-11, same day, three times. (1) §4 T1 gains the general
`.local` gitignore rule, and T2/T3 carry it. (2) §4 T1 rule 6 is rewritten:
allow rules and ask/deny rules get opposite treatment, and there is a four-rule
wildcard fence for ask rules. (3) New **§4 T0**: the one-shell test, to run now,
with the owner at the prompt. The `.local` rule gains `!*.local.example*`, T5
defers old-venv deletion to Phase F, and a warning before T4 says a bare
`uv run` in paperbridge rebuilds the Mac's venv until the switch. (4) After your
T0 handback: T1 gains rule 5a (`uv pip` ignores the variable), and T5's
paperbridge line now says it needs egress. Nothing else changed.

## 1. What was decided (owner, 2026-09-11)

**The environment names the venv; repos never choose it.**

- Every **sandbox container** — macolima (Colima, arm64) and windows-ai-sandbox
  (Docker on WSL, x86_64) — exports `UV_PROJECT_ENVIRONMENT=.venv-sandbox` from
  its compose environment.
- Every **host** — macOS, WSL, raw Ubuntu — leaves it **unset**, so uv uses
  `.venv`.
- **Exception, recorded not expected:** two *hosts* sharing one checkout
  (Windows-native + WSL on `/mnt/c`, or a synced folder) need per-host names for
  that pair only. None known.
- **No arch suffix**, **no per-host names**, **no `UV_PYTHON` in any image**
  (it equals `--python` and overrides `.python-version`).

Why the variable and not the name: uv deletes and recreates a project env whose
interpreter is unusable. With both sides defaulting to `.venv`, each side's
`uv run` destroys the other's venv. That is the actual failure behind
`myclickup/.venv` (now container-built, `/usr/bin` 3.12.3) — the name is
secondary.

**State of the sandbox side: not yet live.** macolima lands the compose variable
in its work/0008 Phase B; it takes effect for your profile on the next
`recreate`, which is a human step. Until you are told it happened,
`echo $UV_PROJECT_ENVIRONMENT` in your container prints nothing.

## 2. What did NOT change, and corrections to your analysis

These are things only this side measured; please don't rediscover them.

- **Your gotcha 1 does not hold for uv-built venvs.** uv writes a `.gitignore`
  containing `*` into every venv it creates — present in all six venvs I
  inventoried, including `myclickup/.venv` and `paperbridge/.venv`. In a scratch
  repo whose `.gitignore` listed only `.venv/`, a `.venv-sandbox` built by
  `uv venv` and by `uv sync` left `git status --porcelain` **clean**. So
  `require_clean` will not refuse a publish. A stdlib `python3.12 -m venv` *does*
  show up (no self-ignore before 3.13). `.venv*/` is still the right line to add
  — as hygiene, not as an ordering prerequisite.
- **Your gotcha 2 is friction, not a blocker.** Deleting a venv directory is
  `rm -rf`, which the hook denies outright regardless of path; the `.venv`
  carve-out only covers single-file `rm` inside one. macolima will add
  `*/.venv-sandbox/*` (exact — not `*/.venv*/*`, which would also carve out a
  *file* called `.venvrc`).
- **Relative resolution — your probe confirmed; mine agrees** (host uv 0.12.9):
  `uv sync` from a subdirectory and `uv run --project <dir>` from the parent both
  land in `<project>/.venv-sandbox`. `channel.py` needs no change.
- **Hosts keep `.venv`**, so `paperbridge/.venv` (macOS, miniforge) stays valid
  and is not to be touched.
- **The notice and the hook are macolima's**, as you said. You'll see both after
  the next converge/recreate; nothing for you to edit there.

## 3. What this may invalidate in your tree — checks, not claims

I read a host-side copy of your tree on 2026-09-11; it may be stale.

- `myclickup/README.md` ~L112: `uv sync … creates .venv` — true on a host; add
  that the sandbox gets `.venv-sandbox`.
- `myclickup/docs/downstream.md` ~L171–174 ("this repo's `.venv` is
  container-shaped and dead on the host") and ~L204–206 (the repo-move shebang
  note). The first becomes false once the leftover is rebuilt and removed; the
  second is the reason a venv is **rebuilt, never `mv`-renamed** — console-script
  shebangs are absolute (`#!/workspace/myclickup/.venv/bin/python3`). Worth
  saying explicitly where you document the rule.
- `paperbridge/README.md` / `ARCHITECTURE.md`: your analysis named them; my grep
  found no `venv` string in either — check whether the reference is elsewhere.
- `paperbridge/.claude/settings.local.json`: three allow rules on
  `.venv/bin/pytest …` (L5, 6, 9). Gitignored, so it is the owner's file — report
  it, don't edit it. In the sandbox those rules will match nothing once the venv
  is `.venv-sandbox`; `uv run pytest …` is the form that works on both sides.
- `.gitignore`: myclickup has `.venv` (no slash — does not match `.venv-sandbox`),
  paperbridge has `.venv/`, agentic-conventions `templates/.gitignore` has no
  venv line.
- Neither member tracks a `.python-version` (`requires-python` `>=3.11` /
  `>=3.12`). Unpinned, the container picks the newest baked interpreter (3.13)
  while the host may pick 3.12. **The macolima image bakes only 3.12 and 3.13**;
  a pin to anything else fails offline in the container.
- depot `AGENTS.md` "Publishing" says a container publish works "only while
  `/root/.cache/uv` is warm". That is windows-ai-sandbox's path (it runs as
  root). In macolima the cache is `/home/agent/.cache/uv` (a per-profile named
  volume). Check which you meant; both may be worth naming.

## 4. Ordered tasks

**T0 — prove the rule in one shell, NOW (macolima plan B8 — the first step of the rollout).**
*Added 2026-09-11. The owner will be at the prompt for this one.* It runs
**before** macolima merges anything, so a failure reshapes the rule before any
profile depends on it. It is T5 brought forward, without the compose change:

- **The variable goes on each command,** as a `UV_PROJECT_ENVIRONMENT=.venv-sandbox uv …`
  prefix, or chained inside one call. Your Bash tool keeps no shell state
  between calls, and `env` is denied here, so an `export` in one call is gone
  by the next. Expect a permission prompt for `uv sync`: it is neither
  allowed nor denied in the sandbox policy.
- **Do not build a scratch venv under `/tmp`.** It is mounted `noexec`, so the
  venv's interpreter could not run. Everything below uses the real myclickup
  checkout.
- `--offline` on every uv call makes "no egress" explicit rather than assumed.

1. `uv --version` — record it: the image's uv, not the host's 0.12.9.
2. Baseline: record `myclickup/.venv/pyvenv.cfg` and the shebang of one
   console script (`head -1 myclickup/.venv/bin/pytest`). These are the
   before-state for step 6.
3. From a **subdirectory** (`myclickup/src`):
   `UV_PROJECT_ENVIRONMENT=.venv-sandbox uv sync --frozen --offline`.
   Expect `myclickup/.venv-sandbox/` at the **project root**, not under
   `src/`. You proved this builds from the cache on 2026-09-11.
4. From the depot root:
   `UV_PROJECT_ENVIRONMENT=.venv-sandbox uv run --offline --project myclickup python -m site`.
   Expect `sys.path` to name `myclickup/.venv-sandbox/lib/…`. (`python -m site`
   rather than `python -c`: the policy denies `python -c`.)
5. myclickup's own gate against the new venv:
   `UV_PROJECT_ENVIRONMENT=.venv-sandbox just check` (or its test recipe) from
   `myclickup/`. Record the pass count; you saw 309.
6. Assert, and record the result of each:
   - `myclickup/.venv/pyvenv.cfg` and that shebang are **byte-identical** to
     step 2: the host-slot venv untouched.
   - `git -C myclickup status --porcelain` is empty, because of the self-ignore.
   - `myclickup/.venv-sandbox/pyvenv.cfg`: which interpreter and version uv
     picked. With no `.python-version` it will likely be the newest baked (3.13),
     which is evidence for T2's pin.
7. paperbridge: `UV_PROJECT_ENVIRONMENT=.venv-sandbox uv sync --frozen --offline`
   from `paperbridge/`. **Expected to fail** on the cold cache. Record the first
   missing package. Do not open egress. A partial `.venv-sandbox` left behind
   is self-ignored and disposable; just report it.
8. `just status` from the depot root: the channel is unaffected.

Leave `myclickup/.venv-sandbox` in place: it is the venv the rule wants. Delete
nothing.

**T1 — agentic-conventions: the rule, for every repo** (your ADR-0017 +
work/0022 proposal; agreed). Normative points the ADR should carry:

1. The environment names the venv. Sandboxes export
   `UV_PROJECT_ENVIRONMENT=.venv-sandbox`; hosts leave it unset and use `.venv`.
   The two-hosts exception, stated.
2. Repos never hard-code a venv path: use `uv run`. Where a path is unavoidable
   (justfile variables, shell scripts), derive it from `UV_PROJECT_ENVIRONMENT`
   with `.venv` as the fallback. **Never select a venv by OS** — a Linux host and
   a Linux sandbox are both "linux".
3. `.venv*/` in `.gitignore`.
4. A tracked `.python-version`, pinned to a version every environment the repo
   runs in actually has.
5. Agents never create, sync into, or delete a venv other than their own
   environment's; `pyvenv.cfg` `home` says whose a venv is. A venv is rebuilt,
   never renamed.
**5a. Only uv's project commands read the variable** (`uv run`, `uv sync`,
   `uv venv`). **The `uv pip` interface ignores it** and picks `VIRTUAL_ENV` or a
   `.venv` in the current directory, which in a container is the host's. Measured
   2026-09-11, uv 0.12.9. So any `uv pip …` a repo documents names its target:
   `--python .venv-sandbox` in the sandbox. A venv directory is accepted.
6. **Permission rules — allow and ask/deny are opposite jobs, so they get
   opposite rules.** (Amended 2026-09-11; the first version said "use `uv run`"
   for all rules, which is wrong for ask/deny.) Rules can't interpolate env
   vars, and they match the literal command text: `python3 x.py` does not match
   a `python x.py` rule. Facts from code.claude.com/docs/en/permissions.md and
   permission-modes.md: deny > ask > allow, across settings scopes; an explicit
   ask rule still forces a prompt in `auto` mode; ask/deny rules match
   subcommands of `cd … && …` compounds; `*` works mid-rule and matches any text.
   - **Allow rules grant permission, so fewer spellings is safer.** Use the
     `uv run …` form only — one rule covers every environment. Never put a venv
     path in an allow rule.
   - **Ask and deny rules put a fence around a command with side effects (a
     write, an upload), so every spelling must be caught.** Any spelling missing
     from the fence falls through to whatever broad allow exists. The sandbox
     allows `python:*`, `python3:*` and `uv run:*`, and runs in `auto` mode, so
     that spelling goes to the classifier instead of to a person. For each
     script `X`, the fence is these four rules:

     ```
     Bash(python*X*)                 # python, python3, python3.12
     Bash(uv run *X*)                # uv run X, uv run python X, uv run --locked python3 X
     Bash(.venv*/bin/python*X*)      # .venv (host) AND .venv-sandbox, python/python3
     Bash(./.venv*/bin/python*X*)    # the ./ spelling of the same
     ```

     Add `Bash(X*)` + `Bash(./X*)` if `X` is executable, and
     `Bash(python* -m <module>*)` if it is importable as a module. An explicit
     enumeration (one rule per spelling) is also valid, but it has to be
     complete. The common miss is `python3`.
   - **The residual the matcher can't close:** an absolute-path spelling
     (`/workspace/<repo>/.venv-sandbox/bin/python X`). Leading wildcards are not
     documented, so don't rely on one. A command with irreversible side effects
     should also refuse to act without an explicit flag (dry-run by default), so
     the permission rules are not the only thing standing in the way.
   - **Worked example:** `therapod/citation_tools/.claude/settings.json`. It had
     five explicit spellings per script, both venvs included, with no `python3`
     form. The four wildcard rules above were added on 2026-09-11 and the
     explicit rules kept. The apply-conventions audit should do what
     macolima's scan does: generate the spellings for each script named in
     ask/deny rules and report any that no rule matches.

**Added 2026-09-11, same template, same release — the general `.local` rule.**
`templates/.gitignore` today ignores `AGENTS.local.md`, `**/AGENTS.local.md` and
`.claude/settings.local.json` by name. The owner wants `.local` to mean
"machine-local, never committed" for any file, in every repo. Two shapes, because
the suffix sits in two places by convention:

```gitignore
*.local
*.local.*
!*.local.example*
```

The second line already covers the three named entries; whether to keep them
for their comments is your call. **The negation was added after the first
cross-repo scan (2026-09-11):** `*.local.*` also matches a committed *example*
of a local file (`config/hub.local.example.yaml` in one repo). Git keeps an
already-tracked file tracked, but every new example would be hidden without a
word. A committed example is documentation for every clone, so the convention
re-includes it. Other legitimate collisions are per-repo `!` exceptions, not
template lines; the one found is an Xcode `*.local.entitlements`. macolima
adopted exactly these three lines on 2026-09-11, and no tracked file there
became ignored. Before shipping, check
agentic-conventions and each member for tracked files the pair would match
(`git ls-files | grep -E '\.local($|\.)'`) — ignoring doesn't untrack, so a hit
is a decision, not a silent change. The apply-conventions audit should flag a
repo whose `.gitignore` misses either shape; macolima's all-repo scan checks the
same thing from the host side.

Artifacts: `templates/.gitignore` line; a short reference paragraph (you proposed
placing it in the brownfield gitignore step — agreed, plus a pointer from
wherever the reference discusses runtime specifics being out of scope, since
this is the stated exception); the apply-conventions audit flagging: hard-coded
`.venv[-*]/bin/` in tracked files, `os()`-based venv selection, venv paths in
settings allow rules, missing `.python-version`, `.gitignore` not covering
`.venv-sandbox/`. Then CHANGELOG, 0.8.0 → 0.9.0, `just sync-plugin`,
`just check`.

**T2 — myclickup (local commit):** `.gitignore` `.venv*/` and the `.local` pair; `.python-version`;
the prose in §3. Pick the pin with the owner if 3.12 vs 3.13 is not obvious from
the gate.

**T3 — paperbridge (local commit):** `.gitignore` `.venv*/` and the `.local` pair; `.python-version`
(its ruff/mypy target 3.12 — that suggests 3.12); prose if found. Report the
`settings.local.json` rules to the owner.

**Before T4 — the pre-switch hazard (added 2026-09-11).** Until your profile
exports the variable, any `uv run` / `uv sync` **without** the
`UV_PROJECT_ENVIRONMENT=.venv-sandbox` prefix, in a member whose `.venv` is the
host's, deletes and rebuilds that `.venv`: uv sees the Mac interpreter and
can't use it. That's **paperbridge** today. It includes
`just publish paperbridge`, because `channel.py` runs
`uv run --project <member>` for `gen_allow`. So until the switch, publish
paperbridge from the host, as your AGENTS.md already says for a cold cache, or
prefix the variable. myclickup's `.venv` is container-built, so its publishes
are unaffected.

**T4 — publish** `myconv` 0.9.0 through the channel (`just publish …`), and a
member only if its gate says the artifact changed — a `.gitignore` /
`.python-version` / README-only change may not; that is your call. Then the
re-vendor is the owner's.

**T5 — (T0 already built the venv; this confirms it under the real variable)
after you are told the `nranthony` profile was recreated with the
variable:**
- `echo $UV_PROJECT_ENVIRONMENT` → `.venv-sandbox`.
- myclickup: `uv sync --frozen` (a no-op if T0's venv is current) → run its
  gate → report `myclickup/.venv` (container-built, `home = /usr/bin`) as a
  **Phase F** candidate. The rollout deletes old venvs only after the profile
  has run cleanly for a while, and deletion is a human step. Don't delete it.
- paperbridge: expected to fail offline. Your T0 found `certifi` missing, and
  pydantic, lxml, requests, ruff and pyzotero are all absent from the cache, so
  it needs the owner's egress window (plan stage 6).
  Don't open egress yourself; report, and it either waits for an egress window
  or stays a host-side gate as your `AGENTS.md` already says.
- `git status` in both members stays clean with the new venv present.

## 5. What has to happen on the sandbox side (do not attempt, do not pick the verb)

macolima carries: the compose variable, the deletion-hook carve-out, a new
"Python environments" section in the sandbox notice, a `verify-sandbox`
assertion, a VS Code interpreter setting, and its own ADR — tracked in its
work/0008. The payload classes are **compose environment** (takes effect on the
profile's recreate) and **notice/hook text** (converge). Nothing you ship changes
any of it, and none of your tasks needs it except T5.

windows-ai-sandbox gets the same set, human-ferried from macolima.

## 6. What to hand back

Into `macolima/work/0008-venv-per-environment/` via the owner (macolima has no
inbox; the owner ferries it), or reply in the thread that carries this doorbell:

0. **T0 results first — macolima's merge of the switch waits on them:** the uv version,
   the step-3/4 paths, the gate's pass count, the three step-6 assertions, the
   interpreter uv picked, paperbridge's first missing package, and `just status`.
1. The agentic-conventions ADR number and the myconv version that ships it —
   macolima's ADR and the other profiles' handoffs will cite it.
2. **Any disagreement with §1 raised in review, before macolima's compose change
   merges.** If the rule moves, the compose value moves with it.
3. Confirmation of the §3 checks, and any hard-coded venv reference in the members
   not listed there.
4. T5 results: myclickup built and green on `.venv-sandbox`; paperbridge state.
5. Which `.python-version` each member pinned.

Closing state from this side: macolima owes you the "variable is live on your
profile" signal (T5 gate). Nothing else outstanding.
