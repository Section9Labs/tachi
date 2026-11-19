"""Isolated loopback coordinator and operator CLI for independent HTTP checks."""

from contextlib import closing, contextmanager
import http.client
import json
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import urlsplit


PYTHON_SERVICE = (sys.executable, "-m", "tachi")
PYTHON_OPERATOR = (sys.executable, "-m", "tachi.hosts")


class CoordinatorLab(unittest.TestCase):
    service_command = PYTHON_SERVICE
    operator_command = PYTHON_OPERATOR
    service_root = None

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        self.database = self.directory / "coordinator.sqlite"

    @contextmanager
    def serve(self, command, *options, cwd=None):
        with subprocess.Popen([*command, "--port", "0", *options], cwd=cwd,
                              stdout=subprocess.PIPE, text=True) as server:
            try:
                self.assertTrue(select.select([server.stdout], [], [], 10)[0], "coordinator startup timed out")
                prefix = "Tachi listening on "
                announcement = server.stdout.readline().strip()
                self.assertTrue(announcement.startswith(prefix), "missing coordinator origin")
                origin = urlsplit(announcement[len(prefix):])
                self.assertEqual((origin.scheme, origin.hostname), ("http", "127.0.0.1"))
                self.port = origin.port
                self.assertIsNotNone(self.port)
                yield
            finally:
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()

    def operator(self, command, human, *arguments):
        subprocess.run([*self.operator_command, command, "--db", self.database,
                        "--human-id", human, *arguments], cwd=self.service_root, check=True, timeout=10)

    def pair(self, human, label, *scopes):
        file = self.directory / label
        scope_args = [arg for scope in scopes for arg in ("--scope", scope)]
        self.operator("invite-client", human, *scope_args, "--out", file)
        response = self.request("POST", "/v1/client/pair", 201,
                                payload={"invitation": file.read_text().strip()})
        return response["token"]

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


class DisposableCoordinator(CoordinatorLab):
    server_options = ()

    def setUp(self):
        super().setUp()
        self.enterContext(self.serve(self.service_command, "--db", self.database, *self.server_options,
                                     cwd=self.service_root))
