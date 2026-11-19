"""Create a verified copy of one SQLite database in a new file."""

import argparse
import os
import sqlite3
import tempfile
from contextlib import closing
from pathlib import Path


def snapshot(source: Path, destination: Path) -> None:
    """Include committed WAL data and publish only a complete standalone copy."""
    if destination.exists() or destination.is_symlink():
        raise FileExistsError(destination)
    source = source.resolve(strict=True)
    if not source.is_file() or source.stat().st_size == 0:
        raise ValueError("expected a file containing a SQLite database")
    with tempfile.TemporaryDirectory(dir=destination.parent) as directory:
        staging = Path(directory) / "snapshot"
        staging.touch(mode=0o600)
        with closing(sqlite3.connect(source.as_uri() + "?mode=ro", uri=True)) as reader:
            with closing(sqlite3.connect(staging)) as writer:
                reader.backup(writer, pages=256)
                writer.execute("PRAGMA journal_mode=DELETE")
                if writer.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
                    raise ValueError("database integrity check failed")
        # Hard linking also refuses an existing destination created during the backup.
        os.link(staging, destination)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        snapshot(args.source, args.destination)
    except (OSError, ValueError, sqlite3.DatabaseError) as error:
        parser.exit(1, f"Snapshot failed: {error}\n")


if __name__ == "__main__":
    main()
