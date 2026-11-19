"""Fixture proof for the Grok Bot connector. No live spend and no billed API."""

from __future__ import annotations

import json
import threading
import unittest
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from tachi.providers.grok.adapter import GrokBotAdapter
from tachi.providers.grok.connector import (
    ConnectorError,
    HttpResult,
    RoutineRejected,
    SubmissionUnobserved,
    evidence,
    probe_client,
    published_release,
    trigger_routine,
)
from tachi.providers.grok.probe import ProbeError, version_drift
from tachi.providers.grok.product import PRODUCT_ID, SubstituteRejected, reject_substitute
from tachi.providers.grok.quota import QuotaBlocked, QuotaCheckpoint, parse_checkpoint
from tachi.runtime import (
    AdapterIdentity,
    AdapterRegistry,
    Capability,
    DispatchRequest,
    DispatchUncertain,
    EventKind,
    UnsupportedCapability,
)

ROOT = Path(__file__).resolve().parents[1]
PLIST = ROOT / "tests" / "fixtures" / "grok" / "Info.plist"
FEED = ROOT / "tests" / "fixtures" / "grok" / "release_feed.json"
NOW = datetime(2026, 11, 19, 2, 30, tzinfo=timezone.utc)


def _checkpoint(**overrides) -> QuotaCheckpoint:
    payload = {
        "observed_at": "2026-11-19T02:00:00Z",
        "source": "grok-bot-settings",
        "billing": "subscription",
        "weekly_pool": "available",
    }
    payload.update(overrides)
    return parse_checkpoint(payload)


class ProductTests(unittest.TestCase):
    def test_product_id_is_grok_bot(self) -> None:
        self.assertEqual(PRODUCT_ID, "grok-bot")
        reject_substitute("grok-bot")

    def test_substitutes_are_rejected(self) -> None:
        for name in ("grok-build", "xai-api", "grok-chat", "claude-code"):
            with self.assertRaises(SubstituteRejected):
                reject_substitute(name)


class ProbeTests(unittest.TestCase):
    def test_fixture_plist(self) -> None:
        install = probe_client(str(PLIST))
        self.assertTrue(install.present)
        self.assertEqual(install.version, "0.1.0")
        self.assertEqual(install.bundle_id, "com.example.grokbot.fixture")
        self.assertEqual(install.url_schemes, ("grokbot", "sand"))

    def test_missing_plist(self) -> None:
        install = probe_client(str(ROOT / "tests" / "fixtures" / "grok" / "missing.plist"))
        self.assertFalse(install.present)

    def test_release_feed_fixture_drops_download_url(self) -> None:
        raw = FEED.read_bytes()

        def opener(request: urllib.request.Request, timeout: float) -> bytes:
            self.assertEqual(request.get_method(), "GET")
            self.assertIn(b"api2.cursor.sh", request.full_url.encode())
            return raw

        release = published_release(
            "https://api2.cursor.sh/updates/api/download/stable/darwin-arm64/sand",
            opener=opener,
        )
        self.assertEqual(release.platform, "darwin-arm64")
        self.assertEqual(release.version, "1.2.3")
        self.assertEqual(release.commit_sha, "a5927fa2ba82336a29f9343babd28b4c903abbb2")

    def test_release_feed_rejects_api_host(self) -> None:
        with self.assertRaises(ProbeError):
            published_release("https://api.x.ai/v1/models", opener=lambda *_: b"{}")

    def test_version_drift(self) -> None:
        self.assertEqual(version_drift("0.78.1", "1.2.3"), "installed_behind_feed")
        self.assertEqual(version_drift("1.2.3", "1.2.3"), "match")
        self.assertEqual(version_drift(None, "1.2.3"), "unknown")


