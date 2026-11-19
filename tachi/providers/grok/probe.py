"""Read the installed Grok Bot client and the public release feed. No credentials."""

from __future__ import annotations

import json
import plistlib
import platform
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Callable
from urllib.parse import urlparse

from tachi.providers.grok.product import DESKTOP_PLIST, RELEASE_FEED_HOST, RELEASE_FEED_TEMPLATE

Opener = Callable[[urllib.request.Request, float], bytes]


@dataclass(frozen=True)
class ClientInstall:
    present: bool
    version: str | None
    bundle_id: str | None
    url_schemes: tuple[str, ...]


@dataclass(frozen=True)
class ReleaseFeed:
    platform: str
    version: str
    commit_sha: str


def feed_platform() -> str:
    system = platform.system().lower()
    machine = platform.machine().lower()
    if system == "darwin" and machine in {"arm64", "aarch64"}:
        return "darwin-arm64"
    if system == "darwin" and machine in {"x86_64", "amd64"}:
        return "darwin-x64"
    if system == "linux" and machine in {"arm64", "aarch64"}:
        return "linux-arm64"
    if system == "linux" and machine in {"x86_64", "amd64"}:
        return "linux-x64"
    if system == "windows" and machine in {"arm64", "aarch64"}:
        return "win32-arm64-user"
    if system == "windows" and machine in {"x86_64", "amd64"}:
        return "win32-x64-user"
    return "darwin-arm64"


def read_install(path: str = DESKTOP_PLIST) -> ClientInstall:
    try:
        with open(path, "rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException):
        return ClientInstall(False, None, None, ())
    schemes: list[str] = []
    for entry in info.get("CFBundleURLTypes") or []:
        schemes.extend(entry.get("CFBundleURLSchemes") or [])
    version = info.get("CFBundleShortVersionString")
    bundle_id = info.get("CFBundleIdentifier")
    return ClientInstall(
        present=True,
        version=str(version) if version else None,
        bundle_id=str(bundle_id) if bundle_id else None,
        url_schemes=tuple(str(item) for item in schemes),
    )


def release_feed_url(feed_platform_name: str | None = None) -> str:
    name = feed_platform_name or feed_platform()
    return RELEASE_FEED_TEMPLATE.format(platform=name)


def fetch_release(
    url: str | None = None,
    *,
    opener: Opener | None = None,
    timeout: float = 20,
) -> ReleaseFeed:
    target = url or release_feed_url()
    parsed = urlparse(target)
    if parsed.scheme != "https" or parsed.hostname != RELEASE_FEED_HOST:
        raise ProbeError("release feed host is not the documented Grok Bot feed")
    raw = (opener or _urlopen)(_request(target), timeout)
    try:
        payload = json.loads(raw.decode("utf-8"))
        version = str(payload["version"])
        commit = str(payload["commitSha"])
    except (UnicodeError, json.JSONDecodeError, KeyError, TypeError) as exc:
        raise ProbeError("release feed did not return version and commitSha") from exc
    slug = parsed.path.rstrip("/").split("/")[-2]
    return ReleaseFeed(platform=slug, version=version, commit_sha=commit)


def version_drift(installed: str | None, published: str | None) -> str:
    if not installed or not published:
        return "unknown"
    left = _parts(installed)
    right = _parts(published)
    if left == right:
        return "match"
    if left < right:
        return "installed_behind_feed"
    return "installed_ahead_of_feed"


def _parts(value: str) -> tuple[int, ...]:
    numbers: list[int] = []
    for piece in value.split("."):
        digits = ""
        for char in piece:
            if char.isdigit():
                digits += char
            else:
                break
        numbers.append(int(digits) if digits else 0)
    return tuple(numbers)


def _request(url: str) -> urllib.request.Request:
    return urllib.request.Request(url, headers={"Accept": "application/json"}, method="GET")


def _urlopen(request: urllib.request.Request, timeout: float) -> bytes:
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read()
    except urllib.error.URLError as exc:
        raise ProbeError("release feed request failed") from exc


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


class ProbeError(Exception):
    pass
