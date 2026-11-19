import json
import os
import subprocess
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack, closing
from dataclasses import replace
from pathlib import Path
from threading import Barrier

from tachi.hosts import AccessDenied, AccountStore, HostStore
from tachi.hosts.local_folder import FolderExecutor
from tachi.runtime import AdapterIdentity, AdapterRegistry
from tachi.runtime.queue import HostScope, TeamQueue
from tachi.runtime.reference import ReferenceAdapter


@unittest.skipUnless(sys.platform == "darwin", "native Mac folder executor")
class LocalFolderTests(unittest.TestCase):
    def setUp(self):
        self.resources = ExitStack()
        self.addCleanup(self.resources.close)
        directory = Path(self.resources.enter_context(tempfile.TemporaryDirectory())).resolve()
        self.root = directory / "selection"
        self.root.mkdir()
        self.outside = directory / "other"
        self.outside.mkdir()
        self.store = HostStore(directory / "policy.sqlite")
        self.host = self.store.pair(self.store.issue_pairing("owner"))
        self.session = self.store.connect(self.host)
        self.checks = 0
        self.during_check = lambda count: None

        def check(*args):
            self.checks += 1
            self.during_check(self.checks)
            self.store.authorize(*args)

        self.executor = self.resources.enter_context(FolderExecutor(self.root, self.host.host_id, check))
        folder = self.executor.folder_id

        def scope(action):
            grant = self.store.grant("owner", self.host.host_id, folder, action)
            return HostScope("owner", self.host.host_id, grant, folder, action, "brief")

        self.read = scope("read")
        self.write = scope("write")

    def test_read_and_exclusive_create(self):
        body = bytes(range(256)) * 4096
        self.executor.execute(self.write, self.session, body=body)
        self.assertEqual(self.executor.execute(self.read, self.session), body)
        with self.assertRaises(FileExistsError):
            self.executor.execute(self.write, self.session, body=b"replacement")
        self.assertEqual((self.root / "brief").read_bytes(), body)
        (self.root / "brief").write_bytes(body + b"x")
        with self.assertRaises(ValueError):
            self.executor.execute(self.read, self.session)
        with self.assertRaises(ValueError):
            self.executor.execute(replace(self.write, relative_path="too-large"), self.session, body=body + b"x")
        self.assertFalse((self.root / "too-large").exists())

    def test_exact_scope_and_lease(self):
        for scope in (replace(self.write, owner_id="other"), replace(self.write, host_id="other"),
                      replace(self.write, folder_id="other"), replace(self.write, grant_id=self.read.grant_id)):
            with self.assertRaises(AccessDenied):
                self.executor.execute(scope, self.session, body=b"x")
        self.store.disconnect(self.session)
        with self.assertRaises(AccessDenied):
            self.executor.execute(self.write, self.session, body=b"x")
        self.assertFalse((self.root / "brief").exists())
        self.session = self.store.connect(self.host)
        self.executor.execute(self.write, self.session, body=b"once")
        self.store.revoke_host("owner", self.host.host_id)
        with self.assertRaises(AccessDenied):
            self.executor.execute(self.read, self.session)

    def test_revoke_during_staging_and_before_read_release(self):
        def revoke(count):
            if count == 2:
                self.store.revoke_grant("owner", self.host.host_id, self.write.grant_id)
        self.during_check = revoke
        with self.assertRaises(AccessDenied):
            self.executor.execute(self.write, self.session, body=b"x")
        self.assertFalse((self.root / "brief").exists())

        (self.root / "brief").write_bytes(b"original")
        self.checks = 0
        def revoke_read(count):
            if count == 4:
                self.store.revoke_grant("owner", self.host.host_id, self.read.grant_id)
        self.during_check = revoke_read
        with self.assertRaises(AccessDenied):
            self.executor.execute(self.read, self.session)

    def test_symlink_hardlink_and_special_file(self):
        source = self.outside / "source"
        source.write_bytes(b"outside")
        dest = self.root / "brief"
        for create in (lambda: dest.symlink_to(source), lambda: os.link(source, dest),
                       lambda: os.mkfifo(dest)):
            create()
            with self.assertRaises(AccessDenied):
                self.executor.execute(self.read, self.session)
            with self.assertRaises(FileExistsError):
                self.executor.execute(self.write, self.session, body=b"new")
            dest.unlink()
        self.assertEqual(source.read_bytes(), b"outside")

    def test_selection_is_pinned_and_each_selection_gets_a_fresh_handle(self):
        moved = self.outside / "moved-selection"
        self.root.rename(moved)
        self.root.symlink_to(self.outside, target_is_directory=True)
        self.executor.execute(self.write, self.session, body=b"pinned")
        self.assertEqual((moved / "brief").read_bytes(), b"pinned")
        self.assertFalse((self.outside / "brief").exists())
        with self.assertRaises(OSError):
            with FolderExecutor(self.root, self.host.host_id, self.store.authorize):
                self.fail("followed a symlink during selection")
        with FolderExecutor(moved, self.host.host_id, self.store.authorize) as new:
            with self.assertRaises(AccessDenied):
                new.execute(self.read, self.session)

    def test_move_open_file_outside_and_replace_before_release(self):
        # First replace just before reading, then replace after buffering the bytes.
        for checkpoint in (3, 4):
            with self.subTest(checkpoint=checkpoint):
                self.checks = 0
                original = self.root / "brief"
                original.write_bytes(b"selected")
                barrier = Barrier(2, timeout=5)

                def pause(count):
                    if count == checkpoint:
                        barrier.wait()
                        barrier.wait()

                self.during_check = pause
                with ThreadPoolExecutor(max_workers=1) as pool:
                    reading = pool.submit(self.executor.execute, self.read, self.session)
                    barrier.wait()
                    original.rename(self.outside / "moved")
                    (self.outside / "moved").write_bytes(b"now outside")
                    original.write_bytes(b"new inode")
                    barrier.wait()
                    with self.assertRaises(AccessDenied):
                        reading.result()

    def test_nested_requests_denied_while_intermediate_moves(self):
        inner = self.root / "inner"
        inner.mkdir()
        barrier = Barrier(2, timeout=5)
        def move():
            barrier.wait()
            inner.rename(self.outside / "moved")
            inner.symlink_to(self.outside, target_is_directory=True)
        with ThreadPoolExecutor(max_workers=1) as pool:
            moving = pool.submit(move)
            barrier.wait()
            for path in ("inner/file", "../file", "/file"):
                with self.assertRaisesRegex(AccessDenied, "only direct children"):
                    self.executor.execute(replace(self.write, relative_path=path), self.session, body=b"x")
            moving.result()
        self.assertFalse((self.outside / "file").exists())
        self.assertFalse((self.outside / "moved" / "file").exists())

    def test_cloud_and_second_host_finish_while_first_waits_then_resumes_once(self):
        path = self.root.parent / "policy.sqlite"
        accounts = AccountStore(path)
        token = accounts.redeem_client(accounts.issue_client_invitation(
            "owner", ["teams:manage", "messages:send", "sessions:read"]))
        principal = accounts.authenticate(token.token)
        accounts.create_team("owner", principal.client_id, "team")
        queue = self.resources.enter_context(closing(TeamQueue(path, accounts)))
        registry = AdapterRegistry()

        class LocalAdapter(ReferenceAdapter):
            def __init__(self, alias, executor, session):
                super().__init__(AdapterIdentity("fixture", "lab", alias))
                self.executor = executor
                self.session = session

            def dispatch(self, request):
                scope = HostScope(**request.payload["_tachi_host_scope"])
                self.executor.execute(scope, self.session, body=b"synthetic brief")
                return super().dispatch(request)

        other = self.store.connect(self.store.pair(self.store.issue_pairing("owner")))
        selected = self.resources.enter_context(FolderExecutor(self.outside, other.host_id, self.store.authorize))
        grant = self.store.grant("owner", other.host_id, selected.folder_id, "write")
        other_scope = HostScope("owner", other.host_id, grant, selected.folder_id, "write", "brief")
        first = LocalAdapter("first", self.executor, self.session)
        second = LocalAdapter("second", selected, other)
        cloud = ReferenceAdapter(AdapterIdentity("fixture", "lab", "cloud"))
        for adapter in (first, second, cloud):
            alias = adapter.identity.assistant_id
            registry.register(adapter)
            queue.add_assistant("team", principal, alias, adapter.identity, alias + "-conversation")
        queue.create_run("team", principal, "brief", "assistant:cloud", turn_limit=5)
        self.store.disconnect(self.session)
        for alias, scope in [("first", self.write), ("second", other_scope), ("cloud", None)]:
            queue.post("team", principal, "brief", alias, {}, direct_to="assistant:" + alias, scope=scope)
        queue.dispatch_one(registry, host_store=self.store, host_session=other)
        queue.dispatch_one(registry)
        self.assertEqual((self.outside / "brief").read_bytes(), b"synthetic brief")
        self.assertEqual(len(cloud.calls), 1)
        self.assertFalse((self.root / "brief").exists())
        self.assertEqual(queue.history("team", principal, "brief")[0]["deliveries"][0]["state"], "queued")

        first.session = self.store.connect(self.host)
        queue.dispatch_one(registry, host_store=self.store, host_session=first.session)
        self.assertEqual((self.root / "brief").read_bytes(), b"synthetic brief")
        self.assertIsNone(queue.dispatch_one(registry, host_store=self.store, host_session=first.session))
        self.assertEqual(len(first.calls), 1)
        queue.post("team", principal, "brief", "after-revocation", {}, direct_to="assistant:first",
                   scope=replace(self.write, relative_path="later"))
        self.store.revoke_grant("owner", self.host.host_id, self.write.grant_id)
        queue.dispatch_one(registry, host_store=self.store, host_session=first.session)
        self.assertEqual(queue.history("team", principal, "brief")[-1]["deliveries"][0]["state"], "blocked")
        self.assertFalse((self.root / "later").exists())

    def test_local_transport_cli(self):
        demo = [sys.executable, "-m", "tachi.hosts.folder_demo"]
        description = subprocess.check_output(demo + ["capabilities"])
        self.assertEqual(json.loads(description)["path_scope"], "direct-children-only")
        target = ["--folder", str(self.root), "note"]
        created = subprocess.run(demo + ["write", *target], input=b"hello", capture_output=True, check=True)
        self.assertEqual(created.stdout + created.stderr, b"")
        self.assertEqual(subprocess.check_output(demo + ["read", *target]), b"hello")


@unittest.skipIf(sys.platform == "darwin", "unsupported-platform behavior")
class UnsupportedPlatformTests(unittest.TestCase):
    def test_no_unconfined_fallback(self):
        with self.assertRaises(NotImplementedError):
            FolderExecutor(".", "host", None)
