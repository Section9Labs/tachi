"""Deterministic, in-process conformance fixture. Uses synthetic identities and input."""

from .contract import AdapterEvent, AdapterIdentity, Capability, DispatchRequest, DispatchUncertain, EventKind


class ReferenceAdapter:
    version = 1
    capabilities = frozenset({Capability.MESSAGE, Capability.TASK})

    def __init__(
        self, identity: AdapterIdentity, *, duplicate_event: bool = False, lose_reply: bool = False
    ) -> None:
        self.identity = identity
        self.duplicate_event = duplicate_event
        self.lose_reply = lose_reply
        self.calls: list[DispatchRequest] = []

    def dispatch(self, request: DispatchRequest) -> tuple[AdapterEvent, ...]:
        self.calls.append(request)
        if self.lose_reply:
            raise DispatchUncertain("reference reply lost after submission")
        event = AdapterEvent(
            self.identity, request.session_id, request.request_id, "result",
            EventKind.COMPLETED, {"operation": request.capability.value},
        )
        return (event, event) if self.duplicate_event else (event,)
