"""Account-bound adapter contract v1. Credentials and native authority stay with adapters."""

from .contract import (
    Adapter, AdapterEvent, AdapterIdentity, AdapterRegistry, Capability, DispatchRequest,
    DispatchUncertain, EventKind, UnsupportedCapability,
)

__all__ = [
    "Adapter", "AdapterEvent", "AdapterIdentity", "AdapterRegistry", "Capability",
    "DispatchRequest", "DispatchUncertain", "EventKind", "UnsupportedCapability",
]
