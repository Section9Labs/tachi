"""Explicitly synthetic reference teams owned by a paired human."""

import sqlite3
from contextlib import closing, contextmanager
from threading import Event, Thread
from uuid import uuid4

from tachi.hosts import AccessDenied
from .contract import AdapterEvent, AdapterIdentity, AdapterRegistry, Capability, EventKind
from .queue import TeamQueue


ALIASES = ("lead", "peer")
RUN = "assignment"
_SCHEMA = """
CREATE TABLE IF NOT EXISTS rt_reference_team (
    team TEXT PRIMARY KEY, human TEXT NOT NULL, creation TEXT NOT NULL, initial_limit INTEGER NOT NULL,
    ready INTEGER NOT NULL DEFAULT 0, UNIQUE(human, creation)
)
"""


class Conflict(ValueError):
    """A stable ID or state transition conflicts with persisted work."""


class _ReferenceCounter:
    version = 1
    capabilities = frozenset({Capability.MESSAGE})

    def __init__(self, team, alias):
        self.identity = AdapterIdentity("tachi-reference", team, alias)

    def dispatch(self, request):
        words = len(request.payload["text"].split())
        return (AdapterEvent(self.identity, request.session_id, request.request_id, "result",
                             EventKind.COMPLETED, {"words": words}),)


class ReferenceTeams:
    def __init__(self, path, accounts):
        self.path = path
        self.accounts = accounts
        self._wake = Event()
        with self.queue() as q:
            q.db.execute(_SCHEMA)

    def queue(self):
        return closing(TeamQueue(self.path, self.accounts))

    def create(self, q, principal, creation, limit):
        self.accounts.authorize_client(principal.human_id, principal.client_id, "teams:manage")
        # Reserve an opaque ID first. An interrupted request resumes provisioning on retry.
        with q._write():
            q.db.execute("""
                INSERT INTO rt_reference_team(team,human,creation,initial_limit) VALUES(?,?,?,?)
                ON CONFLICT(human,creation) DO NOTHING
            """, (uuid4().hex, principal.human_id, creation, limit))
            row = q.db.execute("SELECT * FROM rt_reference_team WHERE human=? AND creation=?",
                               (principal.human_id, creation)).fetchone()
            if row["initial_limit"] != limit:
                raise Conflict()
        team = row["team"]
        if not row["ready"]:
            try:
                self.accounts.create_team(principal.human_id, principal.client_id, team)
            except AccessDenied:
                # A concurrent or interrupted provision may already have created membership.
                self.accounts.authorize_team(principal.human_id, principal.client_id, team, "teams:manage")
        with q._write():
            q._authorize(team, principal, "teams:manage")
            if q.db.execute("SELECT ready FROM rt_reference_team WHERE team=?", (team,)).fetchone()[0] == 0:
                for alias in ALIASES:
                    q._insert_assistant(team, alias, _ReferenceCounter(team, alias).identity, uuid4().hex)
                q._insert_run(team, RUN, "assistant:lead", limit)
                q.db.execute("UPDATE rt_reference_team SET ready=1 WHERE team=?", (team,))
            return self.summary(q, team)

    def require_team(self, q, principal, team, scope):
        # Resolve public routes only inside this human's provisioned reference namespace.
        if not q.db.execute("SELECT 1 FROM rt_reference_team WHERE team=? AND human=? AND ready=1",
                            (team, principal.human_id)).fetchone():
            raise KeyError("team")
        self.accounts.authorize_team(principal.human_id, principal.client_id, team, scope)

    def list_teams(self, q, principal):
        self.accounts.authorize_client(principal.human_id, principal.client_id, "sessions:read")
        summaries = []
        for row in q.db.execute("SELECT team FROM rt_reference_team WHERE human=? AND ready=1 ORDER BY rowid",
                                (principal.human_id,)):
            self.require_team(q, principal, row["team"], "sessions:read")
            summaries.append(self.summary(q, row["team"]))
        return summaries

    @staticmethod
    def summary(q, team):
        run = q._run(team, RUN)
        return {"teamID": team, "mode": "reference", "assistants": list(ALIASES),
                "runState": run["state"], "turnLimit": run["turn_limit"], "turnsUsed": run["turns"]}

    @staticmethod
    def messages(q, principal, team):
        messages = []
        addresses = {"assistant:" + alias for alias in ALIASES}
        for msg in q.history(team, principal, RUN):
            # Project only this surface's public addresses and human-authored text.
            if (msg["author"] != "human:" + principal.human_id
                    or msg["direct_to"] not in {None, *addresses}
                    or not set(msg["mentions"]) <= addresses
                    or not isinstance(msg["payload"].get("text"), str)):
                continue
            deliveries = []
            for delivery in msg["deliveries"]:
                if delivery["target"] not in addresses or delivery["provider"] != "tachi-reference":
                    continue
                alias = delivery["target"].removeprefix("assistant:")
                result = None
                for event in delivery["events"]:
                    words = event["payload"].get("words")
                    if event["kind"] == "completed" and type(words) is int:
                        result = f"Reference {alias} counted {words} word{'s' if words != 1 else ''}."
                deliveries.append({"assistant": alias, "state": delivery["state"], "result": result})
            messages.append({
                "messageID": msg["message"], "author": "you", "text": msg["payload"]["text"],
                "audience": msg["direct_to"].removeprefix("assistant:") if msg["direct_to"] else "room",
                "mentions": [value.removeprefix("assistant:") for value in msg["mentions"]],
                "replyTo": msg["reply_to"], "deliveries": deliveries,
            })
        return messages

    def wake(self):
        self._wake.set()

    @contextmanager
    def worker(self):
        stop = Event()

        def serve():
            with self.queue() as q:
                while not stop.is_set():
                    self._wake.clear()
                    advanced = False
                    try:
                        pending = q.db.execute("""
                            SELECT DISTINCT d.team FROM rt_delivery d JOIN rt_reference_team t USING(team)
                            WHERE t.ready=1 AND d.host IS NULL AND d.state='queued'
                        """).fetchall()
                        for row in pending:
                            if stop.is_set():
                                break
                            registry = AdapterRegistry()
                            for alias in ALIASES:
                                registry.register(_ReferenceCounter(row["team"], alias))
                            if q.dispatch_one(registry, team_id=row["team"]) is not None:
                                advanced = True
                    except sqlite3.OperationalError as exc:
                        if getattr(exc, "sqlite_errorcode", 0) not in {sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED}:
                            raise
                    if not advanced:
                        self._wake.wait(1)

        thread = Thread(target=serve, name="reference-team-worker")
        thread.start()
        try:
            yield
        finally:
            stop.set()
            self.wake()
            thread.join()
