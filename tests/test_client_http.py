import json
import tempfile
import unittest
from functools import partial
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
from pathlib import Path
from threading import Thread

from tachi.hosts import AccountStore
from tachi.http import CoordinatorHandler


class ClientHTTPTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.accounts = AccountStore(Path(directory.name) / "accounts.sqlite")
        handler = partial(CoordinatorHandler, accounts=self.accounts)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.addCleanup(self.server.server_close)
        thread = Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.02})
        thread.start()
        self.addCleanup(thread.join)
        self.addCleanup(self.server.shutdown)

    def request(self, method, path, body=None, headers=None):
        client = HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        try:
            client.request(method, path, body, headers or {})
            response = client.getresponse()
            self.assertEqual(response.getheader("Cache-Control"), "no-store")
            return response.status, json.load(response)
        finally:
            client.close()

    def test_redemption_identity_and_revocation(self):
        invitation = self.accounts.issue_client_invitation("human-a", ["sessions:read"])
        form = json.dumps({"invitation": invitation})
        headers = {"Content-Type": "application/json"}
        code, result = self.request("POST", "/v1/client/pair", form, headers)
        self.assertEqual(code, 201)
        self.assertEqual(set(result), {"token", "clientID"})
        self.assertEqual(self.request("POST", "/v1/client/pair", form, headers)[0], 401)
        auth = {"Authorization": "Bearer " + result["token"]}
        self.assertEqual(self.request("GET", "/v1/client/me", headers=auth), (200, {
            "humanID": "human-a", "clientID": result["clientID"], "scopes": ["sessions:read"],
        }))
        self.accounts.revoke_client("human-a", result["clientID"])
        self.assertEqual(self.request("GET", "/v1/client/me", headers=auth)[0], 401)

    def test_rejects_unbound_identity_and_invalid_requests(self):
        self.assertEqual(self.request("GET", "/v1/client/me")[0], 401)
        for body in ('[]', '{"invitation":5}', '{"humanID":"chosen","invitation":"bad"}', 'x' * 2049):
            with self.subTest(size=len(body)):
                self.assertEqual(self.request("POST", "/v1/client/pair", body,
                                              {"Content-Type": "application/json"})[0], 400)
        self.assertEqual(self.request("POST", "/v1/client/pair", "{}")[0], 415)
