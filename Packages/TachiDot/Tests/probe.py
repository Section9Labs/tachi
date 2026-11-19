"""Drive the built Swift MCP resource over HTTP with an isolated synthetic issuer."""
import base64
import contextlib
import http.client
import http.server
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import uuid


def exchange(port, method, path, payload=None, headers=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        connection.request(method, path, None if payload is None else json.dumps(payload),
                           {"Content-Type": "application/json", **(headers or {})})
        response = connection.getresponse()
        data = response.read()
        return response.status, response.headers, json.loads(data) if data else None
    finally:
        connection.close()


@contextlib.contextmanager
def plugin(executable, env, port):
    with subprocess.Popen([executable, "--local-fixture"], env=env, stdout=subprocess.DEVNULL) as process:
        try:
            for _ in range(100):
                if process.poll() is not None:
                    raise RuntimeError("Swift resource exited before discovery")
                try:
                    exchange(port, "GET", "/.well-known/oauth-protected-resource/mcp")
                    break
                except ConnectionRefusedError:
                    time.sleep(0.05)
            else:
                raise RuntimeError("Swift resource did not start")
            yield
        finally:
            process.terminate()
            process.wait(timeout=5)


def check(executable, directory):
    key = secrets.token_urlsafe()
    basic = base64.b64encode(secrets.token_bytes(32)).decode()
    rows = {}

    class Issuer(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            assert self.path == "/introspect"
            assert self.headers["Authorization"] == "Basic " + basic
            form = urllib.parse.parse_qs(self.rfile.read(int(self.headers["Content-Length"])).decode())
            assert form["token_type_hint"] == ["access_token"]
            body = json.dumps(rows.get(form["token"][0], {"active": False})).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Issuer) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", 0))
                port = sock.getsockname()[1]
            issuer = f"http://127.0.0.1:{server.server_port}"
            resource = f"http://127.0.0.1:{port}/mcp"
            receipt_file = directory / "receipt.json"
            env = dict(os.environ, TACHI_DOT_ISSUER=issuer, TACHI_DOT_RESOURCE=resource,
                       TACHI_DOT_INTROSPECTION=issuer + "/introspect", TACHI_DOT_SUBJECT="trial-owner",
                       TACHI_DOT_INTROSPECTION_BASIC=basic, TACHI_DOT_RECEIPT_FILE=str(receipt_file),
                       TACHI_DOT_PORT=str(port))

            def rpc(method, params, token=None):
                return exchange(port, "POST", "/mcp", {"jsonrpc": "2.0", "method": method, "params": params, "id": 1},
                                {} if token is None else {"Authorization": "Bearer " + token})

            args = {"name": "read_connection_sample", "arguments": {}}
            claims = dict(active=True, token_type="Bearer", sub="trial-owner", iss=issuer, aud=resource,
                          exp=time.time() + 600, scope="sample.read")
            with plugin(executable, env, port):
                result = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                            "clientInfo": {"name": "fixture", "version": "1"}})[2]["result"]
                assert result["capabilities"] == {"tools": {}} and result["protocolVersion"] == "2025-06-18"
                assert exchange(port, "POST", "/mcp", {"jsonrpc": "2.0", "method": "notifications/initialized"})[0] == 202
                tools = rpc("tools/list", {})[2]["result"]["tools"]
                assert [tool["name"] for tool in tools] == [args["name"]]
                assert rpc("events/subscribe", {})[2]["error"]["code"] == -32601
                assert tools[0]["_meta"]["securitySchemes"] == [{"type": "oauth2", "scopes": ["sample.read"]}]
                status, headers, error = rpc("tools/call", args)
                assert status == 200 and error["result"]["isError"]
                assert error["result"]["_meta"]["mcp/www_authenticate"] == [headers["WWW-Authenticate"]]
                assert 'error_description="' in headers["WWW-Authenticate"]
                metadata = exchange(port, "GET", "/.well-known/oauth-protected-resource/mcp")[2]
                assert metadata["resource"] == resource and metadata["authorization_servers"] == [issuer]
                assert resource.replace("/mcp", "/.well-known/oauth-protected-resource/mcp") in headers["WWW-Authenticate"]
                for overrides, expected in [({"active": False}, "invalid_token"), ({"sub": "different"}, "invalid_token"),
                                            ({"iss": issuer + "/other"}, "invalid_token"), ({"aud": [issuer]}, "invalid_token"),
                                            ({"exp": 0}, "invalid_token"), ({"nbf": time.time() + 600}, "invalid_token"),
                                            ({"token_type": "refresh_token"}, "invalid_token"), ({"scope": "sample.write"}, "insufficient_scope")]:
                    rows[key] = dict(claims, **overrides)
                    _, headers, denied = rpc("tools/call", args, key)
                    assert denied["result"]["isError"] and f'error="{expected}"' in headers["WWW-Authenticate"]
                assert not receipt_file.exists()
                rows[key] = claims
                value = rpc("tools/call", args, key)[2]["result"]["structuredContent"]["receipt"]
                uuid.UUID(value)
                assert value == json.loads(receipt_file.read_bytes())["sample"]
            with plugin(executable, env, port):
                rows[key] = dict(claims, aud=[resource])
                assert rpc("tools/call", args, key)[2]["result"]["content"][0]["text"] == value
                rows[key] = {"active": False}
                assert rpc("tools/call", args, key)[2]["result"]["isError"]
            print("PASS: MCP discovery, OAuth challenge, eight denied grants, scoped tool call, independent receipt readback, restart and revocation")
        finally:
            server.shutdown()
            thread.join()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as tmp:
        check(sys.argv[1], Path(tmp))
