#!/usr/bin/env python3
"""
Minimal health endpoint for the infra-runner deployer.

GET /health  →  200 {"status":"ok",...}   or  503 {"status":"unhealthy",...}

The deployer shell script writes /tmp/health (a JSON file) to record the
current health state. This server reads that file on every request so the
response always reflects the latest state without restarting the server.
"""

import http.server
import json
import os

HEALTH_FILE = os.environ.get("HEALTH_FILE", "/tmp/health")
HOST = os.environ.get("HEALTH_HOST", "0.0.0.0")
PORT = int(os.environ.get("HEALTH_PORT", "8080"))


class HealthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/health":
            self._send(404, {"status": "not_found"})
            return

        try:
            with open(HEALTH_FILE) as f:
                state = json.load(f)
        except FileNotFoundError:
            # Deployer is still starting up
            state = {"status": "starting"}
        except Exception:
            state = {"status": "unknown"}

        code = 200 if state.get("status") == "ok" else 503
        self._send(code, state)

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
    server = http.server.HTTPServer((HOST, PORT), HealthHandler)
    print(
        f'{{"ts":null,"level":"info","svc":"deployer","msg":"Health server listening","port":{PORT}}}',
        flush=True,
    )
    server.serve_forever()
