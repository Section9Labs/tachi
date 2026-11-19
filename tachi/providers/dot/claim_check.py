"""Experimental application layer for a user-subscribed synthetic MCP event."""

import base64
import hmac
import json
import secrets
import sqlite3
import time
from contextlib import closing, contextmanager
from datetime import datetime, timezone

EVENT = "tachi.sample.ready"
READ_TOOL = "read_sample"
RETURN_TOOL = "return_sample_total"
READ_SCOPE = "sample.read"
RETURN_SCOPE = "sample.return"


def _object_schema(**fields):
    return {
        "type": "object",
        "properties": {key: {"type": value} for key, value in fields.items()},
        "required": list(fields),
        "additionalProperties": False,
    }


def event_catalog():
    return {"events": [{
        "name": EVENT,
        "description": "A synthetic arithmetic sample is ready for this subscription.",
        "delivery": ["webhook"],
        "inputSchema": _object_schema(),
        "payloadSchema": _object_schema(subscription="string", claim="string"),
    }]}


def tool_catalog():
    tools = []
    for name, description, scope, extra in [
        (READ_TOOL, "Read the two counts for a synthetic sample.", READ_SCOPE, {}),
        (RETURN_TOOL, "Record the sum for a synthetic sample.", RETURN_SCOPE, {"total": "integer"}),
    ]:
        tools.append({
            "name": name, "description": description,
            "inputSchema": _object_schema(subscription="string", claim="string", **extra),
            "securitySchemes": [{"type": "oauth2", "scopes": [scope]}],
            "annotations": {"readOnlyHint": name == READ_TOOL, "openWorldHint": False},
        })
    return {"tools": tools}


def _ids(*values):
    if not all(isinstance(value, str) and value.strip() for value in values):
        raise ValueError("expected nonempty identifiers")


def signed_webhook(subscription, webhook_id, payload, *, keys, signed_at):
    """Serialize once for Standard Webhooks. Keys belong to this verified callback.

    The gateway supplies the current whsec_ secret, plus the previous key only
    during its rotation window. This function performs no network operations.
    """
    _ids(subscription, webhook_id)
    if not all(value.isascii() and value.isprintable() for value in (subscription, webhook_id)):
        raise ValueError("invalid webhook headers")
    if payload.get("type") == "verification":
        if payload.keys() != {"type", "challenge"}:
            raise ValueError("invalid verification payload")
        _ids(payload["challenge"])
    elif (payload.get("eventId") != webhook_id or payload.get("name") != EVENT
          or payload.get("data", {}).get("subscription") != subscription):
        raise ValueError("event outside subscription")
    if not 1 <= len(keys) <= 2 or type(signed_at) is not int:
        raise ValueError("expected signing time and subscription keys")
    body = json.dumps(payload, separators=(",", ":"), allow_nan=False).encode()
    if len(body) > 256 * 1024:
        raise ValueError("event too large")
    message = f"{webhook_id}.{signed_at}.".encode() + body
    signatures = []
    for key in keys:
        if not isinstance(key, str) or not key.startswith("whsec_"):
            raise ValueError("invalid signing key")
        try:
            raw = base64.b64decode(key[6:], validate=True)
        except ValueError:
            raise ValueError("invalid signing key") from None
        if not 24 <= len(raw) <= 64:
            raise ValueError("invalid signing key")
        signature = base64.b64encode(hmac.digest(raw, message, "sha256")).decode()
        signatures.append("v1," + signature)
    return body, {
        "Content-Type": "application/json", "X-MCP-Subscription-Id": subscription,
        "webhook-id": webhook_id, "webhook-timestamp": str(signed_at),
        "webhook-signature": " ".join(signatures),
    }


def verify_callback(subscription, *, keys, post):
    """Verify an echo using the gateway's address-validated, timeout-bounded POST.

    post(body, headers) is bound to the authorized destination and returns
    (HTTP status, decoded JSON). No application data is sent by this check.
    """
    challenge = secrets.token_urlsafe(32)
    body, headers = signed_webhook(
        subscription, secrets.token_hex(16), {"type": "verification", "challenge": challenge},
        keys=keys, signed_at=int(time.time()),
    )
    deadline = time.monotonic() + 10
    status, response = post(body, headers)
    echo = response.get("challenge") if isinstance(response, dict) else None
    if (time.monotonic() >= deadline or not 200 <= status < 300 or not isinstance(echo, str)
            or not echo.isascii() or not hmac.compare_digest(challenge, echo)):
        raise PermissionError("callback verification failed")


