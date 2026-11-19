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


@dataclass(frozen=True)
class TeamMembership:
    role: str
    membership_id: str


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
    CREATE TABLE IF NOT EXISTS account_team_members (
        team_id TEXT NOT NULL,
        human_id TEXT NOT NULL,
        membership_id TEXT UNIQUE NOT NULL,
        role TEXT NOT NULL CHECK (role IN ('owner', 'member')),
        PRIMARY KEY (team_id, human_id)
    );
    CREATE UNIQUE INDEX IF NOT EXISTS account_team_owner ON account_team_members(team_id)
        WHERE role = 'owner';
    CREATE TABLE IF NOT EXISTS account_team_invitations (
        digest BLOB PRIMARY KEY NOT NULL,
        team_id TEXT NOT NULL,
        recipient_id TEXT NOT NULL,
        issuer_client TEXT NOT NULL REFERENCES account_clients(client_id) ON DELETE CASCADE,
        issuer_membership TEXT NOT NULL REFERENCES account_team_members(membership_id) ON DELETE CASCADE,
        expires_at REAL NOT NULL,
        UNIQUE (team_id, recipient_id)
    );
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

    @staticmethod
    def _client_scopes(db, human_id, client_id):
        _identifier(human_id)
        _identifier(client_id)
        row = db.execute(
            "SELECT scopes FROM account_clients WHERE human_id = ? AND client_id = ?",
            (human_id, client_id),
        ).fetchone()
        if row is None:
            raise AccessDenied()
        return json.loads(row[0])

    def authorize_client(self, human_id: str, client_id: str, scope: str) -> None:
        """Trusted worker recheck using the origin captured at authenticated ingress."""
        with self._connection() as db:
            if scope not in self._client_scopes(db, human_id, client_id):
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

    def create_team(self, human_id: str, client_id: str, team_id: str) -> None:
        """The initial owner membership creates the team. Team IDs cannot be claimed twice."""
        _identifier(team_id)
        with self._connection(write=True) as db:
            if "teams:manage" not in self._client_scopes(db, human_id, client_id):
                raise AccessDenied()
            change = db.execute(
                """INSERT INTO account_team_members (team_id, human_id, membership_id, role)
                   SELECT ?, ?, ?, 'owner' WHERE NOT EXISTS
                   (SELECT 1 FROM account_team_members WHERE team_id = ?)""",
                (team_id, human_id, uuid4().hex, team_id),
            )
            _require_one(change)

    def team_membership(self, team_id: str, human_id: str) -> TeamMembership | None:
        """Trusted recipient lookup. A re-invited recipient has a fresh membership ID."""
        _identifier(team_id)
        _identifier(human_id)
        with self._connection() as db:
            row = db.execute(
                "SELECT role, membership_id FROM account_team_members WHERE team_id = ? AND human_id = ?",
                (team_id, human_id),
            ).fetchone()
        return TeamMembership(*row) if row else None

    def team_role(self, team_id: str, human_id: str) -> str | None:
        membership = self.team_membership(team_id, human_id)
        return membership.role if membership else None

    @staticmethod
    def _authorize_membership(db, human_id, client_id, team_id, scope, membership_id=None):
        _identifier(human_id)
        _identifier(client_id)
        _identifier(team_id)
        row = db.execute(
            """SELECT m.role, m.membership_id, c.scopes
               FROM account_team_members m JOIN account_clients c USING (human_id)
               WHERE m.human_id = ? AND c.client_id = ? AND m.team_id = ?""",
            (human_id, client_id, team_id),
        ).fetchone()
        if row is None or scope not in json.loads(row[2]):
            raise AccessDenied()
        role, current_id = row[:2]
        if scope == "teams:manage" and role != "owner":
            raise AccessDenied()
        if membership_id is not None and membership_id != current_id:
            raise AccessDenied()
        return TeamMembership(role, current_id)

    def authorize_membership(self, human_id: str, client_id: str, team_id: str, scope: str,
                             *, membership_id: str | None = None) -> TeamMembership:
        """Capture generation at ingress, then require that generation immediately before dispatch."""
        with self._connection() as db:
            return self._authorize_membership(db, human_id, client_id, team_id, scope, membership_id)

    def authorize_team(self, human_id: str, client_id: str, team_id: str, scope: str) -> str:
        return self.authorize_membership(human_id, client_id, team_id, scope).role

    def invite_member(self, human_id: str, client_id: str, team_id: str, recipient_id: str) -> str:
        """An owner's new invitation supersedes any pending invitation to this recipient."""
        _identifier(recipient_id)
        with self._connection(write=True) as db:
            owner = self._authorize_membership(db, human_id, client_id, team_id, "teams:manage")
            now = self._clock()
            db.execute("DELETE FROM account_team_invitations WHERE expires_at <= ?", (now,))
            invitation = secrets.token_urlsafe(32)
            change = db.execute(
                """INSERT INTO account_team_invitations
                     (digest, team_id, recipient_id, issuer_client, issuer_membership, expires_at)
                   SELECT ?, ?, ?, ?, ?, ? WHERE NOT EXISTS
                     (SELECT 1 FROM account_team_members WHERE team_id = ? AND human_id = ?)
                   ON CONFLICT (team_id, recipient_id) DO UPDATE SET
                     digest = excluded.digest, issuer_client = excluded.issuer_client,
                     issuer_membership = excluded.issuer_membership, expires_at = excluded.expires_at""",
                (_digest(invitation), team_id, recipient_id, client_id, owner.membership_id,
                 now + self.INVITATION_SECONDS, team_id, recipient_id),
            )
            _require_one(change)
        return invitation

    def accept_invitation(self, human_id: str, client_id: str, invitation: str) -> TeamMembership:
        """A live client may accept only for the exact invited human."""
        digest = _digest(invitation)
        with self._connection(write=True) as db:
            self._client_scopes(db, human_id, client_id)
            member = TeamMembership("member", uuid4().hex)
            change = db.execute(
                """INSERT INTO account_team_members (team_id, human_id, membership_id, role)
                   SELECT team_id, recipient_id, ?, ? FROM account_team_invitations
                   WHERE digest = ? AND recipient_id = ? AND expires_at > ?""",
                (member.membership_id, member.role, digest, human_id, self._clock()),
            )
            _require_one(change)
            db.execute("DELETE FROM account_team_invitations WHERE digest = ?", (digest,))
        return member

    def revoke_member(self, human_id: str, client_id: str, team_id: str, recipient_id: str) -> None:
        """Remove an active member or withdraw a pending invitation in one transaction."""
        _identifier(recipient_id)
        with self._connection(write=True) as db:
            self._authorize_membership(db, human_id, client_id, team_id, "teams:manage")
            invitation = db.execute(
                "DELETE FROM account_team_invitations WHERE team_id = ? AND recipient_id = ?",
                (team_id, recipient_id),
            )
            member = db.execute(
                "DELETE FROM account_team_members WHERE team_id = ? AND human_id = ? AND role = 'member'",
                (team_id, recipient_id),
            )
            if not (invitation.rowcount or member.rowcount):
                raise AccessDenied()
