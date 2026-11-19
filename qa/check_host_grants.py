"""Exercise the #6 public API with two synthetic hosts and one shared database."""

from pathlib import Path
import tempfile
import unittest

from tachi.hosts import AccessDenied, HostStore


class HostGrantChecks(unittest.TestCase):
    def test_scoped_work_across_disconnect_and_revocation(self):
        with tempfile.TemporaryDirectory() as directory:
            db = Path(directory) / "hosts.sqlite"
            admin, worker = HostStore(db), HostStore(db)
            owner, folder, path = "lab-owner", "lab-folder", "counts.csv"
            host_a = worker.pair(admin.issue_pairing(owner))
            host_b = worker.pair(admin.issue_pairing(owner))
            session_a, session_b = worker.connect(host_a), worker.connect(host_b)
            grant_a = admin.grant(owner, host_a.host_id, folder, "read")
            grant_b = admin.grant(owner, host_b.host_id, folder, "read")

            def read(session, grant):
                worker.authorize(owner, session, grant, folder, "read", path)

            read(session_a, grant_a)
            with self.assertRaises(AccessDenied):
                read(session_b, grant_a)
            worker.disconnect(session_a)
            with self.assertRaises(AccessDenied):
                read(session_a, grant_a)
            read(session_b, grant_b)

            session_a = worker.connect(host_a)
            read(session_a, grant_a)
            admin.revoke_grant(owner, host_a.host_id, grant_a)
            with self.assertRaises(AccessDenied):
                read(session_a, grant_a)
            admin.revoke_host(owner, host_b.host_id)
            with self.assertRaises(AccessDenied):
                read(session_b, grant_b)
            with self.assertRaises(AccessDenied):
                worker.connect(host_b)


if __name__ == "__main__":
    unittest.main()
