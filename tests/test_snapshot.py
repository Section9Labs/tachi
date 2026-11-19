import sqlite3
import stat
import tempfile
import unittest
from contextlib import closing
from pathlib import Path

from tachi.snapshot import snapshot


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.source = self.root / "sample #1.sqlite"
        self.backup = self.root / "backup.sqlite"

    def test_restore_committed_wal_with_writer_still_open(self):
        with closing(sqlite3.connect(self.source)) as writer:
            writer.execute("PRAGMA journal_mode=WAL")
            writer.execute("CREATE TABLE tasks(state TEXT)")
            writer.execute("INSERT INTO tasks VALUES ('queued')")
            writer.commit()
            writer.execute("INSERT INTO tasks VALUES ('uncommitted')")
            snapshot(self.source, self.backup)
        restored = self.root / "restored.sqlite"
        snapshot(self.backup, restored)
        with closing(sqlite3.connect(restored)) as reader:
            self.assertEqual(reader.execute("SELECT state FROM tasks").fetchall(), [("queued",)])
        self.assertEqual(stat.S_IMODE(restored.stat().st_mode), 0o600)

    def test_refuses_to_overwrite_and_leaves_no_partial_output(self):
        self.source.write_text("invalid database")
        with self.assertRaises(sqlite3.DatabaseError):
            snapshot(self.source, self.backup)
        self.assertFalse(self.backup.exists())
        self.backup.write_text("existing data")
        with self.assertRaises(FileExistsError):
            snapshot(self.source, self.backup)
        self.assertEqual(self.backup.read_text(), "existing data")
