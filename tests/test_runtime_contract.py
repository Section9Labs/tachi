import unittest
from dataclasses import replace

from tachi.runtime import (
    AdapterEvent, AdapterIdentity, AdapterRegistry, Capability, DispatchRequest,
    DispatchUncertain, EventKind, UnsupportedCapability,
)
from tachi.runtime.reference import ReferenceAdapter


class ContractTests(unittest.TestCase):
    def setUp(self):
        self.identity = AdapterIdentity("fixture", "account-a", "assistant")
        self.request = DispatchRequest(self.identity, "session", "request", Capability.MESSAGE, {})
        self.registry = AdapterRegistry()

    def test_routes_two_accounts_with_same_provider_and_assistant(self):
        other = replace(self.identity, account_id="account-b")
        a, b = ReferenceAdapter(self.identity), ReferenceAdapter(other)
        for adapter in (a, b):
            self.registry.register(adapter)
        for adapter in (b, a):
            request = replace(self.request, identity=adapter.identity)
            events = self.registry.dispatch(request)
            self.assertEqual(events, (AdapterEvent(
                adapter.identity, "session", "request", "result", EventKind.COMPLETED,
                {"operation": "message"},
            ),))
            self.assertEqual(adapter.calls, [request])

    def test_negotiation_rejects_unsupported_before_invocation(self):
        adapter = ReferenceAdapter(self.identity)
        self.registry.register(adapter)
        self.assertEqual(self.registry.capabilities(self.identity), adapter.capabilities)
        with self.assertRaises(UnsupportedCapability):
            self.registry.dispatch(replace(self.request, capability=Capability.CANCEL))
        self.assertFalse(adapter.calls)

    def test_registration_validates_version_identity_and_capabilities(self):
        adapter = ReferenceAdapter(self.identity)
        adapter.version = 2
        with self.assertRaises(ValueError):
            self.registry.register(adapter)
        adapter.version = 1
        adapter.capabilities = frozenset({"message"})
        with self.assertRaises(TypeError):
            self.registry.register(adapter)
        adapter.capabilities = frozenset()
        self.registry.register(adapter)
        with self.assertRaises(ValueError):
            self.registry.register(adapter)
        with self.assertRaises(ValueError):
            AdapterIdentity("fixture", " ", "assistant")

    def test_identical_duplicate_event_collapses(self):
        self.registry.register(ReferenceAdapter(self.identity, duplicate_event=True))
        self.assertEqual(len(self.registry.dispatch(self.request)), 1)

    def test_uncertain_submission_is_not_retried(self):
        adapter = ReferenceAdapter(self.identity, lose_reply=True)
        self.registry.register(adapter)
        with self.assertRaises(DispatchUncertain):
            self.registry.dispatch(self.request)
        self.assertEqual(adapter.calls, [self.request])

    def test_malformed_or_cross_session_reply_after_effect_is_uncertain(self):
        event = AdapterEvent(self.identity, "session", "request", "one", EventKind.COMPLETED, {})
        for reply in ((event, replace(event, payload={"different": True})),
                      (replace(event, session_id="another"),), [event]):
            with self.subTest(reply=reply):
                adapter = ReferenceAdapter(self.identity)
                adapter.dispatch = lambda request: reply
                registry = AdapterRegistry()
                registry.register(adapter)
                with self.assertRaises(DispatchUncertain):
                    registry.dispatch(self.request)


if __name__ == "__main__":
    unittest.main()
