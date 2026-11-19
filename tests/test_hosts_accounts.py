import os
import sqlite3
import stat
import subprocess
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from pathlib import Path
from threading import Barrier

from tachi.hosts import AccessDenied, AccountStore, HostStore


class AccountTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.path = Path(temp.name) / "coordinator.sqlite"
        self.now = 1000
        self.admin = AccountStore(self.path, clock=lambda: self.now)
        self.worker = AccountStore(self.path, clock=lambda: self.now)

    def pair(self, human, *scopes):
        return self.worker.redeem_client(self.admin.issue_client_invitation(human, scopes))

    def test_identity_persists_across_clients_and_restart(self):
        first = self.pair("alice", "sessions:read")
        second = self.pair("alice", "sessions:read", "messages:send")
        bob = self.pair("bob", "teams:manage")
        reopened = AccountStore(self.path)
        self.assertNotEqual(first.client_id, second.client_id)
        self.assertEqual(reopened.authenticate(first.token).human_id, "alice")
        principal = reopened.authenticate(second.token)
        self.assertEqual((principal.human_id, principal.client_id), ("alice", second.client_id))
        self.assertEqual(principal.scopes, {"sessions:read", "messages:send"})
        self.assertEqual(reopened.authenticate(bob.token).human_id, "bob")
        self.assertEqual(set(reopened.list_clients("alice")), {first.client_id, second.client_id})

    def test_owner_and_scope_checked_at_dispatch_and_revoke(self):
        alice = self.pair("alice", "messages:send")
        other = self.pair("alice", "sessions:read")
        bob = self.pair("bob", "messages:send")
        self.worker.authorize_client("alice", alice.client_id, "messages:send")
        for owner, client, scope in [
            ("bob", alice.client_id, "messages:send"), ("alice", bob.client_id, "messages:send"),
            ("alice", alice.client_id, "teams:manage"), ("alice", alice.client_id, "*"),
        ]:
            with self.assertRaises(AccessDenied):
                self.worker.authorize_client(owner, client, scope)
        with self.assertRaises(AccessDenied):
            self.admin.revoke_client("bob", alice.client_id)
        self.admin.revoke_client("alice", alice.client_id)
        with self.assertRaises(AccessDenied):
            self.worker.authenticate(alice.token)
        with self.assertRaises(AccessDenied):
            self.worker.authorize_client("alice", alice.client_id, "messages:send")
        self.worker.authorize_client("alice", other.client_id, "sessions:read")
        self.worker.authorize_client("bob", bob.client_id, "messages:send")

    def test_concurrent_redemption_has_exactly_one_winner(self):
        invitation = self.admin.issue_client_invitation("alice", ["sessions:read"])
        ready = Barrier(2)

        def redeem(store):
            ready.wait(timeout=5)
            try:
                return store.redeem_client(invitation)
            except AccessDenied:
                return None

        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(redeem, [self.worker, self.admin]))
        self.assertEqual(sum(result is not None for result in results), 1)
        self.assertEqual(len(self.admin.list_clients("alice")), 1)
        with self.assertRaises(AccessDenied):
            self.worker.redeem_client(invitation)

    def test_invalid_or_expired_authority_and_host_separation(self):
        hosts = HostStore(self.path, clock=lambda: self.now)
        host_invite = hosts.issue_pairing("alice")
        invitation = self.admin.issue_client_invitation("alice", ["sessions:read"])
        with self.assertRaises(AccessDenied):
            hosts.pair(invitation)
        with self.assertRaises(AccessDenied):
            self.worker.redeem_client(host_invite)
        host = hosts.pair(host_invite)
        for secret in [host.secret, hosts.connect(host).secret, invitation, "", None]:
            with self.assertRaises(AccessDenied):
                self.worker.authenticate(secret)
        self.now += self.admin.INVITATION_SECONDS
        with self.assertRaises(AccessDenied):
            self.worker.redeem_client(invitation)
        for scopes in [[], ["*"], ["messages:send", "unknown"]]:
            with self.assertRaises(ValueError):
                self.admin.issue_client_invitation("alice", scopes)
        for human in ["", 1, "alice\nbob"]:
            with self.assertRaises(AccessDenied):
                self.admin.issue_client_invitation(human, ["messages:send"])

    def test_cli_creates_private_single_use_file_and_revokes(self):
        destination = self.path.with_name("invitation")
        def cli(command, *args):
            return subprocess.run(
                [sys.executable, "-m", "tachi.hosts", command, "--db", str(self.path),
                 "--human-id", "alice", *args],
                capture_output=True, text=True, env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            )

        def invite():
            return cli("invite-client", "--scope", "messages:send", "--out", str(destination))

        created = invite()
        self.assertEqual((created.returncode, created.stdout, created.stderr), (0, "", ""))
        self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o600)
        invitation = destination.read_text().strip()
        duplicate = invite()
        self.assertNotEqual(duplicate.returncode, 0)
        self.assertNotIn(invitation, duplicate.stdout + duplicate.stderr)
        self.assertEqual(destination.read_text().strip(), invitation)
        with closing(sqlite3.connect(self.path)) as db:
            self.assertNotIn(invitation, "\n".join(db.iterdump()))
        credential = self.worker.redeem_client(invitation)
        self.assertNotIn(credential.token, repr(credential))
        with closing(sqlite3.connect(self.path)) as db:
            self.assertNotIn(credential.token, "\n".join(db.iterdump()))
        listed = cli("list-clients")
        self.assertEqual((listed.returncode, listed.stdout.strip()), (0, credential.client_id))
        revoked = cli("revoke-client", "--client-id", credential.client_id)
        self.assertEqual((revoked.returncode, revoked.stdout, revoked.stderr), (0, "", ""))
        with self.assertRaises(AccessDenied):
            self.worker.authenticate(credential.token)
