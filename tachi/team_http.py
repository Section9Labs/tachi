"""Authenticated HTTP surface for the explicitly enabled reference team service."""

import re
from http import HTTPStatus

from .runtime.reference_service import ALIASES, RUN, Conflict


ROOT = "/v1/reference-teams"
_ID = re.compile(r"[a-zA-Z0-9_-]{1,80}")


def matches(path):
    return path == ROOT or path.startswith(ROOT + "/")


def identifier(value):
    if not isinstance(value, str) or not _ID.fullmatch(value):
        raise ValueError("invalid ID")
    return value


def fields(data, required, optional=()):
    if not required <= data.keys() or data.keys() - required - set(optional):
        raise ValueError("invalid fields")


def turn_limit(value):
    if type(value) is not int or not 1 <= value <= 1000:
        raise ValueError("invalid turn limit")
    return value


def handle(handler):
    service = handler.reference_teams
    if service is None:
        handler.write_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
        return
    principal = handler.authenticated_client()
    if principal is None:
        return
    match = re.fullmatch(ROOT + r"(?:/([a-f0-9]{32})(?:/(messages|run))?)?", handler.path)
    if match is None:
        handler.write_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
        return
    team, section = match.groups()
    post = handler.command == "POST"
    if (post and team and not section) or (not post and section == "run"):
        handler.write_json(HTTPStatus.METHOD_NOT_ALLOWED, {"error": "method_not_allowed"})
        return
    data = handler.read_json(16384) if post else {}
    if data is None:
        return
    try:
        with service.queue() as q:
            if team is None:
                if post:
                    fields(data, {"creationID", "turnLimit"})
                    result = service.create(q, principal, identifier(data["creationID"]), turn_limit(data["turnLimit"]))
                else:
                    result = {"teams": service.list_teams(q, principal)}
            elif section == "messages" and post:
                service.require_team(q, principal, team, "messages:send")
                result = post_message(q, principal, team, data)
                service.wake()
            elif section == "run":
                service.require_team(q, principal, team, "teams:manage")
                fields(data, {"state"}, {"turnLimit"})
                state = data["state"]
                if state not in ("running", "paused", "completed", "cancelled"):
                    raise ValueError("invalid state")
                limit = turn_limit(data["turnLimit"]) if "turnLimit" in data else None
                try:
                    q.intervene(team, principal, RUN, state, turn_limit=limit)
                except ValueError as exc:
                    raise Conflict() from exc
                result = service.summary(q, team)
                service.wake()
            else:
                service.require_team(q, principal, team, "sessions:read")
                result = ({"messages": service.messages(q, principal, team)} if section == "messages"
                          else service.summary(q, team))
    except KeyError:
        handler.write_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
    except PermissionError:
        handler.write_json(HTTPStatus.FORBIDDEN, {"error": "forbidden"})
    except Conflict:
        handler.write_json(HTTPStatus.CONFLICT, {"error": "conflict"})
    except ValueError:
        handler.write_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_request"})
    else:
        handler.write_json(HTTPStatus.OK, result)


def post_message(q, principal, team, data):
    fields(data, {"messageID", "text", "audience"}, {"mentions", "replyTo"})
    message = identifier(data["messageID"])
    text, audience = data["text"], data["audience"]
    mentions = data.get("mentions", [])
    if (not isinstance(text, str) or not text.strip() or len(text) > 4000 or
        audience not in ("room", *ALIASES) or not isinstance(mentions, list) or
        any(item not in ALIASES for item in mentions) or len(set(mentions)) != len(mentions) or
        (mentions and audience != "room")):
        raise ValueError("invalid message")
    reply = data.get("replyTo")
    if reply is not None:
        identifier(reply)
    try:
        q.post(team, principal, RUN, message, {"text": text},
               direct_to=None if audience == "room" else "assistant:" + audience,
               mentions=tuple("assistant:" + alias for alias in mentions), reply_to=reply)
    except ValueError as exc:
        raise Conflict() from exc
    return {"messageID": message}
