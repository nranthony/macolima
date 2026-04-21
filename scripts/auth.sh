#!/usr/bin/env bash
# =============================================================================
# auth.sh — run `claude login` once; the OAuth token persists on the drive
# =============================================================================
# The token lands in /Volumes/DataDrive/.claude-colima/claude-home and survives
# container restarts / rebuilds. Treat that directory like an SSH private key.
# =============================================================================
set -euo pipefail

DRIVE="/Volumes/DataDrive"

docker run -it --rm \
  -v "$DRIVE/.claude-colima/claude-home":/home/agent/.claude \
  -e HTTP_PROXY -e HTTPS_PROXY \
  macolima:latest \
  claude login
