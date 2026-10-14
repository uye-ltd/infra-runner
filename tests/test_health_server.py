"""Unit tests for deployer/health_server.py (stdlib unittest, no dependencies)."""

import importlib
import json
import os
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "deployer"))


class ReadStateTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.file = os.path.join(self.dir.name, "health")
        os.environ["HEALTH_FILE"] = self.file
        os.environ["HEALTH_MAX_AGE"] = "100"
        import health_server
        self.hs = importlib.reload(health_server)

    def tearDown(self):
        self.dir.cleanup()

    def write(self, obj):
        with open(self.file, "w") as f:
            f.write(obj if isinstance(obj, str) else json.dumps(obj))

    def test_missing_file_is_starting(self):
        self.assertEqual(self.hs.read_state(), (503, {"status": "starting"}))

    def test_fresh_ok_is_200(self):
        self.write({"status": "ok", "epoch": time.time()})
        self.assertEqual(self.hs.read_state()[0], 200)

    def test_unhealthy_is_503(self):
        self.write({"status": "unhealthy", "reason": "x", "epoch": time.time()})
        code, body = self.hs.read_state()
        self.assertEqual(code, 503)
        self.assertEqual(body["reason"], "x")

    def test_stale_ok_is_503_stale(self):
        self.write({"status": "ok", "epoch": time.time() - 500})
        code, body = self.hs.read_state()
        self.assertEqual(code, 503)
        self.assertEqual(body["status"], "stale")
        self.assertEqual(body["last_status"], "ok")

    def test_garbage_is_503_unknown(self):
        self.write("{garbage")
        self.assertEqual(self.hs.read_state(), (503, {"status": "unknown"}))


if __name__ == "__main__":
    unittest.main()
