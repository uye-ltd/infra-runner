#!/usr/bin/env python3
"""Signature observer with no Docker access or executor command channel."""
import json
import os
import subprocess
import threading
import time
from http.server import ThreadingHTTPServer
from pathlib import Path

from health_server import HealthHandler, HOST, PORT

TARGETS = Path(os.environ.get("TARGETS_FILE", "/etc/uye-poller/targets.json"))
HEALTH = Path(os.environ.get("HEALTH_FILE", "/tmp/health"))
INTERVAL = int(os.environ.get("POLL_INTERVAL", "60"))
ISSUER = "https://token.actions.githubusercontent.com"


def verify(target):
    result = subprocess.run(
        ["cosign", "verify", "--certificate-identity", target["identity"],
         "--certificate-oidc-issuer", ISSUER, target["repo"] + ":latest"],
        text=True, capture_output=True, timeout=90,
        env={"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": "/tmp"},
    )
    if result.returncode:
        raise ValueError("signature verification failed")
    signatures = json.loads(result.stdout)
    digests = {entry["critical"]["image"]["docker-manifest-digest"] for entry in signatures}
    if len(digests) != 1:
        raise ValueError("ambiguous signature digest")
    value = digests.pop()
    if not value.startswith("sha256:") or len(value) != 71:
        raise ValueError("invalid signature digest")
    return value


def cycle():
    targets = json.loads(TARGETS.read_text(encoding="utf-8"))["targets"]
    releases, errors = {}, {}
    for target in targets:
        name = target["repo"]
        try:
            releases[name] = verify(target)
        except (ValueError, KeyError, OSError, subprocess.TimeoutExpired) as exc:
            errors[name] = str(exc)
    state = {
        "status": "unhealthy" if errors else "ok",
        "epoch": time.time(),
        "releases": releases,
        "errors": errors,
    }
    temporary = HEALTH.with_suffix(".new")
    temporary.write_text(json.dumps(state, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(HEALTH)
    print(json.dumps({"svc": "poller", "status": state["status"], "errors": errors}), flush=True)


def main():
    if INTERVAL < 5 or INTERVAL > 3600:
        raise ValueError("invalid poll interval")
    server = ThreadingHTTPServer((HOST, PORT), HealthHandler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    while True:
        try:
            cycle()
        except (ValueError, KeyError, OSError) as exc:
            HEALTH.write_text(json.dumps({"status": "unhealthy", "epoch": time.time(), "reason": str(exc)}) + "\n", encoding="utf-8")
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
