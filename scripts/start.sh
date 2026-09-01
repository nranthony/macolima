#!/usr/bin/env bash
# =============================================================================
# start.sh — start the Colima VM + bring up macolima profile(s)
# =============================================================================
# Usage:
#   scripts/start.sh                  # VM only, no profiles started
#   scripts/start.sh <profile>        # VM + one profile
#   scripts/start.sh <p1> <p2> ...    # VM + multiple profiles
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

: "${COLIMA_HOME:?COLIMA_HOME must be set — run: source ~/.zshrc}"

# --- sizing drift check ------------------------------------------------------
# scripts/colima-up.sh is the declared source of truth for --cpu/--memory/--disk,
# but the VM actually boots from Colima's generated colima.yaml, which a manual
# `colima start --memory N` rewrites without touching the repo. Nothing
# reconciled the two until this check, and they had already diverged: the script
# said 6 GB, the running VM had 8, and two docs claimed 10 — so the documented
# post-`colima delete` recovery would have silently downgraded the VM.
#
# Warn, never fail: a mismatch is a bookkeeping problem, not a reason to block a
# start, and the live VM is not wrong — it is just undeclared.
declared_sizing() {  # <cpu|memory|disk> — value passed by colima-up.sh
  # Read only from the `colima start` invocation onward, so prose in the
  # rationale comment above it (which mentions --memory) can never be matched.
  sed -n '/^colima start/,$p' "$REPO_ROOT/scripts/colima-up.sh"     | sed -n "s/^[[:space:]]*--$1[[:space:]][[:space:]]*\([0-9][0-9]*\).*/\1/p"     | head -1
}

live_sizing() {  # <cpu|memory|disk> — value the VM actually booted with
  # Anchored so `rootDisk:` and `cpuType:` cannot match `disk:` / `cpu:`.
  sed -n "s/^$1:[[:space:]]*\([0-9][0-9]*\).*/\1/p" \
    "$COLIMA_HOME/default/colima.yaml" 2>/dev/null | head -1
}

check_sizing_drift() {
  local cfg="$COLIMA_HOME/default/colima.yaml"
  if [[ ! -r "$cfg" ]]; then return 0; fi
  local key declared live drift=0
  for key in cpu memory disk; do
    declared="$(declared_sizing "$key")"
    live="$(live_sizing "$key")"
    if [[ -z "$declared" || -z "$live" ]]; then continue; fi
    if [[ "$declared" != "$live" ]]; then
      echo "[WARN] VM $key is $live, but scripts/colima-up.sh declares $declared."
      drift=1
    fi
  done
  if [[ $drift -eq 1 ]]; then
    echo "[WARN] A 'colima delete' would rebuild the VM with the DECLARED values."
    echo "       Reconcile by editing scripts/colima-up.sh to match the live VM,"
    echo "       or by applying the declared values:"
    echo "         colima stop && colima start --cpu N --memory N --disk N"
    echo "       (disk grows only; shrinking it needs a delete.)"
  fi
}

if colima status &>/dev/null; then
  echo "[INFO] Colima is already running."
else
  echo "[INFO] Starting Colima VM ..."
  colima start
  echo "[ OK ] Colima running."
fi

check_sizing_drift

if [[ $# -eq 0 ]]; then
  echo "[INFO] No profiles specified. VM is up; start a profile with:"
  echo "         scripts/start.sh <profile>"
  echo "         scripts/setup.sh <profile> --restart"
  exit 0
fi

for p in "$@"; do
  echo "[INFO] Bringing up profile '$p' ..."
  "$REPO_ROOT/scripts/profile.sh" "$p" up
done

echo "[ OK ] Done."
