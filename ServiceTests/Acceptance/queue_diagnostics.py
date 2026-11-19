"""Qualify the operator command against a private synthetic database with a live WAL."""
import json
import sqlite3
import subprocess
import sys
import tempfile
from contextlib import closing
from pathlib import Path


def main(coordinator):
    fixture = Path(__file__).resolve().parents[2] / "Packages/TachiRuntime/Tests/TachiRuntimeTests/Fixtures/python-v1.sql"
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "private-fixture.sqlite"

        def run(*args):
            return subprocess.run([coordinator, "diagnostics", *args], capture_output=True, timeout=10)

        def unavailable():
            result = run("--db", path)
            assert result.returncode != 0 and result.stdout == b""
            assert result.stderr == b"Queue diagnostics unavailable.\n"

        unavailable()
        assert not list(path.parent.iterdir())
        invalid = run("--db", path, "--private-fixture-argument")
        assert invalid.returncode != 0 and invalid.stdout == b""
        assert invalid.stderr == b"Usage: tachi-coordinator diagnostics --db PATH\n"

        with closing(sqlite3.connect(path)) as writer:
            # A valid but unrelated SQLite file must not be initialized or treated as an empty queue.
            writer.execute("CREATE TABLE private_fixture(value TEXT)")
            before = path.read_bytes()
            unavailable()
            assert path.read_bytes() == before
            writer.executescript(fixture.read_text())
            assert writer.execute("PRAGMA journal_mode=WAL").fetchone() == ("wal",)
            writer.execute("PRAGMA wal_autocheckpoint=0")
            writer.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            writer.execute("UPDATE rt_run SET state='private-future-run'")
            writer.execute("UPDATE rt_delivery SET state='blocked', reason='private-credential' WHERE seq=1")
            writer.execute("UPDATE rt_delivery SET state='private-future-delivery', host='private-host' WHERE seq=3")
            writer.execute("UPDATE rt_assistant SET provider='private-provider'")
            writer.execute("UPDATE rt_message SET payload=?, direct_to=?", ('{"text":"private-content"}', "private-destination"))
            writer.commit()
            wal = Path(str(path) + "-wal")
            assert wal.stat().st_size > 0
            writer.execute("BEGIN IMMEDIATE")
            writer.execute("UPDATE rt_delivery SET state='failed'")
            expected = {
                "runs": {"running": 0, "paused": 0, "completed": 0, "cancelled": 0, "other": 1},
                "deliveries": {"queued": 0, "active": 0, "blocked": 1, "uncertain": 1,
                               "denied": 0, "completed": 0, "failed": 0, "cancelled": 0, "other": 1},
            }
            before = (path.read_bytes(), wal.read_bytes())
            result = run("--db", path)
            assert result.returncode == 0 and result.stderr == b""
            assert len(result.stdout.splitlines()) == 1 and json.loads(result.stdout) == expected
            assert (path.read_bytes(), wal.read_bytes()) == before
            writer.rollback()
    print("PASS: redacted CLI output, committed WAL snapshot, unchanged database and WAL, sanitized failures")


if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve())
