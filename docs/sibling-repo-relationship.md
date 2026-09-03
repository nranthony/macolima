# Sibling repo: windows-ai-sandbox

`macolima` and `windows-ai-sandbox` are **two implementations of one threat
model on different substrates.** This repo is the origin; the sibling was ported
from it, and has since moved ahead in several areas that are now being ported
back (`work/0005`). They share lineage but must never be blind-copied between —
the value of keeping both is that each is an independent check on the other.

Measurements below were taken 2026-09-03 against `windows-ai-sandbox@52b7c91`.
Re-measure before trusting them; the point of the section is the *method*, not
the numbers.

## Shared (a finding in one is almost always latent in the other)

- **Network model** — `sandbox-internal` (`internal: true`, per-profile
  `172.30.<octet>.0/24`) + Squid egress allowlist + DNS sinkhole + `extra_hosts`
  static IPs.
- **`seccomp.json`** — **functionally identical today** (verified by comparing
  the two files with `_`-prefixed comment keys stripped). The `creat` allowance
  the sibling added in its `work/0017` is present here.
- **VS Code attach-time leakage findings A–E** — SSH-agent forwarding, host
  `~/.gitconfig` copy, IPC credential-helper injection, orphan UID-0 shell,
  Copilot IDE state. These are **VS Code Dev Containers behaviour, platform
  independent.**
- **In-container mitigations** — `openssh-client` purged, `credential.helper`
  scrub on every `up`, `.zshrc` `unset SSH_AUTH_SOCK`.
- **Three-tier verification** — `verify-sandbox.sh` tripwire → audit probes →
  agent-side judgment skill.
- **Audit probe set** — the same nine probes on both sides today
  (`antigravity`, `env`, `fs`, `identity`, `network`, `proxy`,
  `seccomp_runtime`, `seccomp_static`, `settings`). A probe one side has and the
  other lacks is the single highest-value thing to look for.

## Divergent (copying these *causes* flaws)

| Axis | here (macolima) | windows-ai-sandbox |
|---|---|---|
| Host / runtime | macOS + Colima VM + **rootful** Docker | Windows + WSL2 + **rootless** Docker |
| Container user | `agent` UID 1000, **non-root** | **root** UID 0 = host UID 1000 (`userns=host`) |
| Privilege boundary | unprivileged user + dropped caps | rootless userns remap + dropped caps |
| `remoteUser` | `agent` | **`root`** (copying `agent` → remaps to `nobody`, breaks writes) |
| VS Code config carrier | per-repo attach `devcontainer.json` | host-side user `settings.json` + attached-container config |
| Host settings path | `~/Library/Application Support/Code/User/` | `%APPDATA%\Code\User\` |
| Names / prefix / state | `claude-agent-<p>`, `macolima-<p>`, `/Volumes/DataDrive/.claude-colima/` | `ai-sandbox-<p>`, `ai-sandbox-<p>`, `~/.ai-sandbox/` |
| Home paths inside | `/home/agent/...` | `/root/...` |
| FS quirk fought | virtiofs (named volumes for `.cache`/`.vscode-server`) | WSL2 inode/ownership |
| `/usr/bin/env bash` | **3.2.57** (macOS) — no assoc arrays, no `mapfile` | 5.x |
| Allowlist leading-dot entry | **DRIFT** (`proxy/no_vendor_wildcards`) | reported as **INFO** — see below |
| Hook write-protect | **kernel-enforced**: hook is UID 0, agent is UID 1000 | **not enforceable**: agent IS root; the defence is that the engine is baked into the image, so an edit dies on recreate |
| Allowlist size | 14 tagged blocks, 431 lines | 21 tagged blocks, 749 lines |
| GPU / ML stack | none, and deliberately so (no device passthrough) | `[nvidia]`, `[pytorch]`, `[comfyui]`, `/dev/dxg` |
| Offline test suites | 10, run by `just test-offline` | 10 |

**Why leading-dot entries are DRIFT here and INFO there.** This allowlist can be
kept to leaf hosts and is; the sibling's cannot, because `.fal.media` is a
delivery CDN whose host set is not enumerable, and collapsing it to one wildcard
*was* the security change there. Do not loosen this repo's verdict to match, and
do not tighten theirs — leaf-only discipline is achievable on this smaller
surface and is worth keeping precisely because it is.

**The hook row is the one most likely to be ported wrongly, in both
directions.** This repo's `settings/hook_file_immutable` probe measures a real
kernel guarantee (root-owned file, non-root agent). The same probe on the
sibling would measure nothing. Conversely, a rootless-userns concern there has
no analogue here. When porting a control, filter it through the privilege axis
first — and do not dismiss one merely because the sibling frames it in `root`
terms where this repo would say `agent`.

## The `bash 3.2` filter, which applies to every script ported here

`/usr/bin/env bash` on macOS is **3.2.57**, released 2007. The sibling is
written against 5.x. Three hazards, all measured in this repo:

1. **`mapfile`/`readarray` do not exist.** They fail as an *unset array*, not as
   command-not-found — so a loop over the result iterates zero times and every
   check inside it passes **vacuously**. This is the dangerous one: a ported
   test suite goes green by doing nothing.
2. **No associative arrays**, and `if…then…fi` rather than trailing `&&` chains.
3. **`"$( … "…" … )"` mis-parses.** A nested double quote inside a
   double-quoted command substitution terminates the OUTER quote in 3.2.57,
   leaving the result unquoted and brace-expanded. Found in one assertion of a
   ported test, where it silently split one argument into two.

## How to mine the sibling for flaws we might miss

1. **Diff the controls, not the prose.**
2. **Compare probe check-for-check, not file-for-file** — a file-level `ls` diff
   misses renames and in-place strengthening in both directions.
3. **Filter every candidate through the privilege axis** (see the hook row).
4. **Filter every ported script through bash 3.2** before trusting its output.

## Quick cross-check commands

Assuming both repos are checked out as siblings:

```bash
MAC=/Volumes/DataDrive/repo/sandbox/macolima
SIB=/Volumes/DataDrive/repo/sandbox/windows-ai-sandbox

