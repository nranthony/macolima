# Debug recipes

Routine commands for operating a profile. Non-obvious gotchas live in `../CLAUDE.md`.

```bash
# One-shot verify (auth status for claude/gh/glab + git identity + compose ps)
scripts/setup.sh <p> --verify

# Force recreate (covers compose/seccomp/mount changes) via wrapper
scripts/setup.sh <p> --recreate

# Full rebuild + recreate (covers Dockerfile changes)
scripts/profile.sh <p> rebuild

# Blank-slate a profile but KEEP auth (claude creds + claude.json + gh + glab + git identity).
# Tears down containers, drops vscode-server volume, nukes everything else under
# profiles/<p>/ except the auth files, then re-seeds settings.json + skills from
# config/. DB volumes (postgres-data/mongo-data) are preserved unless you pass
# --all-volumes. Confirms first; --dry-run prints the plan, --yes skips the prompt.
scripts/profile.sh <p> wipe --dry-run
scripts/profile.sh <p> wipe                    # interactive (type profile name to confirm)
scripts/profile.sh <p> wipe --yes              # non-interactive
scripts/profile.sh <p> wipe --all-volumes      # also drop postgres/mongo named volumes

# Recreate only (covers seccomp / mounts / env / squid.conf changes)
PROFILE=<p> COMPOSE_PROJECT_NAME=macolima-<p> docker compose up -d --force-recreate

# Proxy reload (covers allowed_domains.txt) — per profile
PROFILE=<p> COMPOSE_PROJECT_NAME=macolima-<p> docker compose restart egress-proxy

# Probe gitstatusd / zsh init with a TTY
docker exec -t claude-agent-<p> zsh -ic 'echo ok'

# Enable p10k debug logs: add `export GITSTATUS_LOG_LEVEL=DEBUG` to config/.zshrc, rebuild
docker exec claude-agent-<p> sh -c 'cat /tmp/gitstatus.*.log'

# Verify a domain reaches through the proxy
scripts/profile.sh <p> exec curl -sI https://<host>/ -o /dev/null -w '%{http_code}\n'

# Tail Squid access log (forensic trail of every proxy request)
docker exec -u proxy egress-proxy-<p> tail -f /var/log/squid/access.log

# Inside-container hardening sweep — stage the audit package first so the
# script is available inside the container (it's not in /workspace otherwise)
scripts/stage-audit-package.sh <p>
scripts/profile.sh <p> exec bash /workspace/temp_audit_package/scripts/verify-sandbox.sh

# Trivy scan (host-side, requires `brew install trivy`) — config + secret + image
scripts/trivy-scan.sh                    # all three (default)
scripts/trivy-scan.sh config             # Dockerfile/compose misconfig only
scripts/trivy-scan.sh image              # CVE scan of macolima:latest
scripts/trivy-scan.sh 2>&1 | tee /tmp/trivy-$(date +%Y%m%d).log  # keep a record

# Stage sandbox config into a profile workspace for an in-container audit
scripts/stage-audit-package.sh <p>              # stage /workspace/temp_audit_package/
scripts/stage-audit-package.sh <p> --clean      # remove when done
```

Accepted CVEs/misconfigs live in `../.trivyignore.yaml` with dated `expired_at` fields — on each expiry, re-run Trivy, and either delete the entry (upstream fixed it) or extend the date with a refreshed statement.
