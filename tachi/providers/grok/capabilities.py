"""Capability inventory for Grok Bot. Programmatic status is what this connector can do."""

from __future__ import annotations

# status: app = the official client documents it
# programmatic: yes only when this connector has a sanctioned call
CAPABILITIES = (
    {
        "operation": "auth.sign_in",
        "app": "supported",
        "programmatic": "no",
        "note": "Browser sign-in on the Cursor account, Sign in with Grok, or Link Grok Account. This connector stores no session token.",
    },
    {
        "operation": "message.send",
        "app": "supported",
        "programmatic": "no",
        "note": "Desktop, mobile, Slack, and X Chat. A routine webhook starts a routine run. It does not open an arbitrary chat turn.",
    },
    {
        "operation": "message.voice",
        "app": "supported",
        "programmatic": "no",
        "note": "Dictation, voice memo, and one live voice chat. The app reconnects a short drop, then the call ends.",
    },
    {
        "operation": "attachment.add",
        "app": "supported",
        "programmatic": "no",
        "note": "Composer files and images. Pages need desktop 0.60.0+ or phone 1.14.0+ and are not on Enterprise yet.",
    },
    {
        "operation": "tools.use",
        "app": "supported",
        "programmatic": "no",
        "note": "Connectors, MCP or API calls the Bot makes, and the shared cloud computer. No inbound tool-invocation API is documented.",
    },
    {
        "operation": "task.routine_webhook",
        "app": "supported",
        "programmatic": "yes",
        "note": "POST the operator webhook. HTTP 200 means the run was accepted. It is not a Bot reply.",
    },
    {
        "operation": "approval.decide",
        "app": "supported",
        "programmatic": "no",
        "note": "Approval cards, drafts, payments, and phone-call consent stay in the app.",
    },
    {
        "operation": "turn.cancel",
        "app": "supported",
        "programmatic": "no",
        "note": "A Stop now message ends the turn and does not undo completed actions. No cancel token is documented for a webhook run.",
    },
    {
        "operation": "session.recover",
        "app": "partial",
        "programmatic": "no",
        "note": "Quit and reopen the app. Voice tries one reconnect. Recreating the cloud computer drops in-computer sign-in.",
    },
    {
        "operation": "client.drift",
        "app": "supported",
        "programmatic": "yes",
        "note": "Compare the installed desktop version with the public stable release feed. Memory drift is corrected in chat only.",
    },
    {
        "operation": "history.read",
        "app": "supported",
        "programmatic": "refused",
        "note": "In-app search exists. This connector does not read personal transcripts.",
    },
    {
        "operation": "model.chat",
        "app": "not-this-product",
        "programmatic": "refused",
        "note": "Grok Bot has no public model id. The xAI API and Grok Build are different products.",
    },
)

CONNECTOR_OPERATIONS = (
    "probe_client",
    "fetch_release",
    "describe",
    "trigger_routine",
)
