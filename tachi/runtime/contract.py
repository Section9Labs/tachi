"""Synchronous v1 dispatch boundary shared by native and reference connectors."""

import json
from dataclasses import dataclass
from enum import StrEnum
from typing import Protocol


class Capability(StrEnum):
    MESSAGE = "message"
    TASK = "task"
    ATTACHMENT = "attachment"
    TOOLS = "tools"
    CANCEL = "cancel"
    RECOVER = "recover"


class EventKind(StrEnum):
    ACCEPTED = "accepted"
    PROGRESS = "progress"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"


def _ids(*values: str) -> None:
    if any(not isinstance(value, str) or not value.strip() for value in values):
        raise ValueError("identifiers must be nonempty strings")


def _json_object(value: dict) -> str:
    if not isinstance(value, dict):
        raise ValueError("payload must be a JSON object")
    encoded = json.dumps(value, allow_nan=False, sort_keys=True, separators=(",", ":"))
    if json.loads(encoded) != value:
        raise ValueError("payload must round-trip as JSON")
    return encoded


@dataclass(frozen=True)
class AdapterIdentity:
    provider: str
    account_id: str
    assistant_id: str

    def __post_init__(self) -> None:
        _ids(self.provider, self.account_id, self.assistant_id)


@dataclass(frozen=True)
class DispatchRequest:
    identity: AdapterIdentity
    session_id: str
    request_id: str
    capability: Capability
    payload: dict

    def __post_init__(self) -> None:
        _ids(self.session_id, self.request_id)
        if not isinstance(self.identity, AdapterIdentity) or not isinstance(self.capability, Capability):
            raise TypeError("expected AdapterIdentity and Capability")
        _json_object(self.payload)


@dataclass(frozen=True)
class AdapterEvent:
    identity: AdapterIdentity
    session_id: str
    request_id: str
    event_id: str
    kind: EventKind
    payload: dict

    def __post_init__(self) -> None:
        _ids(self.session_id, self.request_id, self.event_id)
        if not isinstance(self.identity, AdapterIdentity) or not isinstance(self.kind, EventKind):
            raise TypeError("expected AdapterIdentity and EventKind")
        _json_object(self.payload)


class Adapter(Protocol):
    version: int
    identity: AdapterIdentity
    capabilities: frozenset[Capability]

    def dispatch(self, request: DispatchRequest) -> tuple[AdapterEvent, ...]: ...


class UnsupportedCapability(ValueError):
    """Rejected locally before the adapter ran."""


class DispatchUncertain(RuntimeError):
    """The operation may have taken effect. Reconcile before submitting more work."""


class AdapterRegistry:
    def __init__(self) -> None:
        self._entries: dict[AdapterIdentity, tuple[Adapter, frozenset[Capability]]] = {}

    def register(self, adapter: Adapter) -> None:
        identity = adapter.identity
        if type(adapter.version) is not int or adapter.version != 1:
            raise ValueError("unsupported adapter version")
        if not isinstance(identity, AdapterIdentity):
            raise TypeError("expected AdapterIdentity")
        capabilities = adapter.capabilities
        if not isinstance(capabilities, frozenset) or any(
            not isinstance(item, Capability) for item in capabilities
        ):
            raise TypeError("expected a frozenset of Capability values")
        if identity in self._entries:
            raise ValueError("identity already registered")
        self._entries[identity] = adapter, capabilities

    def capabilities(self, identity: AdapterIdentity) -> frozenset[Capability]:
        return self._entries[identity][1]

    def dispatch(self, request: DispatchRequest) -> tuple[AdapterEvent, ...]:
        adapter, capabilities = self._entries[request.identity]
        if request.capability not in capabilities:
            raise UnsupportedCapability(request.capability.value)
        if adapter.identity != request.identity:
            raise ValueError("registered adapter changed identity")
        _json_object(request.payload)
        try:
            events = adapter.dispatch(request)
            if not isinstance(events, tuple):
                raise ValueError("expected a tuple of events")
            unique: dict[str, AdapterEvent] = {}
            for event in events:
                if not isinstance(event, AdapterEvent) or (
                    event.identity, event.session_id, event.request_id
                ) != (request.identity, request.session_id, request.request_id):
                    raise ValueError("event outside dispatch scope")
                _json_object(event.payload)
                if event.event_id in unique and unique[event.event_id] != event:
                    raise ValueError("conflicting event ID")
                unique[event.event_id] = event
            return tuple(unique.values())
        except DispatchUncertain:
            raise
        except Exception as error:
            # Even a malformed reply can arrive after a successful native side effect.
            raise DispatchUncertain("adapter outcome requires reconciliation") from error