class ClaimChecks:
    """The gateway supplies the authenticated owner and current validated token scopes.

    Only its verified subscription lifecycle may call activate/deactivate. The
    producer calls event and returned_total. Only call_tool accepts model input.
    """

    def __init__(self, path, *, clock=time.time):
        self.path = path
        self.clock = clock
        with self._db() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS dot_subscription (
                    owner TEXT NOT NULL, subscription TEXT NOT NULL, expires INTEGER NOT NULL,
                    PRIMARY KEY(owner, subscription)
                );
                CREATE TABLE IF NOT EXISTS dot_sample (
                    owner TEXT NOT NULL, subscription TEXT NOT NULL, request TEXT NOT NULL,
                    claim TEXT NOT NULL UNIQUE, event_id TEXT NOT NULL UNIQUE, created INTEGER NOT NULL,
                    blue INTEGER NOT NULL, green INTEGER NOT NULL, returned INTEGER,
                    PRIMARY KEY(owner, subscription, request),
                    FOREIGN KEY(owner, subscription) REFERENCES dot_subscription ON DELETE CASCADE
                );
            """)

    @contextmanager
    def _db(self, *, write=False):
        with closing(sqlite3.connect(self.path)) as db, db:
            db.row_factory = sqlite3.Row
            db.execute("PRAGMA foreign_keys = ON")
            db.execute("BEGIN IMMEDIATE" if write else "BEGIN")
            yield db

    def activate(self, owner, subscription, expires):
        """Install or refresh a finite lease after gateway authorization and callback verification."""
        _ids(owner, subscription)
        with self._db(write=True) as db:
            now = self.clock()
            if type(expires) is not int or expires <= now:
                raise ValueError("a future lease expiry is required")
            db.execute("DELETE FROM dot_subscription WHERE owner=? AND subscription=? AND expires<=?",
                       (owner, subscription, now))
            db.execute("""INSERT INTO dot_subscription VALUES (?, ?, ?)
                          ON CONFLICT(owner, subscription) DO UPDATE SET expires=excluded.expires""",
                       (owner, subscription, expires))

    def deactivate(self, owner, subscription):
        """Retire the lease and all of its claims. Repeated unsubscribe is harmless."""
        _ids(owner, subscription)
        with self._db(write=True) as db:
            db.execute("DELETE FROM dot_subscription WHERE owner=? AND subscription=?", (owner, subscription))

    def _require_active(self, db, owner, subscription):
        _ids(owner, subscription)
        if not db.execute("SELECT 1 FROM dot_subscription WHERE owner=? AND subscription=? AND expires>?",
                          (owner, subscription, self.clock())).fetchone():
            raise PermissionError("sample unavailable")

    def event(self, owner, subscription, request):
        """Prepare one webhook body per producer request, stable across retries and restarts."""
        _ids(request)
        with self._db(write=True) as db:
            self._require_active(db, owner, subscription)
            db.execute("""INSERT INTO dot_sample VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)
                          ON CONFLICT(owner, subscription, request) DO NOTHING""",
                       (owner, subscription, request, secrets.token_urlsafe(32), secrets.token_hex(16), int(self.clock()),
                        secrets.randbelow(100), secrets.randbelow(100)))
            row = db.execute("""SELECT claim, event_id, created FROM dot_sample
                                WHERE owner=? AND subscription=? AND request=?""",
                             (owner, subscription, request)).fetchone()
        return {
            "eventId": row["event_id"], "name": EVENT,
            "timestamp": datetime.fromtimestamp(row["created"], timezone.utc).isoformat(),
            "data": {"subscription": subscription, "claim": row["claim"]}, "cursor": None,
        }

    def call_tool(self, owner, scopes: frozenset[str], name, arguments):
        if name not in (READ_TOOL, RETURN_TOOL):
            raise ValueError("unknown tool")
        returning = name == RETURN_TOOL
        scope = RETURN_SCOPE if returning else READ_SCOPE
        if not isinstance(scopes, frozenset) or scope not in scopes:
            raise PermissionError("missing tool scope")
        fields = {"subscription", "claim", "total"} if returning else {"subscription", "claim"}
        if not isinstance(arguments, dict) or arguments.keys() != fields:
            raise ValueError("unexpected tool arguments")
        subscription, claim = arguments["subscription"], arguments["claim"]
        _ids(claim)
        with self._db(write=returning) as db:
            self._require_active(db, owner, subscription)
            row = db.execute("SELECT blue, green FROM dot_sample WHERE owner=? AND subscription=? AND claim=?",
                             (owner, subscription, claim)).fetchone()
            if row is None:
                raise PermissionError("sample unavailable")
            if returning:
                total = arguments["total"]
                if type(total) is not int or total != row["blue"] + row["green"]:
                    raise ValueError("incorrect sample total")
                db.execute("""UPDATE dot_sample SET returned=?
                              WHERE owner=? AND subscription=? AND claim=? AND returned IS NULL""",
                           (total, owner, subscription, claim))
                result = {"recorded": True}
            else:
                result = {"blue": row["blue"], "green": row["green"]}
        return {"content": [{"type": "text", "text": json.dumps(result)}], "structuredContent": result}

    def returned_total(self, owner, subscription, request):
        """Read the tool return for the producer's request; pending returns are None."""
        _ids(owner, subscription, request)
        with self._db() as db:
            row = db.execute("""SELECT returned FROM dot_sample JOIN dot_subscription USING(owner, subscription)
                                WHERE owner=? AND subscription=? AND request=? AND expires>?""",
                             (owner, subscription, request, self.clock())).fetchone()
            if row is None:
                raise PermissionError("sample unavailable")
            return row["returned"]
