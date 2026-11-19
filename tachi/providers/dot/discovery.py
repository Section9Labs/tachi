"""Inspect public discovery documents offline: python -m tachi.providers.dot.discovery."""

import argparse
import json
from pathlib import Path


def _strings(value: object) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ValueError("expected a list of strings")
    return value


def inspect_documents(issuer_metadata: dict, client_request_schema: dict) -> dict:
    """Summarize public protocol declarations without forwarding input values."""
    if not isinstance(issuer_metadata, dict) or issuer_metadata.get("issuer") != "https://auth.openai.com":
        raise ValueError("expected OpenAI issuer metadata")
    scopes = _strings(issuer_metadata.get("scopes_supported"))
    pkce_methods = _strings(issuer_metadata.get("code_challenge_methods_supported"))

    if not isinstance(client_request_schema, dict):
        raise ValueError("expected the generated ClientRequest schema")
    variants = client_request_schema.get("oneOf")
    if not isinstance(variants, list) or not variants:
        raise ValueError("expected the generated ClientRequest schema")
    methods = set()
    for variant in variants:
        try:
            names = _strings(variant["properties"]["method"]["enum"])
        except (TypeError, KeyError, ValueError):
            raise ValueError("unsupported ClientRequest method declaration") from None
        if not names or not all(names):
            raise ValueError("empty ClientRequest method declaration")
        methods.update(names)

    return {
        "issuer_declares_openid": "openid" in scopes,
        "issuer_declares_pkce_s256": "S256" in pkce_methods,
        "codex_method_count": len(methods),
        "codex_methods_present": sorted(methods & {
            "account/login/start", "thread/start", "turn/start", "thread/resume",
        }),
        "dot_named_method_count": sum("dot" in name.lower() for name in methods),
        # A declaration cannot bind a signed-in account to its existing Dot.
        "verified_dot_capabilities": [],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("issuer_metadata", type=Path)
    parser.add_argument("client_request_schema", type=Path)
    args = parser.parse_args()
    try:
        issuer = json.loads(args.issuer_metadata.read_bytes())
        schema = json.loads(args.client_request_schema.read_bytes())
        report = inspect_documents(issuer, schema)
    except (OSError, ValueError, RecursionError):
        parser.exit(2, "Cannot read the expected public issuer metadata and ClientRequest schema.\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
