#!/usr/bin/env python3
"""
Minimal health endpoint for the infra-runner deployer.

GET /health  →  200 {"status":"ok",...}
                503 {"status":"starting"|"unhealthy"|"stale"|"unknown",...}

The deployer writes HEALTH_FILE (JSON with "status" and "epoch") at the end of every
cycle and whenever a deploy step fails. This server reads it on every request. If the
file has not been written for HEALTH_MAX_AGE seconds, the loop is considered wedged and
the response is 503 "stale" even if the last recorded status was "ok".
"""

import http.server
import json
import os
import time

HEALTH_FILE = os.environ.get("HEALTH_FILE", "/tmp/health")
HOST = os.environ.get("HEALTH_HOST", "0.0.0.0")
PORT = int(os.environ.get("HEALTH_PORT", "8080"))
MAX_AGE = int(os.environ.get("HEALTH_MAX_AGE", "900"))


def read_state(now=None):
    """Return (http_code, body) for the current health file."""
    now = time.time() if now is None else now
    try:
        with open(HEALTH_FILE) as f:
            state = json.load(f)
    except FileNotFoundError:
        return 503, {"status": "starting"}
    except (OSError, ValueError):
        return 503, {"status": "unknown"}

    epoch = state.get("epoch")
    if isinstance(epoch, (int, float)) and now - epoch > MAX_AGE:
        stale = dict(state)
        stale["status"] = "stale"
        stale["last_status"] = state.get("status")
        stale["age_s"] = int(now - epoch)
        return 503, stale

    return (200 if state.get("status") == "ok" else 503), state


class HealthHandler(http.server.BaseHTTPRequestHandler):
    timeout = 5  # per-connection socket timeout: a slow client cannot hold a thread forever

    def do_GET(self):
        if self.path != "/health":
            self._send(404, {"status": "not_found"})
            return
        self._send(*read_state())

    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_) -> None:  # type: ignore[override]
        pass  # suppress per-request noise; deployer emits its own structured logs


if __name__ == "__main__":
    server = http.server.ThreadingHTTPServer((HOST, PORT), HealthHandler)
    server.daemon_threads = True
    print(
        json.dumps({"level": "info", "svc": "deployer", "msg": "Health server listening",
                    "port": PORT, "max_age_s": MAX_AGE}),
        flush=True,
    )
    server.serve_forever()