class QuotaTests(unittest.TestCase):
    def test_api_billing_and_grok_build_cannot_checkpoint(self) -> None:
        with self.assertRaises(QuotaBlocked):
            parse_checkpoint(
                {
                    "observed_at": "2026-11-19T02:00:00Z",
                    "source": "grok-build",
                    "billing": "subscription",
                    "weekly_pool": "available",
                }
            )
        with self.assertRaises(QuotaBlocked):
            parse_checkpoint(
                {
                    "observed_at": "2026-11-19T02:00:00Z",
                    "source": "grok-bot-settings",
                    "billing": "api",
                    "weekly_pool": "available",
                }
            )

    def test_stale_checkpoint_blocks_before_the_network(self) -> None:
        called = {"n": 0}

        def transport(request, timeout):
            called["n"] += 1
            return HttpResult(200, b"")

        old = QuotaCheckpoint(
            observed_at=NOW - timedelta(hours=13),
            source="grok-bot-settings",
            billing="subscription",
            weekly_pool="available",
        )
        with self.assertRaises(QuotaBlocked):
            trigger_routine(
                "https://example.invalid/hook",
                "test-secret",
                {"task": "pong"},
                old,
                now=NOW,
                transport=transport,
            )
        self.assertEqual(called["n"], 0)

        with self.assertRaises(QuotaBlocked):
            trigger_routine(
                "https://example.invalid/hook",
                "test-secret",
                {"task": "pong"},
                None,
                now=NOW,
                transport=transport,
            )
        self.assertEqual(called["n"], 0)


class RoutineTests(unittest.TestCase):
    def test_billed_api_is_refused(self) -> None:
        with self.assertRaises(ConnectorError):
            trigger_routine(
                "https://api.x.ai/v1/responses",
                "test-secret",
                {"task": "pong"},
                _checkpoint(),
                now=NOW,
                transport=lambda *_: HttpResult(200, b""),
            )

    def test_http_200_is_accepted_and_not_complete(self) -> None:
        seen = {}

        def transport(request: urllib.request.Request, timeout: float) -> HttpResult:
            seen["auth"] = request.get_header("Authorization")
            seen["body"] = json.loads(request.data.decode())
            return HttpResult(200, b"")

        result = trigger_routine(
            "https://hooks.example.invalid/routine",
            "test-secret",
            {"task": "Reply with the single word pong."},
            _checkpoint(),
            now=NOW,
            transport=transport,
        )
        self.assertTrue(result.accepted)
        self.assertFalse(result.completed)
        self.assertEqual(seen["auth"], "Bearer test-secret")
        self.assertEqual(seen["body"]["task"], "Reply with the single word pong.")

    def test_non_200_hides_the_bearer(self) -> None:
        def transport(request, timeout):
            return HttpResult(401, b"no")

        with self.assertRaises(RoutineRejected) as caught:
            trigger_routine(
                "https://hooks.example.invalid/routine",
                "test-secret",
                None,
                _checkpoint(),
                now=NOW,
                transport=transport,
            )
        self.assertNotIn("test-secret", str(caught.exception))
        self.assertEqual(caught.exception.status, 401)

    def test_loopback_wire_shape(self) -> None:
        received = {}

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:
                length = int(self.headers.get("Content-Length", "0"))
                received["auth"] = self.headers.get("Authorization")
                received["body"] = self.rfile.read(length)
                self.send_response(200)
                self.end_headers()

            def log_message(self, fmt: str, *args) -> None:
                return

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            port = server.server_address[1]
            result = trigger_routine(
                f"http://127.0.0.1:{port}/routine",
                "loopback-secret",
                {"task": "synthetic pong"},
                _checkpoint(),
                now=NOW,
                allow_loopback=True,
            )
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)
        self.assertTrue(result.accepted)
        self.assertFalse(result.completed)
        self.assertEqual(received["auth"], "Bearer loopback-secret")
        self.assertEqual(json.loads(received["body"])["task"], "synthetic pong")


