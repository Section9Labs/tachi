"""Identity of the Grok Bot product and the clients that are not it."""

from __future__ import annotations

PRODUCT_ID = "grok-bot"
PRODUCT_NAME = "Grok Bot"
VENDOR = "SpaceXAI"

# Runtime published adapter contract v1. This id is the provider field on AdapterIdentity.
CONTRACT_STATUS = "v1"
LOCAL_SURFACE = "tachi.providers.grok"

# Observed from the installed desktop app's Info.plist on 2026-11-19.
# These identify the app bundle. They are not account credentials.
BUNDLE_ID = "com.anysphere.sand"
URL_SCHEMES = ("grokbot", "sand")
DESKTOP_PLIST = "/Applications/Grok Bot.app/Contents/Info.plist"

# Documented stable release feed. Platform segment is chosen by the probe.
# https://docs.x.ai/grok-bot/deployment
RELEASE_FEED_TEMPLATE = "https://api2.cursor.sh/updates/api/download/stable/{platform}/sand"
RELEASE_FEED_HOST = "api2.cursor.sh"

# Token-billed inference. Never a stand-in for a Grok Bot session.
BILLED_API_HOSTS = frozenset({"api.x.ai", "mtls.api.x.ai"})

# Other products that must not be reported as Grok Bot.
REJECTED_SUBSTITUTES = frozenset(
    {
        "grok-build",
        "grok-cli",
        "xai-api",
        "grok-chat",
        "claude-code",
        "claude-duet",
        "instinct",
        "zapia",
    }
)

SANCTIONED_AUTH = (
    "cursor-browser-sso",
    "sign-in-with-grok",
    "link-grok-account",
)

DOCS_REVIEWED = "2026-11-19"


def reject_substitute(name: str) -> None:
    """Raise if a caller tries to satisfy a Grok Bot operation with another product."""
    key = name.strip().lower()
    if key in REJECTED_SUBSTITUTES or key == PRODUCT_ID:
        if key != PRODUCT_ID:
            raise SubstituteRejected(key)
        return
    raise SubstituteRejected(key)


class SubstituteRejected(Exception):
    def __init__(self, name: str) -> None:
        self.name = name
        super().__init__(f"{name} is not a Grok Bot session")
