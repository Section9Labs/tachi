import sqlite3
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from pathlib import Path
from threading import Barrier

from tachi.hosts import AccessDenied, HostCredential, HostSession, HostStore


class HostStoreTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.path = Path(tmp.name) / "coordinator.sqlite"
        self.now = 1000
        self.owner = HostStore(self.path, clock=lambda: self.now)
        self.worker = HostStore(self.path, clock=lambda: self.now)
        self.alpha = self.worker.pair(self.owner.issue_pairing("alice"))
        self.beta = self.worker.pair(self.owner.issue_pairing("bob"))
        self.session = self.worker.connect(self.alpha)
        self.other = self.worker.connect(self.beta)
        self.grant = self.owner.grant("alice", self.alpha.host_id, "books", "read")
        self.other_grant = self.owner.grant("bob", self.beta.host_id, "books", "read")

    def check(self, session=None):
        self.worker.authorize("alice", session or self.session, self.grant,
                              "books", "read", "fiction/title.txt")

    def check_other(self):
        self.worker.authorize("bob", self.other, self.other_grant, "books", "read", "title.txt")

    def test_scope_is_per_owner_host_folder_and_operation(self):
        self.check()
        self.check_other()
        same_owner = self.worker.pair(self.owner.issue_pairing("alice"))
        same_owner_session = self.worker.connect(same_owner)
        for owner, session, grant, folder, action in [
            ("bob", self.session, self.grant, "books", "read"),
            ("alice", same_owner_session, self.grant, "books", "read"),
            ("alice", self.session, self.other_grant, "books", "read"),
            ("alice", self.session, self.grant, "books-old", "read"),
            ("alice", self.session, self.grant, "books", "write"),
            ("alice", self.other, self.grant, "books", "read"),
        ]:
            with self.subTest(owner=owner, host=session.host_id, folder=folder, action=action):
                with self.assertRaises(AccessDenied):
                    self.worker.authorize(owner, session, grant, folder, action, "file")
        for op, args in [
            (self.owner.grant, ("bob", self.alpha.host_id, "books", "write")),
            (self.owner.revoke_host, ("bob", self.alpha.host_id)),
            (self.owner.revoke_grant, ("bob", self.alpha.host_id, self.grant)),
            (self.owner.revoke_grant, ("bob", self.beta.host_id, self.grant)),
        ]:
            with self.subTest(op=op.__name__), self.assertRaises(AccessDenied):
                op(*args)
        self.check()
        self.check_other()

    def test_revoke_between_queue_and_execution(self):
        self.check()
        write = self.owner.grant("alice", self.alpha.host_id, "books", "write")
        self.owner.revoke_grant("alice", self.alpha.host_id, self.grant)
        with self.assertRaises(AccessDenied):
            self.check()
        self.worker.authorize("alice", self.session, write, "books", "write", "new.txt")
        self.check_other()

    def test_revoke_device_even_after_restart(self):
        self.owner.revoke_host("alice", self.alpha.host_id)
        self.worker = HostStore(self.path, clock=lambda: self.now)
        for op, args in [
            (self.check, ()),
            (self.worker.heartbeat, (self.session,)),
            (self.worker.connect, (self.alpha,)),
            (self.owner.grant, ("alice", self.alpha.host_id, "books", "write")),
        ]:
            with self.subTest(op=op.__name__), self.assertRaises(AccessDenied):
                op(*args)
        new_device = self.worker.pair(self.owner.issue_pairing("alice"))
        with self.assertRaises(AccessDenied):
            self.check(self.worker.connect(new_device))
        self.check_other()

    def test_connection_loss_and_replacement(self):
        self.worker.disconnect(self.session)
        with self.assertRaises(AccessDenied):
            self.check()
        self.check_other()
        first = self.worker.connect(self.alpha)
        second = self.worker.connect(self.alpha)
        for op in [self.worker.disconnect, self.worker.heartbeat, self.check]:
            with self.subTest(op=op.__name__), self.assertRaises(AccessDenied):
                op(first)
        self.check(second)

    def test_silent_loss_expires_at_lease_boundary(self):
        self.now += HostStore.LEASE_SECONDS - 1
        self.worker.heartbeat(self.session)
        self.now += 1
        self.check()
        with self.assertRaises(AccessDenied):
            self.check_other()
        self.now += HostStore.LEASE_SECONDS - 1
        with self.assertRaises(AccessDenied):
            self.check()
        with self.assertRaises(AccessDenied):
            self.worker.heartbeat(self.session)
        self.check(self.worker.connect(self.alpha))

    def test_one_time_pairing_under_contention(self):
        invitation = self.owner.issue_pairing("alice")
        ready = Barrier(2)

        def redeem(store):
            ready.wait(timeout=5)
            try:
                return store.pair(invitation)
            except AccessDenied:
                return None

        with ThreadPoolExecutor(max_workers=2) as pool:
            devices = list(pool.map(redeem, (self.owner, self.worker)))
        self.assertEqual(sum(device is not None for device in devices), 1)
        with self.assertRaises(AccessDenied):
            self.worker.pair(invitation)

    def test_expired_pairing_and_wrong_secrets(self):
        invitation = self.owner.issue_pairing("alice")
        self.now += HostStore.PAIRING_SECONDS
        with self.assertRaises(AccessDenied):
            self.worker.pair(invitation)
        for secret in [self.beta.secret, self.session.secret, invitation, ""]:
            with self.assertRaises(AccessDenied):
                self.worker.connect(HostCredential(self.alpha.host_id, secret))
        self.session = self.worker.connect(self.alpha)
        for secret in [self.alpha.secret, self.other.secret, invitation, ""]:
            with self.assertRaises(AccessDenied):
                self.check(HostSession(self.alpha.host_id, secret))

    def test_scope_inputs_fail_closed(self):
        for path in ["", ".", "..", "books/../outside", "/tmp/file", "a//b", "a/./b",
                     "folder/", "a\\b", "C:foo", "foo\x00bar", None]:
            with self.subTest(path=path), self.assertRaises(AccessDenied):
                self.worker.authorize("alice", self.session, self.grant, "books", "read", path)
        for folder, action in [("", "read"), (".", "read"), ("/root", "read"),
                               ("books", "execute"), ("books", "*")]:
            with self.assertRaises(AccessDenied):
                self.owner.grant("alice", self.alpha.host_id, folder, action)
        numeric_owner = self.worker.pair(self.owner.issue_pairing("1"))
        with self.assertRaises(AccessDenied):
            self.owner.revoke_host(1, numeric_owner.host_id)

    def test_bearer_secrets_are_not_stored_verbatim(self):
        invitation = self.owner.issue_pairing("alice")
        with closing(sqlite3.connect(self.path)) as db:
            snapshot = "\n".join(db.iterdump())
        for secret in [invitation, self.alpha.secret, self.session.secret]:
            self.assertNotIn(secret, snapshot)
        self.assertNotIn(self.session.secret, repr(self.session))
        self.assertNotIn(self.alpha.secret, repr(self.alpha))
