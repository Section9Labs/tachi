"""Subscription quota checkpoint. Spend is refused until one is on file."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

ALLOWED_SOURCES = frozenset({"grok-bot-settings", "operator-attestation"})
ALLOWED_BILLING = "subscription"
SPENDABLE_POOL = "available"


class QuotaBlocked(Exception):
    """A live Grok Bot operation would spend the weekly pool and must not start."""


@dataclass(frozen=True)
class QuotaCheckpoint:
    observed_at: datetime
    source: str
    billing: str
    weekly_pool: str

    def to_public_dict(self) -> dict[str, str]:
        return {
            "observed_at": _iso(self.observed_at),
            "source": self.source,
            "billing": self.billing,
            "weekly_pool": self.weekly_pool,
        }


def parse_checkpoint(payload: dict) -> QuotaCheckpoint:
    """Parse an operator checkpoint. Unknown billing or an API source never spends."""
    try:
        observed = _parse_time(str(payload["observed_at"]))
        source = str(payload["source"])
        billing = str(payload["billing"])
        pool = str(payload["weekly_pool"])
    except (KeyError, TypeError, ValueError) as exc:
        raise QuotaBlocked("quota checkpoint is incomplete") from exc
    if source not in ALLOWED_SOURCES:
        raise QuotaBlocked("quota checkpoint source is not a Grok Bot subscription reading")
    if billing != ALLOWED_BILLING:
        raise QuotaBlocked("quota checkpoint is not subscription billing")
    if pool != SPENDABLE_POOL:
        raise QuotaBlocked("weekly subscription pool is not available")
    return QuotaCheckpoint(
        observed_at=observed,
        source=source,
        billing=billing,
        weekly_pool=pool,
    )


def require_spend_allowed(
    checkpoint: QuotaCheckpoint | None,
    *,
    now: datetime,
    max_age: timedelta = timedelta(hours=12),
) -> None:
    """Block before any network call that can start Bot work."""
    if checkpoint is None:
        raise QuotaBlocked("no quota checkpoint; live Grok Bot work is stopped")
    if checkpoint.billing != ALLOWED_BILLING or checkpoint.weekly_pool != SPENDABLE_POOL:
        raise QuotaBlocked("quota checkpoint does not allow subscription spend")
    if now.tzinfo is None:
        raise QuotaBlocked("checkpoint clock must be timezone-aware")
    age = now - checkpoint.observed_at
    if age < timedelta(0) or age > max_age:
        raise QuotaBlocked("quota checkpoint is stale or in the future")


def _parse_time(value: str) -> datetime:
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    parsed = datetime.fromisoformat(text)
    if parsed.tzinfo is None:
        raise ValueError("timestamp needs a timezone")
    return parsed.astimezone(timezone.utc)


def _iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
