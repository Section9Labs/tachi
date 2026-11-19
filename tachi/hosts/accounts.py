"""Local admin bootstrap and client authority for human accounts."""

import json
import secrets
from collections.abc import Iterable
from dataclasses import dataclass, field
from uuid import uuid4

from ._policy import AccessDenied, PolicyStore, _digest, _identifier, _require_one


CLIENT_SCOPES = frozenset({"sessions:read", "messages:send", "teams:manage"})


@dataclass(frozen=True)
class ClientCredential:
    client_id: str
    token: str = field(repr=False)


@dataclass(frozen=True)
class ClientPrincipal:
    human_id: str
    client_id: str
    scopes: frozenset[str]


class AccountStore(PolicyStore):
    INVITATION_SECONDS = 300
    _schema = """
    CREATE TABLE IF NOT EXISTS account_client_invitations (
        digest BLOB PRIMARY KEY NOT NULL,
        human_id TEXT NOT NULL,
        scopes TEXT NOT NULL,
        expires_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS account_clients (
        client_id TEXT PRIMARY KEY NOT NULL,
        digest BLOB UNIQUE NOT NULL,
        human_id TEXT NOT NULL,
        scopes TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS account_clients_by_human ON account_clients(human_id);
    """

    def issue_client_invitation(self, human_id: str, scopes: Iterable[str]) -> str:
        """Local operator only. Bind the approved identity and scopes before redemption."""
        _identifier(human_id)
        selected = frozenset(scopes)
        if not selected or not selected <= CLIENT_SCOPES:
            raise ValueError("select one or more supported client scopes")
        secret = secrets.token_urlsafe(32)
        with self._connection(write=True) as db:
            now = self._clock()
            db.execute("DELETE FROM account_client_invitations WHERE expires_at <= ?", (now,))
            db.execute(
                "INSERT INTO account_client_invitations VALUES (?, ?, ?, ?)",
                (_digest(secret), human_id, json.dumps(sorted(selected)), now + self.INVITATION_SECONDS),
            )
        return secret

    def redeem_client(self, invitation: str) -> ClientCredential:
        with self._connection(write=True) as db:
            digest = _digest(invitation)
            row = db.execute(
                "SELECT human_id, scopes FROM account_client_invitations WHERE digest = ? AND expires_at > ?",
                (digest, self._clock()),
            ).fetchone()
            if row is None:
                raise AccessDenied()
            credential = ClientCredential(uuid4().hex, secrets.token_urlsafe(32))
            db.execute(
                "INSERT INTO account_clients (client_id, digest, human_id, scopes) VALUES (?, ?, ?, ?)",
                (credential.client_id, _digest(credential.token), *row),
            )
            db.execute("DELETE FROM account_client_invitations WHERE digest = ?", (digest,))
        return credential

    def authenticate(self, token: str) -> ClientPrincipal:
        """Resolve a bearer on each request. A principal is a snapshot."""
        with self._connection() as db:
            row = db.execute(
                "SELECT human_id, client_id, scopes FROM account_clients WHERE digest = ?", (_digest(token),)
            ).fetchone()
        if row is None:
            raise AccessDenied()
        return ClientPrincipal(row[0], row[1], frozenset(json.loads(row[2])))

    def authorize_client(self, human_id: str, client_id: str, scope: str) -> None:
        """Trusted worker recheck using the origin captured at authenticated ingress."""
        _identifier(human_id)
        _identifier(client_id)
        if scope not in CLIENT_SCOPES:
            raise AccessDenied()
        with self._connection() as db:
            row = db.execute(
                "SELECT scopes FROM account_clients WHERE human_id = ? AND client_id = ?",
                (human_id, client_id),
            ).fetchone()
        if row is None or scope not in json.loads(row[0]):
            raise AccessDenied()

    def list_clients(self, human_id: str) -> tuple[str, ...]:
        """Local operator inventory for selecting a lost or retired client."""
        _identifier(human_id)
        with self._connection() as db:
            rows = db.execute(
                "SELECT client_id FROM account_clients WHERE human_id = ? ORDER BY client_id", (human_id,)
            ).fetchall()
        return tuple(row[0] for row in rows)

    def revoke_client(self, human_id: str, client_id: str) -> None:
        """Local operator only. Other clients of this human keep their authority."""
        _identifier(human_id)
        _identifier(client_id)
        with self._connection(write=True) as db:
            change = db.execute("DELETE FROM account_clients WHERE human_id = ? AND client_id = ?",
                                (human_id, client_id))
            _require_one(change)
