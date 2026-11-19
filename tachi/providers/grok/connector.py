"""Independent Grok Bot connector.

The only sanctioned programmatic start is a routine webhook created in the
desktop app. Chat completions, the Grok Build CLI, and copied app tokens are
not accepted. The webhook secret is bound to the exact origin and path copied
from that routine. Redirects are not followed. Response bodies are discarded.
HTTP 200 accepts the run and is not a Bot reply.
"""

from __future__ import annotations

import ipaddress
import json
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Callable
from urllib.parse import unquote, urlparse

from tachi.providers.grok.capabilities import CAPABILITIES, CONNECTOR_OPERATIONS
from tachi.providers.grok.probe import (
    ClientInstall,
    ReleaseFeed,
    fetch_release,
    read_install,
    version_drift,
)
from tachi.providers.grok.product import (
    BILLED_API_HOSTS,
    CONTRACT_STATUS,
    DOCS_REVIEWED,
    LOCAL_SURFACE,
    PRODUCT_ID,
    PRODUCT_NAME,
    RELEASE_FEED_HOST,
)
from tachi.providers.grok.quota import QuotaCheckpoint

Transport = Callable[[urllib.request.Request, float], "HttpResult"]
_LOOPBACK_NAMES = frozenset({"localhost"})
_REFUSED_HOSTS = BILLED_API_HOSTS | frozenset({RELEASE_FEED_HOST})


@dataclass(frozen=True)
class HttpResult:
    """Status only. The response body is not retained and cannot complete a run."""

    status: int


@dataclass(frozen=True)
class RoutineAcceptance:
    accepted: bool
    completed: bool
    status: int


class ConnectorError(Exception):
    pass


class NotSent(ConnectorError):
    """The routine call was refused before any request left this process."""


class SubmissionUnobserved(ConnectorError):
    """The POST was attempted and the acceptance result was not observed."""


class RoutineRejected(ConnectorError):
    def __init__(self, status: int) -> None:
        self.status = status
        # The routines guide says any response other than 200 means a run did not start.
        super().__init__(f"routine endpoint returned HTTP {status}")


@dataclass(frozen=True)
class WebhookGrant:
    """Secret frozen to one provider-issued origin and path.

    ``trigger_routine`` accepts this grant and no URL. A later call cannot move
    the secret to another host, port, or path.
    """

    scheme: str
    host: str
    port: int
    path: str
    secret: str = field(repr=False)

    def destination(self) -> str:
        return _destination(self.scheme, self.host, self.port, self.path)


def describe() -> dict:
    return {
        "provider_id": PRODUCT_ID,
        "product": PRODUCT_NAME,
        "docs_reviewed": DOCS_REVIEWED,
        "contract": CONTRACT_STATUS,
        "surface": LOCAL_SURFACE,
        "operations": list(CONNECTOR_OPERATIONS),
        "capabilities": list(CAPABILITIES),
        "rejects": [
            "xai-api",
            "grok-build",
            "grok-chat",
            "copied-app-credentials",
            "personal-history",
        ],
    }


def probe_client(path: str | None = None) -> ClientInstall:
    if path is None:
        return read_install()
    return read_install(path)


def published_release(url: str | None = None, *, opener=None) -> ReleaseFeed:
    return fetch_release(url, opener=opener)


def bind_webhook(url: str, secret: str, *, allow_loopback: bool = False) -> WebhookGrant:
    """Freeze a secret to the exact origin and path copied from the desktop routine."""
    if not isinstance(url, str) or not isinstance(secret, str):
        raise NotSent("routine grant is incomplete")
    if not secret or secret.strip() != secret or any(char.isspace() for char in secret):
        raise NotSent("routine secret is missing")
    if any(char.isspace() for char in url):
        raise NotSent("routine URL must be the issued https destination")
    parsed = urlparse(url)
    scheme = parsed.scheme.lower()
    if (
        parsed.query
        or parsed.fragment
        or parsed.username is not None
        or parsed.password is not None
        or "?" in url
        or "#" in url
    ):
        raise NotSent("routine URL must not carry credentials or a query")
    host = parsed.hostname
    if not host or host.endswith("."):
        raise NotSent("routine URL must be the issued https destination")
    host = host.lower()
    if host in _REFUSED_HOSTS:
        raise NotSent("refusing a non-webhook host")
    if _ip_literal(host) is not None:
        if not (allow_loopback and scheme == "http" and host == "127.0.0.1"):
            raise NotSent("routine URL must be the issued https destination")
    loopback_name = host in _LOOPBACK_NAMES
    if scheme == "https":
        if loopback_name or _ip_literal(host) is not None:
            raise NotSent("routine URL must be the issued https destination")
    elif not (allow_loopback and scheme == "http" and (host == "127.0.0.1" or loopback_name)):
        raise NotSent("routine URL must be https")
    path = parsed.path
    if not _exact_webhook_path(path):
        raise NotSent("routine path must be the issued webhook path")
    try:
        parsed_port = parsed.port
    except ValueError as exc:
        raise NotSent("routine URL must be the issued https destination") from exc
    if parsed_port is None:
        port = 443 if scheme == "https" else 80
    elif 1 <= parsed_port <= 65535:
        port = parsed_port
    else:
        raise NotSent("routine URL must be the issued https destination")
    return WebhookGrant(scheme, host, port, path, secret)


