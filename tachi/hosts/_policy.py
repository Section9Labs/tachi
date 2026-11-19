"""Shared SQLite policy store primitives."""

import hashlib
import sqlite3
import time
from contextlib import closing, contextmanager


class AccessDenied(PermissionError):
    """Missing, expired, revoked or mismatched authority."""


def _digest(secret: str) -> bytes:
    if not isinstance(secret, str) or not secret.isascii() or len(secret) != 43:
        raise AccessDenied()
    return hashlib.sha256(secret.encode("ascii")).digest()


def _identifier(value: str) -> None:
    # Reject non-strings before SQLite TEXT affinity can coerce principal IDs.
    if not isinstance(value, str) or not value.strip() or not value.isprintable():
        raise AccessDenied()


def _require_one(cursor: sqlite3.Cursor) -> None:
    if cursor.rowcount != 1:
        raise AccessDenied()


class PolicyStore:
    _schema: str

    def __init__(self, db_path, *, clock=time.time):
        self._path = db_path
        self._clock = clock
        with self._connection() as db:
            db.executescript(self._schema)

    @contextmanager
    def _connection(self, *, write=False):
        with closing(sqlite3.connect(self._path)) as db, db:
            db.execute("PRAGMA foreign_keys = ON")
            if write:
                db.execute("BEGIN IMMEDIATE")
            yield db
