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
from tachi.providers.grok.quota import (
    QuotaBlocked,
    QuotaCheckpoint,
    parse_checkpoint,
    require_spend_allowed,
)
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

    def test_stale_or_missing_checkpoint_blocks_engineering_spend_only(self) -> None:
        old = QuotaCheckpoint(
            observed_at=NOW - timedelta(hours=13),
            source="grok-bot-settings",
            billing="subscription",
            weekly_pool="available",
        )
        with self.assertRaises(QuotaBlocked):
            require_spend_allowed(old, now=NOW)
        with self.assertRaises(QuotaBlocked):
            require_spend_allowed(None, now=NOW)


class RoutineTests(unittest.TestCase):
    def test_billed_api_is_refused(self) -> None:
        with self.assertRaises(ConnectorError):
            trigger_routine(
                "https://api.x.ai/v1/responses",
                "test-secret",
                {"task": "pong"},
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

    def test_redirect_keeps_the_secret_on_the_configured_url(self) -> None:
        hits = {"a": 0, "b": 0, "a_auth": None, "b_auth": None}
        target = {"location": ""}

        class Landing(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                hits["b"] += 1
                hits["b_auth"] = self.headers.get("Authorization")
                self.send_response(200)
                self.end_headers()

            def do_POST(self) -> None:
                self.do_GET()

            def log_message(self, fmt: str, *args) -> None:
                return

        class Redirecting(BaseHTTPRequestHandler):
            def do_POST(self) -> None:
                hits["a"] += 1
                length = int(self.headers.get("Content-Length", "0"))
                self.rfile.read(length)
                hits["a_auth"] = self.headers.get("Authorization")
                self.send_response(302)
                self.send_header("Location", target["location"])
                self.end_headers()

            def log_message(self, fmt: str, *args) -> None:
                return

        landing_server = ThreadingHTTPServer(("127.0.0.1", 0), Landing)
        target["location"] = f"http://127.0.0.1:{landing_server.server_address[1]}/landed"
        redirect_server = ThreadingHTTPServer(("127.0.0.1", 0), Redirecting)
        threads = []
        for server in (landing_server, redirect_server):
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            threads.append(thread)
        try:
            port = redirect_server.server_address[1]
            with self.assertRaises(RoutineRejected) as caught:
                trigger_routine(
                    f"http://127.0.0.1:{port}/routine",
                    "loopback-secret",
                    {"task": "synthetic pong"},
                    allow_loopback=True,
                )
        finally:
            landing_server.shutdown()
            redirect_server.shutdown()
            landing_server.server_close()
            redirect_server.server_close()
            for thread in threads:
                thread.join(timeout=2)
        self.assertEqual(caught.exception.status, 302)
        self.assertNotIn("loopback-secret", str(caught.exception))
        self.assertEqual(hits["a"], 1)
        self.assertEqual(hits["a_auth"], "Bearer loopback-secret")
        self.assertEqual(hits["b"], 0)
        self.assertIsNone(hits["b_auth"])

    def test_authorized_webhook_sends_without_a_quota_checkpoint(self) -> None:
        called = {"n": 0}

        def transport(request, timeout):
            called["n"] += 1
            return HttpResult(200, b"")

        result = trigger_routine(
            "https://hooks.example.invalid/routine",
            "test-secret",
            {"task": "pong"},
            transport=transport,
        )
        self.assertEqual(called["n"], 1)
        self.assertTrue(result.accepted)
        self.assertFalse(result.completed)


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
            transport=transport,
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
            {
                "routine_accepted": True,
                "native_reply": False,
                "native_session_observed": False,
            },
        )
        self.assertNotEqual(events[0].kind, EventKind.COMPLETED)
        self.assertNotIn("synthetic-secret", json.dumps(events[0].payload))
        self.assertEqual(seen["body"]["task"], "Reply with the single word pong.")
        with self.assertRaises(UnsupportedCapability):
            registry.dispatch(self._request(identity, Capability.MESSAGE))

    def test_authorized_webhook_dispatches_without_a_quota_checkpoint(self) -> None:
        identity = self._identity()
        called = {"n": 0}

        def transport(request, timeout):
            called["n"] += 1
            return HttpResult(200, b"")

        adapter = GrokBotAdapter(
            identity,
            webhook_url="https://hooks.example.invalid/routine",
            webhook_secret="synthetic-secret",
            transport=transport,
        )
        events = adapter.dispatch(self._request(identity))
        self.assertEqual(called["n"], 1)
        self.assertEqual(events[0].kind, EventKind.ACCEPTED)
        self.assertFalse(events[0].payload["native_reply"])
        self.assertTrue(events[0].payload["routine_accepted"])

    def test_billed_host_is_a_local_failure(self) -> None:
        identity = self._identity()
        adapter = GrokBotAdapter(
            identity,
            webhook_url="https://api.x.ai/v1/responses",
            webhook_secret="synthetic-secret",
            transport=lambda *_: HttpResult(200, b""),
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
            transport=transport,
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
        self.assertIn("authorized webhook", record["access_dependency"])
        self.assertIn("not a Bot reply", record["access_dependency"])
        self.assertIsNone(record["quota_checkpoint"])

    def test_sanitizer_rejects_an_email(self) -> None:
        install = probe_client(str(PLIST))
        install = type(install)(True, "0.1.0", "person@example.com", ())
        with self.assertRaises(ConnectorError):
            evidence(install, None, observed_at=NOW, checkpoint=None)


if __name__ == "__main__":
    unittest.main()
