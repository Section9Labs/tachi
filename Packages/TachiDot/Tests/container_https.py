"""Qualify a built Linux image with a local HTTPS gateway and a synthetic OAuth issuer."""
import base64
import contextlib
import http.client
import http.server
import json
import os
from pathlib import Path
import secrets
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import uuid


def run(*args):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, text=True).stdout.strip()


@contextlib.contextmanager
def https_server(handler, cert, key):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield server.server_port
        finally:
            server.shutdown()
            thread.join()


class Quiet(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send_bytes(self, status, data, headers=()):
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def qualify(image, root):
    ca, cert, key = (root / name for name in ("ca.crt", "gateway.crt", "gateway.key"))
    run("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=Dot CI CA",
        "-keyout", str(root / "ca.key"), "-out", str(ca))
    run("openssl", "req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=localhost",
        "-keyout", str(key), "-out", str(root / "gateway.csr"))
    ext = root / "extensions"
    ext.write_text("subjectAltName=IP:127.0.0.1\nextendedKeyUsage=serverAuth\n")
    run("openssl", "x509", "-req", "-in", str(root / "gateway.csr"), "-CA", str(ca),
        "-CAkey", str(root / "ca.key"), "-CAcreateserial", "-days", "1", "-extfile", str(ext), "-out", str(cert))
    ca.chmod(0o644)
    client_tls = ssl.create_default_context(cafile=str(ca))
    data_dir = root / "state"
    data_dir.mkdir(mode=0o700)
    bearer = secrets.token_urlsafe()
    basic = base64.b64encode(("trial:" + secrets.token_urlsafe()).encode()).decode()
    claims = {"active": True, "token_type": "Bearer", "sub": "trial-owner", "scope": "sample.read",
              "exp": int(time.time()) + 600}

    class Issuer(Quiet):
        def do_POST(self):
            form = urllib.parse.parse_qs(self.rfile.read(int(self.headers.get("Content-Length", 0))).decode())
            if self.path != "/introspect" or self.headers.get("Authorization") != "Basic " + basic:
                self.send_bytes(403, b"")
                return
            value = claims if form.get("token") == [bearer] else {"active": False}
            self.send_bytes(200, json.dumps(value).encode(), [("Content-Type", "application/json")])

    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        backend = sock.getsockname()[1]

    class Gateway(Quiet):
        def forward(self):
            headers = {name: self.headers[name] for name in ("Content-Type", "Authorization") if name in self.headers}
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            conn = http.client.HTTPConnection("127.0.0.1", backend, timeout=5)
            try:
                conn.request(self.command, self.path, body=body, headers=headers)
                response = conn.getresponse()
                forwarded = [(k, v) for k, v in response.getheaders() if k.lower() in ("content-type", "www-authenticate")]
                self.send_bytes(response.status, response.read(), forwarded)
            except ConnectionRefusedError:
                self.send_bytes(503, b"")
            finally:
                conn.close()

        do_GET = do_POST = forward

    with https_server(Issuer, cert, key) as issuer, https_server(Gateway, cert, key) as gateway:
        origin = f"https://127.0.0.1:{gateway}"
        resource = origin + "/mcp"
        claims.update(iss=f"https://127.0.0.1:{issuer}", aud=resource)
        env = root / "private.env"
        env.write_text("\n".join(f"TACHI_DOT_{k}={v}" for k, v in {
            "RESOURCE": resource, "ISSUER": claims["iss"], "SUBJECT": claims["sub"], "PORT": backend,
            "INTROSPECTION": claims["iss"] + "/introspect", "INTROSPECTION_BASIC": basic,
        }.items()) + "\n")
        env.chmod(0o600)

        def get(path, method=None, params=None, authenticated=False):
            conn = http.client.HTTPSConnection("127.0.0.1", gateway, context=client_tls, timeout=8)
            headers = {"Content-Type": "application/json"}
            if authenticated:
                headers["Authorization"] = "Bearer " + bearer
            payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}})
            try:
                conn.request("POST" if method else "GET", path, payload if method else None, headers)
                reply = conn.getresponse()
                body = reply.read()
                return reply.status, json.loads(body) if body else None
            finally:
                conn.close()

        receipt = None
        for _ in range(2):
            container = run("docker", "run", "-d", "--network", "host", "--read-only", "--cap-drop=ALL",
                            "--security-opt=no-new-privileges", "--user", f"{os.getuid()}:{os.getgid()}",
                            "--env-file", str(env), "-v", f"{data_dir}:/var/lib/tachi-dot",
                            "-v", f"{ca}:/etc/ssl/certs/ca-certificates.crt:ro", image)
            try:
                for _ in range(100):
                    status, metadata = get("/.well-known/oauth-protected-resource/mcp")
                    if status == 200:
                        break
                    time.sleep(0.05)
                assert metadata and metadata["resource"] == resource
                assert metadata["authorization_servers"] == [claims["iss"]]
                _, hello = get("/mcp", "initialize", {"protocolVersion": "2025-06-18"})
                assert hello["result"]["capabilities"] == {"tools": {}}
                _, catalog = get("/mcp", "tools/list")
                assert [tool["name"] for tool in catalog["result"]["tools"]] == ["read_connection_sample"]
                call = {"name": "read_connection_sample", "arguments": {}}
                _, denied = get("/mcp", "tools/call", call)
                assert denied["result"]["isError"] and denied["result"]["_meta"]["mcp/www_authenticate"]
                _, reply = get("/mcp", "tools/call", call, True)
                sample = reply["result"]["structuredContent"]["receipt"]
                uuid.UUID(sample)
                assert sample == json.loads((data_dir / "receipt.json").read_bytes())["sample"]
                if receipt is not None:
                    assert receipt == sample
                    claims["active"] = False
                    _, revoked = get("/mcp", "tools/call", call, True)
                    assert revoked["result"]["isError"]
                receipt = sample
            finally:
                run("docker", "rm", "-f", container)
    print("PASS: HTTPS discovery and challenge, trusted issuer introspection, scoped receipt, replacement container and revocation")


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as directory:
        qualify(sys.argv[1], Path(directory))