# seccomp: compare FUNCTION, not bytes. The two files carry different
# substrate notes in their `_comment` keys by design, so a raw `diff` is
# permanently noisy and gets ignored — which is the failure mode this repo
# names elsewhere as "a check that cries wolf on its first run".
python3 -c '
import json,sys
def strip(o):
    if isinstance(o,dict): return {k:strip(v) for k,v in o.items() if not k.startswith("_")}
    if isinstance(o,list): return [strip(x) for x in o]
    return o
a,b=[strip(json.load(open(p))) for p in sys.argv[1:]]
print("seccomp functionally identical:", a==b)
' "$MAC/seccomp.json" "$SIB/seccomp.json"

# Allowlists diverge by design — a raw diff is noise. Compare the TAG SETS,
# then read only the blocks that differ.
tags() { grep -oE '^# -+ .*\[[a-z0-9-]+\] -+$' "$1" | grep -oE '\[[a-z0-9-]+\]' | sort -u; }
tags "$MAC/proxy/allowed_domains.txt" > /tmp/mac.tags
tags "$SIB/proxy/allowed_domains.txt" > /tmp/sib.tags
comm -13 /tmp/mac.tags /tmp/sib.tags   # theirs only — candidates, not obligations
comm -23 /tmp/mac.tags /tmp/sib.tags   # ours only

# Probe file names, as a first pass only (see method note 2).
ls "$MAC/scripts/audit/probes" > /tmp/mac.probes
ls "$SIB/scripts/audit/probes" > /tmp/sib.probes
diff /tmp/mac.probes /tmp/sib.probes
```

Note the two `comm` invocations use temp files rather than process substitution:
`<(...)` opens `/dev/fd/N`, which some sandboxes refuse.

## The live backlog in both directions

- [`work/0005`](../work/0005-w-parity-backlog/spec.md) — sibling → here. The
  ranked port backlog, re-validated against what has already landed rather than
  restating their handoff. Its §2 records what is **deliberately excluded** (the
  whole GPU/ML stack, `glab`, `beads`, the PDF/OCR stack) so absence is not
  re-litigated as oversight.
- **§3 of that same file** — here → sibling. Ten items owed back, four of them
  defects in their own code: the cross-device `mktemp` staging in
  `converge_skills`, a `docs/` instruction that says "recreate" and then prints
  `up`, `docker builder prune --keep-storage` silently negating `--refresh-ai`,
  the block-walker guard in `proxy.py`, and the unguarded `CLAUDE.md` overwrite
  in `sync-agent-files.sh`.

There is no automated sync between the repos and there should not be. Every
carry is a decision with a substrate filter in front of it.
