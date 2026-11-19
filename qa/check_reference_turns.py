"""Manually relay synthetic requests through the v1 reference adapter."""

from unittest import TestCase, main

from tachi.runtime import AdapterIdentity, AdapterRegistry, Capability, DispatchRequest, EventKind
from tachi.runtime.reference import ReferenceAdapter


class ReferenceTurnChecks(TestCase):
    def setUp(self):
        self.registry = AdapterRegistry()

    def register(self, provider):
        identity = AdapterIdentity(provider, "lab-account", "lab-assistant")
        adapter = ReferenceAdapter(identity)
        self.registry.register(adapter)
        return adapter

    def send(self, adapter, session, request_id, capability, payload):
        request = DispatchRequest(adapter.identity, session, request_id, capability, payload)
        event, = self.registry.dispatch(request)
        self.assertEqual(adapter.calls[-1], request)
        self.assertEqual(event.identity, request.identity)
        self.assertEqual(event.session_id, session)
        self.assertEqual(event.request_id, request_id)
        self.assertEqual(event.kind, EventKind.COMPLETED)
        self.assertEqual(event.payload, {"operation": capability.value})
        return event

    def test_solo_turn(self):
        assistant = self.register("reference-a")
        self.send(assistant, "solo", "q1", Capability.TASK, {"input": "draft.md"})
        self.assertEqual(len(assistant.calls), 1)

    def test_manually_relayed_team_turns(self):
        lead = self.register("reference-a")
        reviewer = self.register("reference-b")
        brief = self.send(lead, "team-lead", "q1", Capability.MESSAGE, {"input": "draft.md"})
        check = self.send(reviewer, "team-reviewer", "q2", Capability.TASK,
                          {"parent": brief.request_id, "input": "attendance.csv"})
        self.send(lead, "team-lead", "q3", Capability.MESSAGE, {"parent": check.request_id})
        self.assertEqual([r.request_id for r in lead.calls], ["q1", "q3"])
        self.assertEqual([r.request_id for r in reviewer.calls], ["q2"])


if __name__ == "__main__":
    main()
