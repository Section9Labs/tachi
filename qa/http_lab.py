"""Isolated loopback coordinator and operator CLI for independent HTTP checks."""

from contextlib import closing
import http.client
import json
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import urlsplit


class DisposableCoordinator(unittest.TestCase):
    server_options = ()

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        self.database = self.directory / "coordinator.sqlite"
        server = subprocess.Popen(
            [sys.executable, "-m", "tachi", "--db", self.database, "--port", "0", *self.server_options],
            stdout=subprocess.PIPE, text=True,
        )
        self.addCleanup(server.stdout.close)
        self.addCleanup(server.wait, 5)
        self.addCleanup(server.terminate)
        self.assertTrue(select.select([server.stdout], [], [], 10)[0], "coordinator startup timed out")
        prefix = "Tachi listening on "
        announcement = server.stdout.readline().strip()
        self.assertTrue(announcement.startswith(prefix), "missing coordinator origin")
        origin = urlsplit(announcement[len(prefix):])
        self.assertEqual((origin.scheme, origin.hostname), ("http", "127.0.0.1"))
        self.port = origin.port
        self.assertIsNotNone(self.port)

    def operator(self, command, human, *arguments):
        subprocess.run([sys.executable, "-m", "tachi.hosts", command, "--db", self.database,
                        "--human-id", human, *arguments], check=True, timeout=10)

    def request(self, method, path, status, *, payload=None, token=None):
        headers = {"Accept": "application/json"}
        body = None
        if payload is not None:
            headers["Content-Type"] = "application/json"
            body = json.dumps(payload).encode()
        if token is not None:
            headers["Authorization"] = "Bearer " + token
        with closing(http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)) as connection:
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            self.assertEqual(response.status, status, f"{method} {path}")
            self.assertEqual(response.headers.get_content_type(), "application/json")
            self.assertEqual(response.getheader("Cache-Control"), "no-store")
            return json.loads(response.read())
