"""v1 adapter. Advertises task only when an operator webhook is configured.

An authorized webhook is the product step. Dispatch does not consult the
engineering quota checkpoint.
"""

from __future__ import annotations

from tachi.providers.grok.connector import (
    NotSent,
    RoutineRejected,
    SubmissionUnobserved,
    trigger_routine,
)
from tachi.providers.grok.product import PRODUCT_ID
from tachi.runtime import (
    AdapterEvent,
    AdapterIdentity,
    Capability,
    DispatchRequest,
    DispatchUncertain,
    EventKind,
)


class GrokBotAdapter:
    version = 1

    def __init__(
        self,
        identity: AdapterIdentity,
        *,
        webhook_url: str | None = None,
        webhook_secret: str | None = None,
        transport=None,
        allow_loopback: bool = False,
    ) -> None:
        if not isinstance(identity, AdapterIdentity) or identity.provider != PRODUCT_ID:
            raise ValueError("identity provider must be grok-bot")
        self.identity = identity
        self._webhook_url = webhook_url
        self._webhook_secret = webhook_secret
        self._transport = transport
        self._allow_loopback = allow_loopback
        configured = bool(webhook_url and webhook_secret)
        self.capabilities = frozenset({Capability.TASK}) if configured else frozenset()

    def dispatch(self, request: DispatchRequest) -> tuple[AdapterEvent, ...]:
        if request.capability is not Capability.TASK:
            return (self._event(request, EventKind.FAILED, {"reason": "unsupported"}),)
        if not self._webhook_url or not self._webhook_secret:
            return (self._event(request, EventKind.FAILED, {"reason": "webhook_unconfigured"}),)
        try:
            acceptance = trigger_routine(
                self._webhook_url,
                self._webhook_secret,
                request.payload,
                transport=self._transport,
                allow_loopback=self._allow_loopback,
            )
        except NotSent:
            return (self._event(request, EventKind.FAILED, {"reason": "not_sent"}),)
        except RoutineRejected as exc:
            return (self._event(request, EventKind.FAILED, {"reason": "rejected", "status": exc.status}),)
        except SubmissionUnobserved as exc:
            raise DispatchUncertain("routine submission result was not observed") from exc
        if not acceptance.accepted or acceptance.completed:
            raise DispatchUncertain("routine acceptance did not match the documented 200 contract")
        # HTTP 200 accepts the run. It is not a Bot reply and not a native session id.
        # session_id stays the caller's opaque id. This process does not POST again.
        return (
            self._event(
                request,
                EventKind.ACCEPTED,
                {
                    "routine_accepted": True,
                    "native_reply": False,
                    "native_session_observed": False,
                },
            ),
        )

    def _event(self, request: DispatchRequest, kind: EventKind, payload: dict) -> AdapterEvent:
        return AdapterEvent(
            self.identity,
            request.session_id,
            request.request_id,
            f"{kind.value}-1",
            kind,
            payload,
        )
