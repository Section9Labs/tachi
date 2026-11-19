"""Pair hosts and authorize individual folder operations against current SQLite state."""

import secrets
from dataclasses import dataclass, field
from uuid import uuid4

from ._policy import AccessDenied, PolicyStore, _digest, _identifier, _require_one


@dataclass(frozen=True)
class HostCredential:
    host_id: str
    secret: str = field(repr=False)


@dataclass(frozen=True)
class HostSession:
    host_id: str
    secret: str = field(repr=False)


_SCHEMA = """
CREATE TABLE IF NOT EXISTS host_pairings (
    digest BLOB PRIMARY KEY NOT NULL,
    owner_id TEXT NOT NULL,
    expires_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS host_devices (
    host_id TEXT PRIMARY KEY NOT NULL,
    owner_id TEXT NOT NULL,
    credential_digest BLOB NOT NULL,
    session_digest BLOB,
    lease_until REAL
);
CREATE TABLE IF NOT EXISTS host_grants (
    grant_id TEXT PRIMARY KEY NOT NULL,
    host_id TEXT NOT NULL REFERENCES host_devices(host_id) ON DELETE CASCADE,
    folder_id TEXT NOT NULL,
    action TEXT NOT NULL CHECK (action IN ('read', 'write'))
);
CREATE INDEX IF NOT EXISTS host_grants_by_host ON host_grants(host_id);
"""


def _scope(folder_id: str, action: str) -> None:
    _identifier(folder_id)
    if "/" in folder_id or "\\" in folder_id or folder_id in (".", ".."):
        raise AccessDenied()
    if action not in ("read", "write"):
        raise AccessDenied()


def _relative_path(path: str) -> None:
    if not isinstance(path, str) or not path.isprintable() or "\\" in path or ":" in path:
        raise AccessDenied()
    if any(part in ("", ".", "..") for part in path.split("/")):
        raise AccessDenied()


class HostStore(PolicyStore):
    """Use a file-backed database in a coordinator-private directory."""

    _schema = _SCHEMA
    PAIRING_SECONDS = 300
    LEASE_SECONDS = 30

    def issue_pairing(self, owner_id: str) -> str:
        """Return a short-lived bearer invitation bound to the authenticated owner."""
        _identifier(owner_id)
        secret = secrets.token_urlsafe(32)
        with self._connection(write=True) as db:
            now = self._clock()
            db.execute("DELETE FROM host_pairings WHERE expires_at <= ?", (now,))
            db.execute(
                "INSERT INTO host_pairings (digest, owner_id, expires_at) VALUES (?, ?, ?)",
                (_digest(secret), owner_id, now + self.PAIRING_SECONDS),
            )
        return secret

    def pair(self, pairing_secret: str) -> HostCredential:
        """Consume one invitation and create one host, initially disconnected."""
        with self._connection(write=True) as db:
            digest = _digest(pairing_secret)
            row = db.execute(
                "SELECT owner_id FROM host_pairings WHERE digest = ? AND expires_at > ?",
                (digest, self._clock()),
            ).fetchone()
            if row is None:
                raise AccessDenied()
            credential = HostCredential(uuid4().hex, secrets.token_urlsafe(32))
            db.execute(
                "INSERT INTO host_devices (host_id, owner_id, credential_digest) VALUES (?, ?, ?)",
                (credential.host_id, row[0], _digest(credential.secret)),
            )
            db.execute("DELETE FROM host_pairings WHERE digest = ?", (digest,))
        return credential

    def connect(self, credential: HostCredential) -> HostSession:
        """Authenticate an outbound connection and supersede any previous lease."""
        session = HostSession(credential.host_id, secrets.token_urlsafe(32))
        with self._connection(write=True) as db:
            change = db.execute(
                """UPDATE host_devices SET session_digest = ?, lease_until = ?
                   WHERE host_id = ? AND credential_digest = ?""",
                (_digest(session.secret), self._clock() + self.LEASE_SECONDS,
                 credential.host_id, _digest(credential.secret)),
            )
            _require_one(change)
        return session

    def heartbeat(self, session: HostSession) -> None:
        with self._connection(write=True) as db:
            now = self._clock()
            change = db.execute(
                """UPDATE host_devices SET lease_until = ?
                   WHERE host_id = ? AND session_digest = ? AND lease_until > ?""",
                (now + self.LEASE_SECONDS, session.host_id, _digest(session.secret), now),
            )
            _require_one(change)

    def disconnect(self, session: HostSession) -> None:
        with self._connection(write=True) as db:
            change = db.execute(
                """UPDATE host_devices SET session_digest = NULL, lease_until = NULL
                   WHERE host_id = ? AND session_digest = ?""",
                (session.host_id, _digest(session.secret)),
            )
            _require_one(change)

    def grant(self, owner_id: str, host_id: str, folder_id: str, action: str) -> str:
        _identifier(owner_id)
        _scope(folder_id, action)
        grant_id = uuid4().hex
        with self._connection(write=True) as db:
            change = db.execute(
                """INSERT INTO host_grants (grant_id, host_id, folder_id, action)
                   SELECT ?, host_id, ?, ? FROM host_devices WHERE owner_id = ? AND host_id = ?""",
                (grant_id, folder_id, action, owner_id, host_id),
            )
            _require_one(change)
        return grant_id

    def authorize(self, owner_id: str, session: HostSession, grant_id: str,
                  folder_id: str, action: str, relative_path: str) -> None:
        """Check the executing host's live lease and the exact requested grant."""
        _identifier(owner_id)
        _scope(folder_id, action)
        _relative_path(relative_path)
        with self._connection() as db:
            row = db.execute(
                """SELECT h.lease_until FROM host_devices AS h JOIN host_grants AS g USING (host_id)
                   WHERE h.owner_id = ? AND h.host_id = ? AND h.session_digest = ?
                     AND g.grant_id = ? AND g.folder_id = ? AND g.action = ?""",
                (owner_id, session.host_id, _digest(session.secret),
                 grant_id, folder_id, action),
            ).fetchone()
        if row is None or row[0] <= self._clock():
            raise AccessDenied()

    def revoke_grant(self, owner_id: str, host_id: str, grant_id: str) -> None:
        _identifier(owner_id)
        with self._connection(write=True) as db:
            change = db.execute(
                """DELETE FROM host_grants WHERE grant_id = ? AND host_id = ?
                   AND EXISTS (SELECT 1 FROM host_devices WHERE host_id = ? AND owner_id = ?)""",
                (grant_id, host_id, host_id, owner_id),
            )
            _require_one(change)

    def revoke_host(self, owner_id: str, host_id: str) -> None:
        _identifier(owner_id)
        with self._connection(write=True) as db:
            change = db.execute(
                "DELETE FROM host_devices WHERE owner_id = ? AND host_id = ?",
                (owner_id, host_id),
            )
            _require_one(change)
