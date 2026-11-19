import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier

from tachi.hosts import AccessDenied, AccountStore


class TeamMembershipTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.path = Path(tmp.name) / "coordinator.sqlite"
        self.now = 1000
        self.accounts = AccountStore(self.path, clock=lambda: self.now)
        self.worker = AccountStore(self.path, clock=lambda: self.now)
        self.a = self.client("alice", "teams:manage", "messages:send", "sessions:read")
        self.b = self.client("bob", "teams:manage", "messages:send", "sessions:read")
        self.c = self.client("carol", "sessions:read")
        self.accounts.create_team("alice", self.a, "north")
        self.accounts.create_team("bob", self.b, "south")

    def client(self, human, *scopes):
        invitation = self.accounts.issue_client_invitation(human, scopes)
        return self.accounts.redeem_client(invitation).client_id

    def invite(self, human="bob"):
        return self.accounts.invite_member("alice", self.a, "north", human)

    def join(self):
        return self.worker.accept_invitation("bob", self.b, self.invite())

    def test_recipient_bound_membership_and_distinct_team_roles(self):
        self.assertEqual(self.accounts.team_role("north", "alice"), "owner")
        invitation = self.invite()
        self.assertIsNone(self.worker.team_membership("north", "bob"))
        for human, client in [("carol", self.c), ("bob", self.c), ("alice", self.a)]:
            with self.assertRaises(AccessDenied):
                self.worker.accept_invitation(human, client, invitation)
        member = self.worker.accept_invitation("bob", self.b, invitation)
        self.assertEqual(self.accounts.team_membership("north", "bob"), member)
        self.assertEqual(self.accounts.authorize_team("bob", self.b, "north", "messages:send"), "member")
        self.assertEqual(self.accounts.authorize_team("bob", self.b, "south", "teams:manage"), "owner")
        with self.assertRaises(AccessDenied):
            self.worker.accept_invitation("bob", self.b, invitation)
        for action, args in [
            (self.accounts.authorize_team, ("bob", self.b, "north", "teams:manage")),
            (self.accounts.authorize_team, ("alice", self.a, "south", "sessions:read")),
            (self.accounts.authorize_team, ("alice", self.b, "north", "sessions:read")),
            (self.accounts.invite_member, ("bob", self.b, "north", "carol")),
            (self.accounts.revoke_member, ("bob", self.b, "north", "alice")),
            (self.accounts.revoke_member, ("alice", self.a, "north", "alice")),
            (self.accounts.create_team, ("bob", self.b, "north")),
            (self.accounts.create_team, ("carol", self.c, "third")),
        ]:
            with self.subTest(action=action.__name__), self.assertRaises(AccessDenied):
                action(*args)
        self.assertIsNone(self.worker.team_role("third", "carol"))

    def test_rejoin_cannot_restore_queued_authority_or_old_dm_audience(self):
        membership = self.join()
        original = self.worker.authorize_membership("bob", self.b, "north", "messages:send")
        self.assertEqual(original, membership)
        self.accounts.revoke_member("alice", self.a, "north", "bob")
        self.assertIsNone(self.worker.team_membership("north", "bob"))
        with self.assertRaises(AccessDenied):
            self.worker.authorize_team("bob", self.b, "north", "messages:send")
        current = self.join()
        self.assertNotEqual(current.membership_id, original.membership_id)
        with self.assertRaises(AccessDenied):
            self.worker.authorize_membership("bob", self.b, "north", "messages:send",
                                             membership_id=original.membership_id)
        self.assertEqual(self.worker.authorize_membership("bob", self.b, "north", "messages:send",
                                                          membership_id=current.membership_id), current)
        self.assertEqual(self.worker.team_role("south", "bob"), "owner")

    def test_read_only_client_and_issuer_revocation(self):
        self.worker.accept_invitation("carol", self.c, self.invite("carol"))
        self.assertEqual(self.worker.authorize_team("carol", self.c, "north", "sessions:read"), "member")
        with self.assertRaises(AccessDenied):
            self.worker.authorize_team("carol", self.c, "north", "messages:send")
        other = self.client("alice", "sessions:read")
        with self.assertRaises(AccessDenied):
            self.accounts.invite_member("alice", other, "north", "bob")
        invitation = self.invite()
        self.accounts.revoke_client("alice", self.a)
        with self.assertRaises(AccessDenied):
            self.worker.accept_invitation("bob", self.b, invitation)
        self.assertEqual(self.worker.authorize_team("alice", other, "north", "sessions:read"), "owner")
        self.assertEqual(self.worker.team_role("north", "carol"), "member")
        self.accounts.revoke_client("carol", self.c)
        with self.assertRaises(AccessDenied):
            self.worker.authorize_team("carol", self.c, "north", "sessions:read")

    def test_withdrawn_replaced_expired_and_wrong_kind_invitations(self):
        first = self.invite()
        second = self.invite()
        with self.assertRaises(AccessDenied):
            self.worker.redeem_client(second)
        with self.assertRaises(AccessDenied):
            self.worker.accept_invitation("bob", self.b, first)
        self.accounts.revoke_member("alice", self.a, "north", "bob")
        with self.assertRaises(AccessDenied):
            self.worker.accept_invitation("bob", self.b, second)
        third = self.invite()
        self.now += self.accounts.INVITATION_SECONDS
        with self.assertRaises(AccessDenied):
            self.worker.accept_invitation("bob", self.b, third)
        self.assertIsNone(self.worker.team_role("north", "bob"))

    def test_revoke_racing_accept_leaves_no_authority(self):
        invitation = self.invite()
        ready = Barrier(2)

        def accept():
            ready.wait(timeout=5)
            try:
                self.worker.accept_invitation("bob", self.b, invitation)
            except AccessDenied:
                pass  # The revoke transaction committed first.

        with ThreadPoolExecutor(max_workers=1) as pool:
            accepted = pool.submit(accept)
            ready.wait(timeout=5)
            self.accounts.revoke_member("alice", self.a, "north", "bob")
            accepted.result()
        self.assertIsNone(self.worker.team_role("north", "bob"))
        with self.assertRaises(AccessDenied):
            self.worker.accept_invitation("bob", self.b, invitation)
