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

echo "[INFO] Starting Colima with mounts from $DRIVE ..."
colima start \
  --vm-type vz \
  --vz-rosetta \
  --mount-type virtiofs \
  --cpu 6 \
  --memory 10 \
  --disk 80 \
  --mount "$DRIVE/repo:w" \
  --mount "$DRIVE/.claude-colima:w"

echo ""
echo "[ OK ] Colima up. Verify with:"
echo "        colima status"
echo "        colima ssh -- ls /Volumes/DataDrive"
echo "        docker run --rm hello-world"
