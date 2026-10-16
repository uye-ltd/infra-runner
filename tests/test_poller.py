"""Poller has no Docker API or command channel; these tests cover its read-only cycle."""
import importlib
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "deployer"))


class PollerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.targets = Path(self.tmp.name) / "targets.json"
        self.health = Path(self.tmp.name) / "health.json"
        self.targets.write_text(json.dumps({"targets": [{"repo": "ghcr.io/uye-ltd/infra-edge", "identity": "https://github.com/uye-ltd/infra-edge/.github/workflows/ci.yml@refs/heads/main"}]}))
        os.environ["TARGETS_FILE"] = str(self.targets)
        os.environ["HEALTH_FILE"] = str(self.health)
        import poller
        self.poller = importlib.reload(poller)

    def test_verified_digest_and_no_docker_invocation(self):
        digest = "sha256:" + "a" * 64
        payload = [{"critical": {"image": {"docker-manifest-digest": digest}}}]
        with patch.object(self.poller.subprocess, "run") as command:
            command.return_value.returncode = 0
            command.return_value.stdout = json.dumps(payload)
            self.poller.cycle()
        argv = command.call_args.args[0]
        self.assertEqual(argv[0:2], ["cosign", "verify"])
        self.assertEqual(argv[-1], "ghcr.io/uye-ltd/infra-edge:latest")
        self.assertNotIn("DOCKER_HOST", command.call_args.kwargs["env"])
        self.assertEqual(json.loads(self.health.read_text())["releases"]["ghcr.io/uye-ltd/infra-edge"], digest)

    def test_failed_signature_is_unhealthy(self):
        with patch.object(self.poller.subprocess, "run") as command:
            command.return_value.returncode = 1
            self.poller.cycle()
        self.assertEqual(json.loads(self.health.read_text())["status"], "unhealthy")

    def test_ambiguous_signature_is_unhealthy(self):
        payload = [{"critical": {"image": {"docker-manifest-digest": "sha256:" + digit * 64}}} for digit in ("a", "b")]
        with patch.object(self.poller.subprocess, "run") as command:
            command.return_value.returncode = 0
            command.return_value.stdout = json.dumps(payload)
            self.poller.cycle()
        self.assertEqual(json.loads(self.health.read_text())["status"], "unhealthy")


if __name__ == "__main__":
    unittest.main()
