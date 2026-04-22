#!/usr/bin/env bash
# =============================================================================
# trivy-scan.sh — static + image security scan for the macolima sandbox
# =============================================================================
# Usage: scripts/trivy-scan.sh [config|secret|image|all]  (default: all)
#
# Runs on the HOST (macOS), not inside a container. Requires `trivy` on PATH
# (brew install trivy). First run downloads the CVE DB (~700MB, cached).
#
# Modes:
#   config   misconfig scan of Dockerfile + docker-compose.yml
#   secret   secret scan of the repo (catches accidentally-committed creds
#            — especially relevant for profiles/<p>/db.env leakage)
#   image    CVE scan of the built macolima:latest image (HIGH/CRITICAL,
#            fixed-only — drops the Ubuntu "won't fix" noise)
#   all      run all three (default)
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="macolima:latest"
IGNORE_FILE="$REPO_DIR/.trivyignore.yaml"
MODE="${1:-all}"

command -v trivy >/dev/null || { echo "trivy not found — brew install trivy" >&2; exit 1; }

hdr() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }

run_config() {
  hdr "config scan (Dockerfile + docker-compose.yml misconfig)"
  trivy config --exit-code 0 --ignorefile "$IGNORE_FILE" "$REPO_DIR"
}

run_secret() {
  hdr "secret scan (repo tree)"
  # Skip profiles/ explicitly — that dir is user state with real creds
  # (db.env), lives outside this repo in practice, but skip here too in
  # case a symlink or stray file ends up under the repo root.
  trivy fs --scanners secret \
    --skip-dirs "profiles,temp_audit_package" \
    --exit-code 0 "$REPO_DIR"
}

run_image() {
  hdr "image CVE scan ($IMAGE, HIGH/CRITICAL, fixed-only)"
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "image $IMAGE not found locally — build first: scripts/profile.sh <p> build" >&2
    return 1
  fi
  trivy image \
    --severity HIGH,CRITICAL \
    --ignore-unfixed \
    --ignorefile "$IGNORE_FILE" \
    --exit-code 0 \
    "$IMAGE"
}

case "$MODE" in
  config) run_config ;;
  secret) run_secret ;;
  image)  run_image ;;
  all)    run_config; run_secret; run_image ;;
  *) echo "usage: $0 [config|secret|image|all]" >&2; exit 1 ;;
esac
