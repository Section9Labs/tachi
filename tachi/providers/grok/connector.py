"""Independent Grok Bot connector.

The only sanctioned programmatic start is a routine webhook created in the
desktop app. Chat completions, the Grok Build CLI, and copied app tokens are
not accepted. A subscription quota checkpoint is required before that webhook.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Callable
from urllib.parse import urlparse

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
)
from tachi.providers.grok.quota import QuotaCheckpoint, require_spend_allowed

Transport = Callable[[urllib.request.Request, float], "HttpResult"]


@dataclass(frozen=True)
class HttpResult:
    status: int
    body: bytes


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
        super().__init__(f"routine endpoint returned HTTP {status}")


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


def trigger_routine(
    url: str,
    bearer: str,
    body: dict | None,
    checkpoint: QuotaCheckpoint | None,
    *,
    now: datetime,
    transport: Transport | None = None,
    timeout: float = 30,
    allow_loopback: bool = False,
) -> RoutineAcceptance:
    """Start a routine. HTTP 200 means the run was accepted, not that it finished."""
    require_spend_allowed(checkpoint, now=now)
    _validate_webhook(url, bearer, allow_loopback=allow_loopback)
    payload = json.dumps(body or {}).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=payload,
        method="POST",
        headers={
            "Authorization": f"Bearer {bearer}",
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
            "Installed client can be probed, but no subscription quota checkpoint is on file. "
            "A native routine run also needs the webhook URL and secret created in that Bot. "
            "Those values stay with the operator and are not stored here."
        )
    return "Quota checkpoint is present. A routine webhook still needs an operator-held URL and secret."


def _validate_webhook(url: str, bearer: str, *, allow_loopback: bool) -> None:
    if not bearer or bearer.strip() != bearer or any(char.isspace() for char in bearer):
        raise NotSent("routine secret is missing")
    parsed = urlparse(url)
    host = (parsed.hostname or "").lower()
    if host in BILLED_API_HOSTS:
        raise NotSent("refusing the billed xAI API")
    if parsed.username or parsed.password or "bearer" in (parsed.query or "").lower():
        raise NotSent("routine URL must not carry credentials")
    loopback = host in {"127.0.0.1", "localhost"}
    if parsed.scheme == "https" and not loopback:
        return
    if allow_loopback and parsed.scheme == "http" and loopback:
        return
    raise NotSent("routine URL must be https")


def _transport(request: urllib.request.Request, timeout: float) -> HttpResult:
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return HttpResult(status=response.status, body=response.read())
    except urllib.error.HTTPError as exc:
        return HttpResult(status=exc.code, body=exc.read())
    except urllib.error.URLError as exc:
        raise SubmissionUnobserved("routine submission result was not observed") from exc


# Imported for callers that should fail closed on a substitute name.
__all__ = [
    "RoutineAcceptance",
    "describe",
    "evidence",
    "probe_client",
    "published_release",
    "trigger_routine",
]