def trigger_routine(
    grant: WebhookGrant,
    body: dict | None = None,
    *,
    transport: Transport | None = None,
    timeout: float = 30,
) -> RoutineAcceptance:
    """Start a routine. HTTP 200 means the run was accepted, not that the Bot replied.

    The grant is the destination. There is no URL argument. An observed status
    other than 200, including 5xx, is the routines guide's rejection: any other
    response means a run did not start. A timeout is not a response.
    """
    if not isinstance(grant, WebhookGrant):
        raise NotSent("routine credentials require a bound webhook grant")
    issued = _destination(grant.scheme, grant.host, grant.port, grant.path)
    bound = bind_webhook(issued, grant.secret, allow_loopback=grant.scheme == "http")
    if (bound.scheme, bound.host, bound.port, bound.path, bound.secret) != (
        grant.scheme,
        grant.host,
        grant.port,
        grant.path,
        grant.secret,
    ):
        raise NotSent("routine grant does not match its destination")
    payload = json.dumps(body or {}).encode("utf-8")
    request = urllib.request.Request(
        bound.destination(),
        data=payload,
        method="POST",
        headers={
            "Authorization": f"Bearer {bound.secret}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    result = (transport or _transport)(request, timeout)
    if result.status != 200:
        raise RoutineRejected(result.status)
    return RoutineAcceptance(accepted=True, completed=False, status=200)


def evidence(
    install: ClientInstall,
    release: ReleaseFeed | None,
    *,
    observed_at: datetime,
    checkpoint: QuotaCheckpoint | None,
    feed_error: str | None = None,
) -> dict:
    """Sanitized proof. Omits account ids, tokens, paths, and download URLs."""
    record = {
        "observed_at": _iso(observed_at),
        "provider_id": PRODUCT_ID,
        "product": PRODUCT_NAME,
        "docs_reviewed": DOCS_REVIEWED,
        "installed_client": {
            "present": install.present,
            "version": install.version,
            "bundle_id": install.bundle_id,
            "url_schemes": list(install.url_schemes),
        },
        "release_feed": None
        if release is None
        else {
            "platform": release.platform,
            "version": release.version,
            "commit_sha": release.commit_sha,
        },
        "client_drift": version_drift(
            install.version, None if release is None else release.version
        ),
        "feed_error": feed_error,
        "quota_checkpoint": None if checkpoint is None else checkpoint.to_public_dict(),
        "live_routine": "not_sent",
        "advertised_capabilities": [],
        "access_dependency": _access_dependency(install, checkpoint),
    }
    assert_sanitized(record)
    return record


def _iso(value: datetime) -> str:
    if value.tzinfo is None:
        raise ConnectorError("observed_at needs a timezone")
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def assert_sanitized(record: dict) -> None:
    text = json.dumps(record)
    lowered = text.lower()
    banned = ("bearer ", "authorization", "sk-", "xai-", "/users/", "api_key", "@")
    for token in banned:
        if token in lowered:
            raise ConnectorError("evidence contains a private identifier")


def _access_dependency(install: ClientInstall, checkpoint: QuotaCheckpoint | None) -> str:
    if not install.present:
        return "Grok Bot desktop app is not installed. Sign in through the app. No API key substitutes."
    if checkpoint is None:
        return (
            "Installed client can be probed. This engineering record did not start a routine. "
            "A user who already has an authorized webhook does not also need a quota checkpoint. "
            "HTTP 200 means the routine was accepted and is not a Bot reply. "
            "The result stays in the Bot chat and in phone Run history, and this connector does not read either."
        )
    return (
        "An engineering quota note is on file for shared-account spend. "
        "A user who already has an authorized webhook does not also need a quota checkpoint. "
        "The webhook URL and secret stay with the operator and are not stored here."
    )


def _ip_literal(host: str) -> ipaddress.IPv4Address | ipaddress.IPv6Address | None:
    try:
        return ipaddress.ip_address(host)
    except ValueError:
        return None


def _exact_webhook_path(path: str) -> bool:
    if not path.startswith("/") or path == "/":
        return False
    check = path[:-1] if path.endswith("/") else path
    parts = [unquote(part) for part in check.split("/")]
    for part in parts[1:]:
        if part in {"", ".", ".."} or "/" in part or "\\" in part or "\x00" in part:
            return False
    return True


def _destination(scheme: str, host: str, port: int, path: str) -> str:
    if (scheme == "https" and port == 443) or (scheme == "http" and port == 80):
        netloc = host
    else:
        netloc = f"{host}:{port}"
    return f"{scheme}://{netloc}{path}"


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Keep the webhook secret on the URL the operator configured."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, msg, headers, fp)

    def http_error_302(self, req, fp, code, msg, headers):
        raise urllib.error.HTTPError(req.full_url, code, msg, headers, fp)

    http_error_301 = http_error_303 = http_error_307 = http_error_308 = http_error_302


def _opener() -> urllib.request.OpenerDirector:
    # No environment proxy, and no redirect. The secret goes to one URL.
    return urllib.request.build_opener(_NoRedirect(), urllib.request.ProxyHandler({}))


def _transport(request: urllib.request.Request, timeout: float) -> HttpResult:
    try:
        response = _opener().open(request, timeout=timeout)
    except urllib.error.HTTPError as exc:
        exc.close()
        return HttpResult(status=exc.code)
    except (urllib.error.URLError, TimeoutError) as exc:
        raise SubmissionUnobserved("routine submission result was not observed") from exc
    try:
        return HttpResult(status=response.status)
    finally:
        response.close()


# Imported for callers that should fail closed on a substitute name.
__all__ = [
    "RoutineAcceptance",
    "WebhookGrant",
    "bind_webhook",
    "describe",
    "evidence",
    "probe_client",
    "published_release",
    "trigger_routine",
]
