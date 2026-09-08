# work/0006 — pnpm 10 → 12 upgrade

Status: **spec only, not scheduled.** Raised 2026-09-08 by a `pnpm install`
update notice inside a profile (`10.34.5 → 12.3.4`).

## Ask

Decide whether to move the image off `pnpm@10` (`Dockerfile:109`), and if so,
migrate the config this repo seeds for pnpm — which pnpm 11 relocates out from
under us.

## Version facts (checked against the live registry + release notes, 2026-09-08)

| tag | version | date |
|---|---|---|
| `latest-10` | 10.34.5 | shipped in our image as `pnpm@10` |
| `latest-11` | 11.26.0 | 11.0.0 was 2026-04-28 |
| `latest` / `latest-12` | 12.3.4 | 12.0.0 was 2026-08-26; 12.3.4 is 2026-09-04 |
| `next-12` | 12.4.0 | 2026-09-08 |

Node floor is a non-issue: 11 requires Node 22+, the image is on NodeSource 24
(`Dockerfile:107`).

## Why we would take it

1. **Supply-chain defaults, on by default.** 11 ships `minimumReleaseAge: 1440`
   (won't resolve anything published in the last 24h), `blockExoticSubdeps:
   true`, `strictDepBuilds: true`. That is the posture `Dockerfile:256` records
   as a KNOWN GAP for pnpm and that `profile.sh:874` currently hand-seeds as
   `minimum-release-age=10080`. Note our 7 days is STRICTER than 11's 1-day
   default — an upgrade must carry the value across, not inherit the default.
2. **Git deps stop recording SSH URLs (12.0).** Every spelling of a GitHub /
   GitLab / Bitbucket dep resolves through the host's canonical HTTPS URL and
   the lockfile never stores an SSH form. `openssh-client` is deliberately
   purged here (`docs/vscode-leakage.md`), so a lockfile that resolved to SSH on
   someone's laptop is uninstallable inside a profile. 12 removes the transport
   probe that produced those.
3. **Deterministic lockfiles (12.0).** Canonical cycle-breaking makes the
   lockfile a pure function of the dependency graph — byte-identical across
   importer and resolution order; 2–3× faster peer resolution on cycle-heavy
   workspaces.
4. **Speed.** SQLite store index (store v11), undici + Happy Eyeballs,
   direct-to-CAS writes; the whole 12.3.x line is large-workspace speedups.

## The load-bearing cost: pnpm 11 moves our config out from under us

**pnpm 11 makes `.npmrc`-style rc files auth/registry ONLY.** Every other
setting must live in `pnpm-workspace.yaml` or the new global `config.yaml`, and
env vars take a `pnpm_config_*` prefix.

`profile.sh:859-875` (`ensure_state`) seeds two keys into the per-profile
`~/.config/pnpm/rc`:

- `manage-package-manager-versions=false` — stops pnpm re-exec'ing a downloaded
  binary out of `~/.local/share/pnpm/.tools/`, which is a noexec tmpfs (EACCES).
- `minimum-release-age=10080` — the 7-day quarantine.

On 11+ both sit in a file pnpm no longer reads for settings. Failure mode is
SILENT: the quarantine does not disappear, it quietly drops 7 days → 1 day, and
the version-manager guard just stops applying.

Worse, `deny-destructive.sh:334` guards `~/.config/pnpm/rc` as a
quarantine-tamper target (asserted by `deny-destructive.test.sh:335`). After the
upgrade that hook defends a file nothing reads while the file that matters is
unguarded — a protection that still passes its own test.

So this is a `profile.sh` + hook + hook-test + `Dockerfile` change, not a
version bump.

Secondary migration items:

- `onlyBuiltDependencies`, `onlyBuiltDependenciesFile`, `neverBuiltDependencies`,
  `ignoredBuiltDependencies`, `ignoreDepScripts` are REMOVED → `allowBuilds`.
- `auditConfig.ignoreCves` → `ignoreGhsas` (audit moved to npm's bulk endpoint).
- npm-passthrough commands now throw "not implemented" (publish/login/view/etc.
  are native in 11).
- Store v11 (SQLite) ⇒ first install re-downloads and re-hashes the store.
- 12.0: an unrecognized key in `pnpm-workspace.yaml` warns, and ERRORS
  (`ERR_PNPM_UNRECOGNIZED_WORKSPACE_SETTINGS`) when the project pins a pnpm
  version the running pnpm satisfies.

## Recommendation

**Take it, but not yet, and in two hops.**

Not yet: 12.3.4 is four days old and the 12.3.x line has been patching
self-inflicted breakage fast — 12.3.3 fixed installs dying with `syntax error
near unexpected token ')'` under `--ignore-scripts`-style provisioning, 12.3.4
fixed pnpm 12 rejecting boolean flags (`--unsafe-perm`) that 11 accepted, which
failed every install on Vercel. By pnpm's own 24-hour-quarantine logic, let it
settle. Our own `min-release-age=7` says the same thing about anything this
fresh.

Two hops: `pnpm@11` first. 11 carries nearly every breaking config change; 12 is
mostly resolution semantics and the git-URL canonicalization. Splitting them
means a failed install has one candidate cause.

## Steps when scheduled

1. Move the two seeded keys from `~/.config/pnpm/rc` to whatever 11 reads
   (global `config.yaml`), keeping `minimum-release-age=10080` explicit — do NOT
   inherit the 1-day default.
2. Repoint `deny-destructive.sh:334` at the new path, keeping the old path in
   the ruleset too (a profile can hold both files across the transition).
   Extend `deny-destructive.test.sh` to assert both.
3. `Dockerfile:109` `pnpm@10` → `pnpm@11`, and refresh the comment block at
   `Dockerfile:97-104` (it names "pnpm 10's own version manager") and the KNOWN
   GAP note at `Dockerfile:256-261`, which an upgrade partly closes.
4. `scripts/profile.sh build` (no profile arg) then `<p> rebuild` per profile.
5. Verify inside a profile: `pnpm config get minimum-release-age` reports 10080,
   and a `pnpm add` of a package published today is refused.
6. Second hop to `pnpm@12` once 12.4.x has settled.

## Not covered

Installing pnpm at all needs `registry.npmjs.org`, which is PLANNING-MODE in
`proxy/allowed_domains.txt` — uncomment for the rebuild, recomment after. The
image build fetches it at build time, not the agent at runtime.
