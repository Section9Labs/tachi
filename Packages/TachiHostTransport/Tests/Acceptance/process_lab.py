"""Exercise release or debug Swift binaries with disposable loopback endpoints."""
import argparse
import http.client
import json
import os
import select
import sqlite3
import subprocess
import tempfile
import threading
import time
from contextlib import ExitStack, closing
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from tachi.hosts import AccountStore
from tachi.runtime.queue import HostScope, TeamQueue
from tls_fixture import tls_identity


def until(check, label, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if result := check():
            return result
        time.sleep(.05)
    raise RuntimeError("timeout: " + label)


def announced(process):
    if not select.select([process.stdout], [], [], 10)[0]:
        raise RuntimeError("no process announcement")
    line = process.stdout.readline()
    if not line:
        raise RuntimeError("process exited before announcing readiness")
    return line


def stop(process):
    if process.poll() is None:
        process.kill()
    process.wait(timeout=10)
    process.stdout.close()


def main(binary, https):
    server, agent = binary / "tachi-host-sidecar", binary / "tachi-host-agent"
    with tempfile.TemporaryDirectory() as temp, ExitStack() as cleanup:
        base = Path(temp).resolve()
        db = base / "service.sqlite"

        def start(*command):
            process = subprocess.Popen(list(map(str, command)), stdout=subprocess.PIPE)
            cleanup.callback(stop, process)
            return process

        sidecar = start(server, "serve", db, 0)
        port = int(announced(sidecar))
        # An ACK gate lets the test stop the host AFTER the actual APFS create
        # and BEFORE the coordinator receives its completion.
        hold, arrived, release = threading.Event(), threading.Event(), threading.Event()
        offline_host = None
        outage_seen = threading.Event()
        check_held, check_seen, resume_check = threading.Event(), threading.Event(), threading.Event()
        check_denied = threading.Event()
        pair_seen = threading.Event()

        class Gate(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                if self.path.endswith("/pair"):
                    pair_seen.set()
                if offline_host is not None and self.headers.get("X-Tachi-Host") == offline_host:
                    outage_seen.set()
                    return  # Drop the connection without forwarding the request.
                if check_held.is_set() and self.path.endswith("/check"):
                    check_seen.set()
                    if not resume_check.wait(12):
                        return
                if hold.is_set() and self.path.endswith("/finish"):
                    arrived.set()
                    release.wait(15)
                    return
                with closing(http.client.HTTPConnection("127.0.0.1", port, timeout=5)) as conn:
                    headers = {k: self.headers[k] for k in ("Authorization", "X-Tachi-Host", "Content-Type") if self.headers[k]}
                    try:
                        conn.request("POST", self.path, body, headers)
                        response = conn.getresponse()
                        data = response.read()
                    except (ConnectionError, http.client.IncompleteRead):
                        # The lab deliberately kills and rebinds the upstream sidecar.
                        self.send_response(503)
                        self.send_header("Content-Length", "0")
                        self.end_headers()
                        return
                    if self.path.endswith("/check") and response.status == 403:
                        check_denied.set()
                    self.send_response(response.status)
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)

        proxy = ThreadingHTTPServer(("127.0.0.1", 0), Gate)
        cleanup.callback(proxy.server_close)
        address = str(proxy.server_port)
        agent_args = [agent]
        if https:
            context = tls_identity(base)
            proxy.socket = context.wrap_socket(proxy.socket, server_side=True)
            address = f"https://localhost:{proxy.server_port}"
            agent_args += ["--ca-der", base / "ca.der"]
        threading.Thread(target=proxy.serve_forever, daemon=True).start()
        cleanup.callback(proxy.shutdown)
        cleanup.callback(release.set)
        cleanup.callback(resume_check.set)

        accounts = AccountStore(db)
        token = accounts.redeem_client(accounts.issue_client_invitation(
            "owner", ["sessions:read", "messages:send", "teams:manage"])).token
        human = accounts.authenticate(token)
        token_file = base / "human-token"
        with os.fdopen(os.open(token_file, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), "w") as file:
            file.write(token)
        accounts.create_team("owner", human.client_id, "team")
        queue = cleanup.enter_context(closing(TeamQueue(db, accounts)))

        def setup(alias):
            folder, state = base / (alias + "-root"), base / (alias + "-state")
            folder.mkdir()
            state.mkdir(mode=0o700)
            invitation, credential = base / (alias + "-invite"), base / (alias + "-key")
            subprocess.run([server, "invite", db, "owner", invitation], check=True)
            if https and alias == "alpha":
                # The same ticket must still work after every TLS handshake failure.
                for label, cmd, origin in [
                    ("unknown-ca", [agent], address),
                    ("wrong-ca", [agent, "--ca-der", base / "unrelated.der"], address),
                    ("wrong-name", agent_args, f"https://127.0.0.1:{proxy.server_port}"),
                ]:
                    output = base / label
                    failure = subprocess.run([*cmd, "pair", origin, invitation, output], capture_output=True)
                    assert failure.returncode != 0 and not pair_seen.is_set()
                    assert not output.exists() or output.stat().st_size == 0
            subprocess.run([*agent_args, "pair", address, invitation, credential], check=True)
            assert credential.stat().st_mode & 0o077 == 0
            args = (*agent_args, "run", address, credential, folder, state)
            worker = start(*args)
            ids = json.loads(announced(worker))
            subprocess.run([server, "bind", db, token_file, "team", alias], check=True)
            grant = subprocess.check_output([server, "grant", db, "owner", ids["hostID"], ids["folderID"], "write"], text=True).strip()
            return args, worker, HostScope("owner", ids["hostID"], grant, ids["folderID"], "write", "brief"), folder

        args, alpha, a, folder_a = setup("alpha")
        _, beta, b, folder_b = setup("beta")
        queue.create_run("team", human, "run", "assistant:alpha", turn_limit=8)

        def post(alias, message, scope, body):
            subprocess.run([server, "post", db, token_file, "team", "run", alias, message, scope.host_id,
                            scope.grant_id, scope.folder_id, scope.action, scope.relative_path], input=body, check=True)

        def delivery(message):
            return next(row["deliveries"][0] for row in queue.history("team", human, "run") if row["message"] == message)

        offline_host = a.host_id
        assert outage_seen.wait(10)
        post("alpha", "alpha-brief", a, b"actual first file")
        post("beta", "beta-brief", b, b"actual second file")
        until(lambda: delivery("beta-brief")["state"] == "completed", "independent host")
        assert delivery("alpha-brief")["state"] == "queued" and not (folder_a / "brief").exists()
        assert (folder_b / "brief").read_bytes() == b"actual second file"
        def lease(scope):
            with closing(sqlite3.connect(db)) as conn:
                return conn.execute("SELECT lease_until FROM host_devices WHERE host_id=?", (scope.host_id,)).fetchone()[0]

        # Let A miss a real renewal while B continues renewing its lease.
        until(lambda: lease(a) <= time.time(), "silent host expiry", timeout=35)
        assert lease(b) > time.time()
        hold.set()
        offline_host = None
        assert arrived.wait(10)
        assert (folder_a / "brief").read_bytes() == b"actual first file"
        first = delivery("alpha-brief")
        assert first["state"] == "uncertain" and not first["events"]
        original = (folder_a / "brief").stat()
        stop(alpha)
        hold.clear()
        release.set()
        stop(sidecar)
        restarted = start(server, "serve", db, port)
        assert int(announced(restarted)) == port
        fresh = start(*args)
        assert json.loads(announced(fresh))["folderID"] != a.folder_id
        until(lambda: delivery("alpha-brief")["state"] == "completed", "receipt recovery")
        final = delivery("alpha-brief")
        assert first["request"] == final["request"] and len(final["events"]) == 1
        assert final["events"][0]["payload"] == {"byteCount": len(b"actual first file")}
        restored = (folder_a / "brief").stat()
        assert (original.st_ino, original.st_mtime_ns) == (restored.st_ino, restored.st_mtime_ns)
        denied = HostScope("owner", b.host_id, b.grant_id, b.folder_id, "write", "later")
        check_held.set()
        post("beta", "revoked", denied, b"never published")
        assert check_seen.wait(10)
        claimed = delivery("revoked")
        assert claimed["state"] == "uncertain" and not (folder_b / "later").exists()
        subprocess.run([server, "revoke", db, "owner", b.host_id, b.grant_id], check=True)
        resume_check.set()
        assert check_denied.wait(5)
        until(lambda: delivery("revoked")["state"] == "failed", "revoked claim refused")
        refused = delivery("revoked")
        assert refused["request"] == claimed["request"] and len(refused["events"]) == 1
        assert refused["events"][0]["payload"] == {"byteCount": 0}
        assert not (folder_b / "later").exists()
        post("beta", "after-revoke", denied, b"never published")
        until(lambda: delivery("after-revoke")["state"] == "blocked", "revoked grant")
        assert not (folder_b / "later").exists()
        beta.terminate()
        assert beta.wait(timeout=12) == 0 and lease(b) is None
        print("PASS", "HTTPS" if https else "HTTP", "two Swift agents, dropped connections, lease expiry, "
              "independent creates, restart and receipt recovery, post-claim and pre-claim revocation")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("--https", action="store_true")
    args = parser.parse_args()
    main(args.binary.resolve(), args.https)
