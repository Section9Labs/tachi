#!/usr/bin/env python3
"""Check the coordinator's bootstrap response from outside the application."""

import argparse
import http.client
import json
import sys


class ProbeFailure(Exception):
    pass


def unique_fields(pairs):
    fields = {}
    for key, value in pairs:
        if key in fields:
            raise ProbeFailure("duplicate JSON field")
        fields[key] = value
    return fields


def check_status(port):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
    try:
        connection.request("GET", "/v1/status", headers={"Accept": "application/json"})
        response = connection.getresponse()
        if response.status != 200:
            raise ProbeFailure(f"expected HTTP 200, received {response.status}")
        media_type = response.getheader("Content-Type", "").partition(";")[0]
        if media_type.strip().lower() != "application/json":
            raise ProbeFailure("expected Content-Type application/json")
        declared_length = response.length
        body = response.read(65537)
        if len(body) > 65536:
            raise ProbeFailure("status response exceeds 64 KiB")
        if declared_length is not None and len(body) != declared_length:
            raise ProbeFailure("incomplete status response")
    finally:
        connection.close()

    try:
        status = json.loads(body.decode("utf-8"), object_pairs_hook=unique_fields)
    except (ValueError, RecursionError) as error:
        raise ProbeFailure("invalid UTF-8 JSON response") from error

    expected = {"service": "tachi", "protocolVersion": 1, "status": "ready"}
    if status != expected or type(status["protocolVersion"]) is not int:
        raise ProbeFailure("unexpected status fields, types, or values")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8743)
    port = parser.parse_args().port
    if not 1 <= port <= 65535:
        parser.error("port must be in the range 1..65535")
    try:
        check_status(port)
    except ProbeFailure as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    except (OSError, http.client.HTTPException) as error:
        print(f"FAIL: transport error ({type(error).__name__})", file=sys.stderr)
        return 1
    print("PASS: GET /v1/status returned HTTP 200 and the protocol v1 ready object")
    return 0


if __name__ == "__main__":
    sys.exit(main())
