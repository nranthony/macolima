import os
import subprocess
from typing import Dict, List, Optional

import docker

# Path to the allowlist INSIDE the egress-proxy container. Module-level and
# unabbreviated on purpose: scripts/with-egress.test.sh greps this exact name to
# assert that all four call sites (squid.conf's acl, with-egress.sh, profile.sh
# and this dashboard) name the same path. It moved from /etc/squid/ to
# /etc/squid/host/ in work/0001 A2, when proxy/ became a DIRECTORY mount — a
# single-file bind mount pins an inode at container start and goes silently
# blind to host edits. Change this only together with the compose mount target
# and the squid.conf acl.
PROXY_ALLOWLIST = "/etc/squid/host/allowed_domains.txt"


def _resolve_docker_host() -> Optional[str]:
    """Resolve the Docker daemon URL the same way the docker CLI does.

    Python's `docker.from_env()` only reads $DOCKER_HOST and falls back to
    `unix:///var/run/docker.sock`. On macOS with Colima the socket lives at
    `~/.colima/<profile>/docker.sock` (or a custom location like
    `/Volumes/DataDrive/.colima/default/docker.sock` here), and the docker
    CLI finds it via the active context — which the SDK ignores. So we shell
    out to the CLI to read the active context's endpoint.

    Returns the URL (e.g. `unix:///path/to/docker.sock`) or None to mean
    "let docker.from_env() do its thing."
    """
    # 1. $DOCKER_HOST always wins if set.
    env_host = os.environ.get("DOCKER_HOST")
    if env_host:
        return env_host

    try:
        ctx = subprocess.run(
            ["docker", "context", "show"],
            capture_output=True, text=True, timeout=3, check=False,
        )
        if ctx.returncode != 0:
            return None
        ctx_name = ctx.stdout.strip()
        if not ctx_name or ctx_name == "default":
            return None  # default context = SDK default; nothing to override

        endpoint = subprocess.run(
            ["docker", "context", "inspect", ctx_name,
             "--format", "{{.Endpoints.docker.Host}}"],
            capture_output=True, text=True, timeout=3, check=False,
        )
        if endpoint.returncode != 0:
            return None
        return endpoint.stdout.strip() or None
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return None


