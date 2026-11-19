"""Exercise HTTP pairing and selective revocation against a disposable coordinator."""

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


class ClientPairingCheck(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        self.database = self.directory / "coordinator.sqlite"
        server = subprocess.Popen(
            [sys.executable, "-m", "tachi", "--db", self.database, "--port", "0"],
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

    def request(self, method, path, status, *, invitation=None, token=None):
        headers = {"Accept": "application/json"}
        body = None
        if invitation is not None:
            headers["Content-Type"] = "application/json"
            body = json.dumps({"invitation": invitation}).encode()
        if token is not None:
            headers["Authorization"] = "Bearer " + token
        with closing(http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)) as connection:
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            self.assertEqual(response.status, status, f"{method} {path}")
            self.assertEqual(response.headers.get_content_type(), "application/json")
            self.assertEqual(response.getheader("Cache-Control"), "no-store")
            return json.loads(response.read())

    def test_replay_and_selective_revocation(self):
        clients = []
        for label, human, scope in (("first", "synthetic-a", "sessions:read"),
                                    ("sibling", "synthetic-a", "messages:send"),
                                    ("other", "synthetic-b", "sessions:read")):
            path = self.directory / label
            self.operator("invite-client", human, "--scope", scope, "--out", path)
            invitation = path.read_text().strip()
            credential = self.request("POST", "/v1/client/pair", 201, invitation=invitation)
            self.assertTrue(set(credential) == {"clientID", "token"}, "unexpected credential fields")
            self.assertTrue(all(isinstance(v, str) and v for v in credential.values()), "invalid credential")
            principal = {"clientID": credential["clientID"], "humanID": human, "scopes": [scope]}
            clients.append((credential["token"], principal))
            if label == "first":
                replay = self.request("POST", "/v1/client/pair", 401, invitation=invitation)
                self.assertTrue(replay == {"error": "unauthorized"}, "unexpected replay response")

        self.assertEqual(len({principal["clientID"] for _, principal in clients}), 3)
        for token, principal in clients:
            me = self.request("GET", "/v1/client/me", 200, token=token)
            self.assertTrue(me == principal, "incorrect client identity or scopes before revocation")

        revoked_token, revoked = clients[0]
        self.operator("revoke-client", revoked["humanID"], "--client-id", revoked["clientID"])
        denied = self.request("GET", "/v1/client/me", 401, token=revoked_token)
        self.assertTrue(denied == {"error": "unauthorized"}, "unexpected revocation response")
        for token, principal in clients[1:]:
            me = self.request("GET", "/v1/client/me", 200, token=token)
            self.assertTrue(me == principal, "unaffected client lost its original binding")


if __name__ == "__main__":
    unittest.main()
