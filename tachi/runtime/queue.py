"""Durable routing for trusted coordinator callers with an authenticated team member.

Room posts enter the shared transcript. Explicit mentions and direct addresses schedule
assistant work. A run shares one turn budget across all its members. Each worker opens
its own TeamQueue; no SQLite transaction spans a native call.
"""

import json
import sqlite3
from contextlib import contextmanager
from dataclasses import asdict, dataclass
from pathlib import Path
from uuid import uuid4

from tachi.hosts import AccountStore, ClientPrincipal, HostSession, HostStore

from .contract import (
    AdapterEvent, AdapterIdentity, AdapterRegistry, Capability, DispatchRequest,
    DispatchUncertain, EventKind, _ids, _json_object,
)


_SCHEMA = """
CREATE TABLE IF NOT EXISTS rt_assistant (
    team TEXT NOT NULL, member TEXT NOT NULL,
    provider TEXT NOT NULL, account TEXT NOT NULL, assistant TEXT NOT NULL, session TEXT NOT NULL,
    PRIMARY KEY(team, member), UNIQUE(provider, account, assistant, session)
);
CREATE TABLE IF NOT EXISTS rt_run (
    team TEXT NOT NULL, run TEXT NOT NULL, lead TEXT NOT NULL,
    state TEXT NOT NULL DEFAULT 'running', turns INTEGER NOT NULL DEFAULT 0,
    turn_limit INTEGER NOT NULL, PRIMARY KEY(team, run),
    FOREIGN KEY(team, lead) REFERENCES rt_assistant(team, member)
);
CREATE TABLE IF NOT EXISTS rt_message (
    seq INTEGER PRIMARY KEY, team TEXT NOT NULL, message TEXT NOT NULL,
    run TEXT NOT NULL, author TEXT NOT NULL, direct_to TEXT, mentions TEXT NOT NULL,
    reply_to TEXT, capability TEXT NOT NULL, payload TEXT NOT NULL, scope TEXT,
    human TEXT NOT NULL, client TEXT NOT NULL, membership TEXT NOT NULL, recipient_membership TEXT,
    parent_request TEXT, parent_event TEXT,
    UNIQUE(team, message), FOREIGN KEY(team, run) REFERENCES rt_run(team, run),
    FOREIGN KEY(team, reply_to) REFERENCES rt_message(team, message)
);
CREATE TABLE IF NOT EXISTS rt_delivery (
    seq INTEGER PRIMARY KEY, team TEXT NOT NULL, message TEXT NOT NULL, target TEXT NOT NULL,
    request TEXT NOT NULL UNIQUE, host TEXT, state TEXT NOT NULL DEFAULT 'queued', reason TEXT,
    UNIQUE(team, message, target),
    FOREIGN KEY(team, message) REFERENCES rt_message(team, message),
    FOREIGN KEY(team, target) REFERENCES rt_assistant(team, member)
);
CREATE INDEX IF NOT EXISTS rt_session_work ON rt_delivery(team, target, seq);
CREATE INDEX IF NOT EXISTS rt_ready ON rt_delivery(state, host, seq);
CREATE TABLE IF NOT EXISTS rt_event (
    seq INTEGER PRIMARY KEY, request TEXT NOT NULL REFERENCES rt_delivery(request),
    event TEXT NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL, UNIQUE(request, event)
);
"""


@dataclass(frozen=True)
class HostScope:
    """Opaque scope only. Pairing, credential and session secrets stay with the host."""

    owner_id: str
    host_id: str
    grant_id: str
    folder_id: str
    action: str
    relative_path: str

    def __post_init__(self) -> None:
        _ids(*asdict(self).values())
        if self.action not in {"read", "write"}:
            raise ValueError("unknown host action")


