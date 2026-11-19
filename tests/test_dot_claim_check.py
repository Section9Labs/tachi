import base64
import hashlib
import hmac
import json
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from tachi.providers.dot.claim_check import (
    EVENT, READ_SCOPE, READ_TOOL, RETURN_SCOPE, RETURN_TOOL, ClaimChecks,
    event_catalog, signed_webhook, tool_catalog, verify_callback,
)

# Public, deterministic Standard Webhooks test key (the bytes 0..31).
KEY = "whsec_AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
READ = frozenset({READ_SCOPE})
WRITE = frozenset({RETURN_SCOPE})


class PluginRoundTripTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.path = Path(tmp.name) / "bridge.sqlite"
        self.now = 1700000000
        self.bridge = ClaimChecks(self.path, clock=lambda: self.now)
        def echo(body, headers):
            self.assertEqual(headers["X-MCP-Subscription-Id"], "sub-a")
            return 200, {"challenge": json.loads(body)["challenge"]}

        verify_callback("sub-a", keys=[KEY], post=echo)
        self.bridge.activate("owner-a", "sub-a", self.now + 600)

    def event(self):
        return self.bridge.event("owner-a", "sub-a", "request-1")

    def test_signed_event_read_return_and_reopen(self):
        event = self.event()
        self.assertEqual(event["name"], event_catalog()["events"][0]["name"])
        self.assertEqual(EVENT, event["name"])
        self.assertEqual([t["name"] for t in tool_catalog()["tools"]], [READ_TOOL, RETURN_TOOL])
        self.assertEqual(set(event["data"]), {"claim", "subscription"})
        self.assertNotEqual(event["data"]["claim"], event["eventId"])

        body, headers = signed_webhook("sub-a", event["eventId"], event, keys=[KEY], signed_at=self.now)
        self.assertEqual(headers["X-MCP-Subscription-Id"], "sub-a")
        parts = [headers["webhook-id"].encode(), headers["webhook-timestamp"].encode(), body]
        mac = hmac.new(bytes(range(32)), b".".join(parts), hashlib.sha256).digest()
        self.assertEqual(headers["webhook-signature"], "v1," + base64.b64encode(mac).decode())
        args = json.loads(body)["data"]
        counts = self.bridge.call_tool("owner-a", READ, READ_TOOL, args)["structuredContent"]
        self.assertIsNone(self.bridge.returned_total("owner-a", "sub-a", "request-1"))

        self.bridge = ClaimChecks(self.path, clock=lambda: self.now)
        self.assertEqual(self.event(), event)
        total = counts["blue"] + counts["green"]
        for _ in range(2):
            reply = self.bridge.call_tool("owner-a", WRITE, RETURN_TOOL, dict(args, total=total))
            self.assertEqual(reply["structuredContent"], {"recorded": True})
        with self.assertRaises(ValueError):
            self.bridge.call_tool("owner-a", WRITE, RETURN_TOOL, dict(args, total=total+1))
        self.assertEqual(self.bridge.returned_total("owner-a", "sub-a", "request-1"), total)

    def test_owner_subscription_and_tool_scopes(self):
        args = self.event()["data"]
        self.bridge.activate("owner-b", "sub-a", self.now + 600)
        self.bridge.activate("owner-a", "sub-b", self.now + 600)
        for owner, scopes, subscription in [
            ("owner-b", READ, "sub-a"), ("owner-a", READ, "sub-b"), ("owner-a", WRITE, "sub-a"),
        ]:
            with self.subTest(owner=owner, subscription=subscription, scopes=scopes):
                with self.assertRaises(PermissionError):
                    self.bridge.call_tool(owner, scopes, READ_TOOL, dict(args, subscription=subscription))
        with self.assertRaises(PermissionError):
            self.bridge.call_tool("owner-a", READ, RETURN_TOOL, dict(args, total=25))
        with self.assertRaises(ValueError):
            self.bridge.call_tool("owner-a", READ, READ_TOOL, dict(args, owner="owner-b"))
        with self.assertRaises(ValueError):
            self.bridge.call_tool("owner-a", WRITE, RETURN_TOOL, dict(args, total=True))
        other = self.bridge.event("owner-b", "sub-a", "request-1")
        self.assertNotEqual(args["claim"], other["data"]["claim"])
        with self.assertRaises(PermissionError):
            self.bridge.call_tool("owner-b", WRITE, RETURN_TOOL, dict(args, total=0))

    def test_refresh_expiry_and_resubscription(self):
        event = self.event()
        self.bridge.activate("owner-a", "sub-a", self.now + 1200)
        self.now += 600
        self.assertEqual(self.event(), event)
        self.now += 600
        with self.assertRaises(PermissionError):
            self.event()
        with self.assertRaises(PermissionError):
            self.bridge.call_tool("owner-a", READ, READ_TOOL, event["data"])
        self.bridge.activate("owner-a", "sub-a", self.now + 60)
        self.assertNotEqual(self.event(), event)
        with self.assertRaises(PermissionError):
            self.bridge.call_tool("owner-a", READ, READ_TOOL, event["data"])

    def test_idempotent_unsubscribe_stops_read_and_return(self):
        args = self.event()["data"]
        for _ in range(2):
            self.bridge.deactivate("owner-a", "sub-a")
        with self.assertRaises(PermissionError):
            self.bridge.returned_total("owner-a", "sub-a", "request-1")
        self.bridge.activate("owner-a", "sub-a", self.now + 60)
        with self.assertRaises(PermissionError):
            self.bridge.call_tool("owner-a", WRITE, RETURN_TOOL, dict(args, total=25))

    def test_concurrent_retry_correlates_one_event(self):
        with ThreadPoolExecutor(4) as pool:
            results = list(pool.map(lambda _: self.event(), range(8)))
        self.assertTrue(all(event == results[0] for event in results))

    def test_signing_vector_and_rotation(self):
        challenge = {"type": "verification", "challenge": "fixture"}
        second_key = "whsec_" + base64.b64encode(bytes(range(32, 64))).decode()
        _, headers = signed_webhook("sub-a", "verify-1", challenge, keys=[KEY, second_key], signed_at=self.now)
        first, second = headers["webhook-signature"].split()
        self.assertEqual(first, "v1,pA+QS/NLRksvmEXCZFbKvmPYa+8pp2SmIq/x/8IhrLo=")
        self.assertNotEqual(first, second)
        for invalid in ([], ["invalid"], ["whsec_YQ=="], ["whsec_!"]):
            with self.assertRaises(ValueError):
                signed_webhook("sub-a", "verify-1", challenge, keys=invalid, signed_at=self.now)

    def test_stale_echo_non_success_and_misdirected_event(self):
        replies = []

        def replay(body, headers):
            replies.append(json.loads(body)["challenge"])
            return 200, {"challenge": replies[0]}

        verify_callback("sub-a", keys=[KEY], post=replay)
        with self.assertRaises(PermissionError):
            verify_callback("sub-a", keys=[KEY], post=replay)
        with self.assertRaises(PermissionError):
            verify_callback("sub-a", keys=[KEY], post=lambda body, _: (403, json.loads(body)))
        event = self.event()
        with self.assertRaises(ValueError):
            signed_webhook("sub-b", event["eventId"], event, keys=[KEY], signed_at=self.now)