class DockerClient:
    def __init__(self):
        try:
            host = _resolve_docker_host()
            if host:
                self.client = docker.DockerClient(base_url=host)
            else:
                self.client = docker.from_env()
            self.host = host or "default"
        except Exception:
            self.client = None
            self.host = None

    def get_running_profiles(self) -> List[str]:
        if not self.client:
            return []
        try:
            containers = self.client.containers.list()
        except Exception:
            return []

        profiles = set()
        for container in containers:
            if container.name.startswith("claude-agent-"):
                profiles.add(container.name.replace("claude-agent-", ""))
        return list(profiles)

    # Kept as a class attribute for the existing call sites below; the value
    # is the module-level constant so there is exactly one spelling of the path.
    _ALLOWED_DOMAINS_PATH = PROXY_ALLOWLIST

    def _count_active_domains_in_container(self, container) -> Optional[int]:
        """Count uncommented, non-blank lines in the in-container allowlist.

        Returns None if the file is unreadable inside the container — the
        dead-giveaway of a stale single-file bind mount on macOS virtiofs
        (the host inode the mount latched onto at container start has been
        replaced; the container sees `-?????????` and squid logs
        `ERROR: Can not open file ... for reading` then continues with an
        empty ACL → every request 403s).
        """
        # `sh -c` so we get one round-trip with the test+grep+wc pipeline.
        # `grep -cvE '^\s*(#|$)'` counts non-comment, non-blank lines —
        # matches how squid actually parses the file. `|| true` keeps the
        # pipeline's exit at 0 even when grep finds zero matches (exit 1)
        # so we can disambiguate "0 active domains" from "file unreadable".
        cmd = (
            f"test -r {self._ALLOWED_DOMAINS_PATH} && "
            f"grep -cvE '^\\s*(#|$)' {self._ALLOWED_DOMAINS_PATH} || true"
        )
        try:
            ec, output = container.exec_run(["sh", "-c", cmd])
        except Exception:
            return None
        if ec != 0:
            return None
        text = output.decode(errors="replace").strip()
        if not text:
            return None
        try:
            return int(text.splitlines()[-1])
        except ValueError:
            return None

    def reload_proxy(self, profile: str) -> Dict:
        """Send SIGHUP to squid via `squid -k reconfigure`.

        Zero-downtime, validates the new config before applying — if the
        new allowed_domains.txt has a syntax error squid keeps running
        on the old one and logs the error to /var/log/squid/cache.log.
        Strictly better than `container.restart()` for ACL/allowlist edits.

        Returns a dict:
          {"profile", "ok", "msg", "domains": Optional[int],
           "needs_recreate": bool}.

        `ok=True` requires BOTH that `squid -k reconfigure` exited 0 AND
        that the in-container allowlist is readable — squid happily exits
        0 on a reconfigure that loaded an empty ACL because the included
        file was unreadable, which silently 403s every domain. We catch
        that here and set `needs_recreate=True` with a recovery hint so
        the UI can surface the exact compose command.
        """
        result = {
            "profile": profile, "ok": False, "msg": "",
            "domains": None, "needs_recreate": False,
        }
        if not self.client:
            result["msg"] = "no docker client"
            return result

        proxy_name = f"egress-proxy-{profile}"
        try:
            container = self.client.containers.get(proxy_name)
        except docker.errors.NotFound:
            result["msg"] = f"{proxy_name} not running"
            return result
        except Exception as e:
            result["msg"] = f"docker error: {e}"
            return result

        try:
            ec, output = container.exec_run(["squid", "-k", "reconfigure"])
        except Exception as e:
            result["msg"] = f"exec failed: {e}"
            return result

        if ec != 0:
            result["msg"] = (
                f"squid -k reconfigure exit {ec}: "
                f"{output.decode(errors='replace').strip() or '(no output)'}"
            )
            return result

        # Reconfigure said OK — now confirm squid actually has something
        # to allow. Check both the bind mount and (best-effort) the most
        # recent cache.log lines for the smoking-gun warning.
        domains = self._count_active_domains_in_container(container)
        if domains is None:
            result["needs_recreate"] = True
            result["msg"] = (
                "squid reloaded but the in-container allowlist is "
                "unreadable (stale single-file bind mount — virtiofs "
                "lost the inode binding). Squid is now running with an "
                "EMPTY ACL → every domain 403s. Recreate the proxy "
                "container to re-bind:\n"
                f"  COMPOSE_PROJECT_NAME=macolima-{profile} "
                f"PROFILE={profile} docker compose up -d "
                "--force-recreate egress-proxy"
            )
            return result

        result["ok"] = True
        result["domains"] = domains
        return result

    def reload_all_proxies(self) -> List[Dict]:
        """One reload result dict per running profile (see reload_proxy)."""
        return [self.reload_proxy(p) for p in self.get_running_profiles()]

    def recreate_proxy(self, profile: str) -> Dict:
        """Force-recreate the egress-proxy container for one profile.

        Used as the recovery action when reload_proxy reports
        `needs_recreate` (stale bind mount). We do this via the docker
        SDK rather than shelling out to `docker compose` so the dashboard
        doesn't need the compose CLI on PATH and doesn't have to manage
        COMPOSE_PROJECT_NAME / PROFILE env vars itself.

        Stop + remove + nudge the user toward `compose up` is risky (we'd
        leave the proxy down if the up step fails); instead we shell out
        to `docker compose up -d --force-recreate egress-proxy` with the
        right env. Returns {"profile", "ok", "msg"}.
        """
        result = {"profile": profile, "ok": False, "msg": ""}
        env = os.environ.copy()
        env["COMPOSE_PROJECT_NAME"] = f"macolima-{profile}"
        env["PROFILE"] = profile
        # Repo root is two dirs up from this file (dashboard/src/lib/).
        repo_root = os.path.abspath(
            os.path.join(os.path.dirname(__file__), "..", "..", "..")
        )
        try:
            proc = subprocess.run(
                ["docker", "compose", "up", "-d",
                 "--force-recreate", "egress-proxy"],
                cwd=repo_root, env=env, capture_output=True, text=True,
                timeout=60, check=False,
            )
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError) as e:
            result["msg"] = f"compose invocation failed: {e}"
            return result
        if proc.returncode != 0:
            result["msg"] = (
                f"compose up exit {proc.returncode}: "
                f"{(proc.stderr or proc.stdout).strip()[:400]}"
            )
            return result
        result["ok"] = True
        result["msg"] = "egress-proxy recreated"
        return result
