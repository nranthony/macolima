#!/usr/bin/env bash
# =============================================================================
# attach.sh — open an interactive shell inside the running agent container
# =============================================================================
set -euo pipefail
exec docker exec -it claude-agent bash