class AdapterTests(unittest.TestCase):
    def _identity(self) -> AdapterIdentity:
        return AdapterIdentity("grok-bot", "synthetic-account", "synthetic-bot")

    def _request(self, identity: AdapterIdentity, capability=Capability.TASK) -> DispatchRequest:
        return DispatchRequest(
            identity,
            "synthetic-session",
            "synthetic-request",
            capability,
            {"task": "Reply with the single word pong."},
        )

    def test_unconfigured_adapter_advertises_no_v1_capability(self) -> None:
        identity = self._identity()
        adapter = GrokBotAdapter(identity)
        registry = AdapterRegistry()
        registry.register(adapter)
        self.assertEqual(adapter.capabilities, frozenset())
        with self.assertRaises(UnsupportedCapability):
            registry.dispatch(self._request(identity))

    def test_other_provider_identity_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            GrokBotAdapter(AdapterIdentity("grok-build", "synthetic-account", "synthetic-bot"))

    def test_task_fixture_is_accepted_not_completed(self) -> None:
        identity = self._identity()
        seen = {}

        def transport(request: urllib.request.Request, timeout: float) -> HttpResult:
            seen["body"] = json.loads(request.data.decode())
            return HttpResult(200, b"")

        adapter = GrokBotAdapter(
            identity,
            webhook_url="https://hooks.example.invalid/routine",
            webhook_secret="synthetic-secret",
            checkpoint=_checkpoint(),
            transport=transport,
            clock=lambda: NOW,
        )
        registry = AdapterRegistry()
        registry.register(adapter)
        request = self._request(identity)
        events = registry.dispatch(request)
        self.assertEqual(registry.capabilities(identity), frozenset({Capability.TASK}))
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0].kind, EventKind.ACCEPTED)
        self.assertIs(events[0].identity, identity)
        self.assertEqual(events[0].session_id, request.session_id)
        self.assertEqual(events[0].request_id, request.request_id)
        self.assertEqual(
            events[0].payload,
            {"accepted": True, "completed": False, "native_session_observed": False},
        )
        self.assertNotIn("synthetic-secret", json.dumps(events[0].payload))
        self.assertEqual(seen["body"]["task"], "Reply with the single word pong.")
        with self.assertRaises(UnsupportedCapability):
            registry.dispatch(self._request(identity, Capability.MESSAGE))

    def test_missing_quota_does_not_send(self) -> None:
        identity = self._identity()
        called = {"n": 0}

        def transport(request, timeout):
            called["n"] += 1
            return HttpResult(200, b"")

        adapter = GrokBotAdapter(
            identity,
            webhook_url="https://hooks.example.invalid/routine",
            webhook_secret="synthetic-secret",
            checkpoint=None,
            transport=transport,
            clock=lambda: NOW,
        )
        events = adapter.dispatch(self._request(identity))
        self.assertEqual(events[0].kind, EventKind.FAILED)
        self.assertEqual(events[0].payload["reason"], "quota_checkpoint_required")
        self.assertEqual(called["n"], 0)

    def test_billed_host_is_a_local_failure(self) -> None:
        identity = self._identity()
        adapter = GrokBotAdapter(
            identity,
            webhook_url="https://api.x.ai/v1/responses",
            webhook_secret="synthetic-secret",
            checkpoint=_checkpoint(),
            transport=lambda *_: HttpResult(200, b""),
            clock=lambda: NOW,
        )
        events = adapter.dispatch(self._request(identity))
        self.assertEqual(events[0].kind, EventKind.FAILED)
        self.assertEqual(events[0].payload["reason"], "not_sent")

    def test_unobserved_submission_stays_uncertain(self) -> None:
        identity = self._identity()

        calls = {"n": 0}

        def transport(request, timeout):
            calls["n"] += 1
            raise SubmissionUnobserved("routine submission result was not observed")

        adapter = GrokBotAdapter(
            identity,
            webhook_url="https://hooks.example.invalid/routine",
            webhook_secret="synthetic-secret",
            checkpoint=_checkpoint(),
            transport=transport,
            clock=lambda: NOW,
        )
        registry = AdapterRegistry()
        registry.register(adapter)
        with self.assertRaises(DispatchUncertain):
            registry.dispatch(self._request(identity))
        self.assertEqual(calls["n"], 1)


class EvidenceTests(unittest.TestCase):
    def test_evidence_omits_secrets_and_marks_routine_unsent(self) -> None:
        install = probe_client(str(PLIST))
        release = published_release(
            "https://api2.cursor.sh/updates/api/download/stable/darwin-arm64/sand",
            opener=lambda *_: FEED.read_bytes(),
        )
        record = evidence(install, release, observed_at=NOW, checkpoint=None)
        text = json.dumps(record)
        self.assertNotIn("downloadUrl", text)
        self.assertNotIn("unused", text)
        self.assertEqual(record["live_routine"], "not_sent")
        self.assertEqual(record["advertised_capabilities"], [])
        self.assertEqual(record["client_drift"], "installed_behind_feed")
        self.assertIn("quota checkpoint", record["access_dependency"])
        self.assertIsNone(record["quota_checkpoint"])

    def test_sanitizer_rejects_an_email(self) -> None:
        install = probe_client(str(PLIST))
        install = type(install)(True, "0.1.0", "person@example.com", ())
        with self.assertRaises(ConnectorError):
            evidence(install, None, observed_at=NOW, checkpoint=None)


if __name__ == "__main__":
    unittest.main()
