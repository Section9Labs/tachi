"""Exercise HTTP pairing and selective revocation against a disposable coordinator."""

from pathlib import Path
import subprocess
import sys
import unittest

from http_lab import DisposableCoordinator


class ClientPairingCheck(DisposableCoordinator):
    def test_bootstrap_probe(self):
        probe = Path(__file__).with_name("probe_status.py")
        subprocess.run([sys.executable, probe, "--port", str(self.port)], check=True, timeout=10)

    def test_replay_and_selective_revocation(self):
        clients = []
        for label, human, scope in (("first", "synthetic-a", "sessions:read"),
                                    ("sibling", "synthetic-a", "messages:send"),
                                    ("other", "synthetic-b", "sessions:read")):
            path = self.directory / label
            self.operator("invite-client", human, "--scope", scope, "--out", path)
            invitation = path.read_text().strip()
            credential = self.request("POST", "/v1/client/pair", 201, payload={"invitation": invitation})
            self.assertTrue(set(credential) == {"clientID", "token"}, "unexpected credential fields")
            self.assertTrue(all(isinstance(v, str) and v for v in credential.values()), "invalid credential")
            principal = {"clientID": credential["clientID"], "humanID": human, "scopes": [scope]}
            clients.append((credential["token"], principal))
            if label == "first":
                replay = self.request("POST", "/v1/client/pair", 401, payload={"invitation": invitation})
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
