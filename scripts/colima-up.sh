#!/usr/bin/env bash
# =============================================================================
# colima-up.sh — first-time Colima start with the flags we want persisted
# =============================================================================
# Run this ONCE after bootstrap.sh. Colima writes the flags into its config;
# from then on, plain `colima start` (or scripts/start.sh) is enough.
# =============================================================================
set -euo pipefail

: "${COLIMA_HOME:?COLIMA_HOME must be set — run: source ~/.zshrc}"

DRIVE="/Volumes/DataDrive"

# RESOURCE SIZING — this file is the source of truth. `colima delete` wipes
# colima.yaml, so whatever is written here is what a rebuilt VM gets, and any
# doc that restates these numbers can drift away from them silently (it did:
# README and sandbox-design-notes both claimed 10 GB / 80 GB while this said
# 6 GB / 128 GB and the running VM had 8 GB / 128 GB).
#
# Sized against what a profile actually costs, from docker-compose.yml:
#   claude-agent  3g   + postgres 512m + mongo 512m + egress-proxy 512m
#   => ~4.0g per profile without mongo, ~4.5g with it.
# 8 GB comfortably runs one profile with headroom for the VM itself; two
# concurrent profiles want ~12 GB and three ~16 GB. Raise --memory here if you
# intend to run profiles side by side, then `colima delete && scripts/colima-up.sh`
# (or `colima stop && colima start --memory N` to change an existing VM).
#
# --memory is deliberately NOT raised past 8 on a 16 GB host. Under vmType vz the
# guest's footprint climbs toward its ceiling and is not handed back to macOS, so
# the number behaves more like a reservation than a cap; 8 leaves room for the
# host, editors and a browser. Run two profiles one at a time rather than sizing
# the VM for both.
#
# --disk is sparse: the backing files under $COLIMA_HOME/_lima live on the
# DataDrive (hundreds of GB free, unlike the ~37 GB internal disk), and consume
# only what is written. Generous is close to free, so this is set well above what
# a rebuild actually needs. Two asymmetries justify the headroom:
#   - growing is live (`colima start --disk N`); shrinking needs a full delete;
#   - the sparse file is a one-way ratchet — `docker system prune` frees space
#     inside the VM, but the host-side file never shrinks back.
echo "[INFO] Starting Colima with mounts from $DRIVE ..."
colima start \
  --vm-type vz \
  --vz-rosetta \
  --mount-type virtiofs \
  --cpu 6 \
  --memory 8 \
  --disk 200 \
  --mount "$DRIVE/repo:w" \
  --mount "$DRIVE/.claude-colima:w"

echo ""
echo "[ OK ] Colima up. Verify with:"
echo "        colima status"
echo "        colima ssh -- ls /Volumes/DataDrive"
echo "        docker run --rm hello-world"
