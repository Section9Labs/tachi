"""Grok Bot connector. Not the xAI API and not Grok Build."""

from tachi.providers.grok.connector import (
    WebhookGrant,
    bind_webhook,
    describe,
    evidence,
    probe_client,
    published_release,
    trigger_routine,
)
from tachi.providers.grok.product import PRODUCT_ID, SubstituteRejected, reject_substitute

__all__ = [
    "PRODUCT_ID",
    "SubstituteRejected",
    "WebhookGrant",
    "bind_webhook",
    "describe",
    "evidence",
    "probe_client",
    "published_release",
    "reject_substitute",
    "trigger_routine",
]