class TeamQueue:
    def __init__(self, path: str | Path, accounts: AccountStore) -> None:
        self.accounts = accounts
        self.db = sqlite3.connect(path, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.executescript(_SCHEMA)

    def close(self) -> None:
        self.db.close()

    @contextmanager
    def _write(self):
        self.db.execute("BEGIN IMMEDIATE")
        try:
            yield
            self.db.commit()
        except BaseException:
            self.db.rollback()
            raise

    def _authorize(self, team, principal, scope):
        return self.accounts.authorize_membership(principal.human_id, principal.client_id, team, scope)

    def _recipient(self, team, address):
        _ids(address)
        kind, _, identifier = address.partition(":")
        _ids(identifier)
        if kind == "human":
            membership = self.accounts.team_membership(team, identifier)
            if membership is None:
                raise PermissionError("unknown team member")
            return membership.membership_id
        if kind != "assistant" or not self.db.execute(
            "SELECT 1 FROM rt_assistant WHERE team=? AND member=?", (team, address)
        ).fetchone():
            raise PermissionError("unknown assistant address")
        return None

    def add_assistant(self, team: str, principal: ClientPrincipal, alias: str,
                      identity: AdapterIdentity, session_id: str) -> None:
        """Bind an already-authorized session to one team. Human membership lives in AccountStore."""
        _ids(team, alias, session_id)
        with self._write():
            self._authorize(team, principal, "teams:manage")
            self.db.execute("INSERT INTO rt_assistant VALUES(?,?,?,?,?,?)", (
                team, "assistant:" + alias, identity.provider, identity.account_id,
                identity.assistant_id, session_id,
            ))

    @staticmethod
    def _limit(value):
        if type(value) is not int or not 1 <= value <= 2**31 - 1:
            raise ValueError("turn limit must be a positive 32-bit integer")

    def create_run(self, team: str, principal: ClientPrincipal, run: str, lead: str, *, turn_limit: int) -> None:
        _ids(run)
        self._limit(turn_limit)
        with self._write():
            self._authorize(team, principal, "teams:manage")
            if not lead.startswith("assistant:"):
                raise ValueError("run lead must be a bound assistant")
            self._recipient(team, lead)
            self.db.execute("INSERT INTO rt_run(team,run,lead,turn_limit) VALUES(?,?,?,?)",
                            (team, run, lead, turn_limit))

    def _run(self, team, run):
        row = self.db.execute("SELECT * FROM rt_run WHERE team=? AND run=?", (team, run)).fetchone()
        if row is None:
            raise KeyError("unknown run")
        return row

    def run_status(self, team: str, principal: ClientPrincipal, run: str) -> dict:
        self._authorize(team, principal, "sessions:read")
        return dict(self._run(team, run))

    def intervene(self, team: str, principal: ClientPrincipal, run: str, state: str, *,
                  turn_limit: int | None = None) -> None:
        """Pause/resume future dispatch or end a run. Submitted native work stays visible."""
        if state not in {"paused", "running", "cancelled", "completed"}:
            raise ValueError("unknown run state")
        if turn_limit is not None:
            self._limit(turn_limit)
        with self._write():
            self._authorize(team, principal, "teams:manage")
            old = self._run(team, run)
            if old["state"] in {"cancelled", "completed"}:
                raise ValueError("run has ended")
            self.db.execute("UPDATE rt_run SET state=?, turn_limit=COALESCE(?,turn_limit) WHERE team=? AND run=?",
                            (state, turn_limit, team, run))
            if state in {"cancelled", "completed"}:
                self.db.execute("""
                    UPDATE rt_delivery SET state='cancelled' WHERE team=? AND state IN ('queued','blocked')
                    AND message IN (SELECT message FROM rt_message WHERE team=? AND run=?)
                """, (team, team, run))

    def post(self, team: str, principal: ClientPrincipal, run: str, message: str, payload: dict, *,
             direct_to: str | None = None, mentions: tuple[str, ...] = (),
             reply_to: str | None = None, capability: Capability = Capability.MESSAGE,
             scope: HostScope | None = None) -> None:
        """Post as the authenticated human. Addresses use human:<id> or assistant:<alias>."""
        with self._write():
            membership = self._authorize(team, principal, "messages:send")
            origin = (principal.human_id, principal.client_id, membership.membership_id)
            if scope and scope.owner_id != principal.human_id:
                raise PermissionError("host grant belongs to another human")
            self._post(team, "human:" + principal.human_id, run, message, payload, direct_to,
                       mentions, reply_to, capability, scope, origin, None, None)

    def post_reply(self, parent: AdapterEvent, message: str, payload: dict, *,
                   direct_to: str | None = None, mentions: tuple[str, ...] = (),
                   capability: Capability = Capability.MESSAGE) -> None:
        """Trusted connector handoff from a recorded native result or progress event."""
        with self._write():
            source = self.db.execute("""
                SELECT d.target,m.*,e.kind,e.payload AS event_payload,
                       a.provider,a.account,a.assistant,a.session
                FROM rt_delivery d JOIN rt_message m USING(team,message)
                JOIN rt_assistant a ON a.team=d.team AND a.member=d.target
                JOIN rt_event e ON e.request=d.request WHERE d.request=? AND e.event=?
            """, (parent.request_id, parent.event_id)).fetchone()
            if source is None or (
                parent.identity != AdapterIdentity(source["provider"], source["account"], source["assistant"])
                or parent.session_id != source["session"] or parent.kind.value != source["kind"]
                or parent.kind not in {EventKind.PROGRESS, EventKind.COMPLETED}
                or _json_object(parent.payload) != source["event_payload"]
            ):
                raise PermissionError("handoff requires a correlated native event")
            origin = (source["human"], source["client"], source["membership"])
            self.accounts.authorize_membership(origin[0], origin[1], source["team"], "messages:send",
                                               membership_id=origin[2])
            self._post(source["team"], source["target"], source["run"], message, payload, direct_to,
                       mentions, source["message"], capability, None, origin, parent.request_id, parent.event_id)

    def _post(self, team, author, run, message, payload, direct_to, mentions, reply_to,
              capability, scope, origin, parent_request, parent_event):
        if not isinstance(mentions, tuple):
            raise TypeError("mentions must be a tuple of member IDs")
        _ids(run, message, *mentions)
        if direct_to is not None:
            _ids(direct_to)
        if reply_to is not None:
            _ids(reply_to)
        if not isinstance(capability, Capability) or len(set(mentions)) != len(mentions):
            raise ValueError("invalid operation or duplicate mention")
        if direct_to is not None and mentions:
            raise ValueError("a direct message has a single destination")
        if "_tachi_host_scope" in payload:
            raise ValueError("host scope is supplied by the coordinator")
        if scope and (direct_to is None or not direct_to.startswith("assistant:")):
            raise PermissionError("host scope requires direct addressing by its owner")
        encoded = _json_object(payload)
        addresses = (direct_to,) if direct_to is not None else mentions
        memberships = {address: self._recipient(team, address) for address in addresses}
        recipient_membership = memberships.get(direct_to)
        envelope = (run, author, direct_to, json.dumps(sorted(mentions)), reply_to, capability.value,
                    encoded, _json_object(asdict(scope)) if scope else None, *origin,
                    recipient_membership, parent_request, parent_event)
        existing = self.db.execute("""
            SELECT run,author,direct_to,mentions,reply_to,capability,payload,scope,
                   human,client,membership,recipient_membership,parent_request,parent_event
            FROM rt_message WHERE team=? AND message=?
        """, (team, message)).fetchone()
        if existing is not None:
            if tuple(existing) != envelope:
                raise ValueError("message ID already used")
            return
        if self._run(team, run)["state"] in {"completed", "cancelled"}:
            raise ValueError("run has ended")
        if reply_to is not None:
            parent = self.db.execute("SELECT * FROM rt_message WHERE team=? AND message=?",
                                     (team, reply_to)).fetchone()
            if parent is None or parent["run"] != run:
                raise ValueError("unknown reply in run")
            if parent["direct_to"] is not None and (
                direct_to is None or {direct_to, author} != {parent["author"], parent["direct_to"]}
            ):
                raise PermissionError("reply exceeds direct audience")
            if parent["direct_to"] is not None:
                for address, generation in ((parent["author"], parent["membership"]),
                                            (parent["direct_to"], parent["recipient_membership"])):
                    if address.startswith("human:") and self._recipient(team, address) != generation:
                        raise PermissionError("direct audience membership changed")
        self.db.execute("""
            INSERT INTO rt_message(team,message,run,author,direct_to,mentions,reply_to,capability,payload,scope,
                                   human,client,membership,recipient_membership,parent_request,parent_event)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, (team, message, *envelope))
        for address in addresses:
            if address.startswith("assistant:"):
                self.db.execute("""
                    INSERT INTO rt_delivery(team,message,target,request,host) VALUES(?,?,?,?,?)
                """, (team, message, address, uuid4().hex, scope.host_id if scope else None))

    def history(self, team: str, principal: ClientPrincipal, run: str) -> list[dict]:
        membership = self._authorize(team, principal, "sessions:read").membership_id
        actor = "human:" + principal.human_id
        rows = self.db.execute("""
            SELECT message,author,direct_to,mentions,reply_to,payload,capability,parent_request,parent_event FROM rt_message
            WHERE team=? AND run=? AND (direct_to IS NULL OR
            (direct_to=? AND recipient_membership=?) OR (author=? AND membership=?)) ORDER BY seq
        """, (team, run, actor, membership, actor, membership))
        messages = []
        for row in rows:
            message = dict(row)
            message["mentions"] = json.loads(row["mentions"])
            message["payload"] = json.loads(row["payload"])
            deliveries = self.db.execute("""
                SELECT d.request,d.target,d.state,d.reason,a.provider,a.account AS account_id,
                       a.assistant AS assistant_id,a.session AS session_id
                FROM rt_delivery d JOIN rt_assistant a ON a.team=d.team AND a.member=d.target
                WHERE d.team=? AND d.message=? ORDER BY d.seq
            """, (team, row["message"]))
            message["deliveries"] = [
                {**dict(delivery), "events": [
                    {**dict(event), "payload": json.loads(event["payload"])}
                    for event in self.db.execute("""
                        SELECT event,kind,payload FROM rt_event WHERE request=? ORDER BY seq
                    """, (delivery["request"],))
                ]} for delivery in deliveries
            ]
            messages.append(message)
        return messages

    def _claim(self, host_id):
        with self._write():
            row = self.db.execute("""
                SELECT d.request,d.target,d.team,m.*,a.provider,a.account,a.assistant,a.session
                FROM rt_delivery d JOIN rt_message m USING(team,message)
                JOIN rt_assistant a ON a.team=d.team AND a.member=d.target
                JOIN rt_run r ON r.team=m.team AND r.run=m.run
                WHERE d.state='queued' AND d.host IS ? AND r.state='running' AND r.turns<r.turn_limit
                AND NOT EXISTS (
                    SELECT 1 FROM rt_delivery prev WHERE prev.team=d.team AND prev.target=d.target
                    AND prev.seq<d.seq AND prev.state IN ('queued','uncertain','active','blocked')
                ) ORDER BY d.seq LIMIT 1
            """, (host_id,)).fetchone()
            if row is None:
                return None
            # From this commit until a correlated terminal event, replay is unsafe.
            self.db.execute("UPDATE rt_delivery SET state='uncertain', reason=NULL WHERE request=?", (row["request"],))
            self.db.execute("UPDATE rt_run SET turns=turns+1 WHERE team=? AND run=?", (row["team"], row["run"]))
            return row

    def dispatch_one(self, registry: AdapterRegistry, *, host_session: HostSession | None = None,
                     host_store: HostStore | None = None) -> str | None:
        """Claim one cloud delivery, or one delivery for this authenticated host worker.

        For host work the adapter receives the exact authorized _tachi_host_scope in
        its payload. A host executor must confine filesystem access to that scope and
        recheck it with its live session before each local effect.
        """
        if (host_session is None) != (host_store is None):
            raise ValueError("host workers require both a session and a store")
        row = self._claim(host_session.host_id if host_session else None)
        if row is None:
            return None
        identity = AdapterIdentity(row["provider"], row["account"], row["assistant"])
        payload = json.loads(row["payload"])
        capability = Capability(row["capability"])
        try:
            self.accounts.authorize_membership(row["human"], row["client"], row["team"], "messages:send",
                                               membership_id=row["membership"])
        except PermissionError:
            # Revoked client/membership generations cannot authorize later work on this lane.
            return self._not_submitted(row, "denied", "origin_denied")
        try:
            if capability not in registry.capabilities(identity):
                return self._not_submitted(row, "blocked", "unsupported_capability")
        except KeyError:
            return self._not_submitted(row, "blocked", "adapter_unavailable")
        if host_session is not None:
            scope = HostScope(**json.loads(row["scope"]))
            try:
                host_store.authorize(scope.owner_id, host_session, scope.grant_id,
                                     scope.folder_id, scope.action, scope.relative_path)
            except PermissionError:
                return self._not_submitted(row, "blocked", "host_denied")
            payload["_tachi_host_scope"] = asdict(scope)
        request = DispatchRequest(identity, row["session"], row["request"], capability, payload)
        try:
            events = registry.dispatch(request)
        except DispatchUncertain:
            return request.request_id
        try:
            with self._write():
                for event in events:
                    self._record(event)
        except ValueError:
            # Contradictory native events cannot settle this delivery. Keep its lane held.
            return request.request_id
        return request.request_id

    def _not_submitted(self, row, state, reason):
        with self._write():
            if self._run(row["team"], row["run"])["state"] in {"completed", "cancelled"}:
                state = "cancelled"
            self.db.execute("UPDATE rt_delivery SET state=?,reason=? WHERE request=?",
                            (state, reason, row["request"]))
            self.db.execute("UPDATE rt_run SET turns=turns-1 WHERE team=? AND run=?", (row["team"], row["run"]))
        return row["request"]

    def retry_blocked(self, team: str, principal: ClientPrincipal, request_id: str) -> None:
        """Only pre-dispatch failures are retryable. Recheck all authority on the next claim."""
        with self._write():
            self._authorize(team, principal, "teams:manage")
            result = self.db.execute("""
                UPDATE rt_delivery SET state='queued' WHERE team=? AND request=? AND state='blocked'
            """, (team, request_id))
            if not result.rowcount:
                raise ValueError("request is not safely retryable")

    def record(self, event: AdapterEvent) -> None:
        """Ingest a correlated event from the authenticated connector, including after restart."""
        with self._write():
            self._record(event)

    def _record(self, event):
        row = self.db.execute("""
            SELECT d.state,a.provider,a.account,a.assistant,a.session FROM rt_delivery d
            JOIN rt_assistant a ON a.team=d.team AND a.member=d.target WHERE d.request=?
        """, (event.request_id,)).fetchone()
        if row is None or event.identity != AdapterIdentity(row["provider"], row["account"], row["assistant"]) or (
            event.session_id != row["session"]
        ):
            raise ValueError("event outside dispatch scope")
        payload = _json_object(event.payload)
        previous = self.db.execute("SELECT kind,payload FROM rt_event WHERE request=? AND event=?",
                                   (event.request_id, event.event_id)).fetchone()
        if previous:
            if tuple(previous) != (event.kind.value, payload):
                raise ValueError("conflicting event ID")
            return
        terminal = {EventKind.COMPLETED, EventKind.CANCELLED, EventKind.FAILED}
        if row["state"] in {"queued", "blocked", "denied"} or (
            row["state"] == "cancelled" and not self.db.execute(
                "SELECT 1 FROM rt_event WHERE request=?", (event.request_id,)
            ).fetchone()
        ):
            raise ValueError("request has not been submitted")
        if row["state"] in terminal and event.kind in terminal and row["state"] != event.kind:
            raise ValueError("contradictory terminal event")
        self.db.execute("INSERT INTO rt_event(request,event,kind,payload) VALUES(?,?,?,?)",
                        (event.request_id, event.event_id, event.kind.value, payload))
        if row["state"] not in terminal:
            state = event.kind.value if event.kind in terminal else "active"
            self.db.execute("UPDATE rt_delivery SET state=? WHERE request=?", (state, event.request_id))
