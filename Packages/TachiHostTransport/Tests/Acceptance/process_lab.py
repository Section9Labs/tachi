"""Exercise release or debug Swift binaries with disposable loopback endpoints."""
import http.client
import json
import os
import select
import signal
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from contextlib import ExitStack, closing
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from tachi.hosts import AccountStore
from tachi.runtime.queue import HostScope, TeamQueue


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


def main(binary):
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

        class Gate(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                if hold.is_set() and self.path.endswith("/finish"):
                    arrived.set()
                    release.wait(15)
                    return
                with closing(http.client.HTTPConnection("127.0.0.1", port, timeout=5)) as conn:
                    headers = {k: self.headers[k] for k in ("Authorization", "X-Tachi-Host", "Content-Type") if self.headers[k]}
                    conn.request("POST", self.path, body, headers)
                    response = conn.getresponse()
                    data = response.read()
                    self.send_response(response.status)
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)

        proxy = ThreadingHTTPServer(("127.0.0.1", 0), Gate)
        threading.Thread(target=proxy.serve_forever, daemon=True).start()
        cleanup.callback(proxy.server_close)
        cleanup.callback(proxy.shutdown)
        cleanup.callback(release.set)

        accounts = AccountStore(db)
        token = accounts.redeem_client(accounts.issue_client_invitation(
            "owner", ["sessions:read", "messages:send", "teams:manage"])).token
        human = accounts.authenticate(token)
        token_file = base / "human-token"
        with os.fdopen(os.open(token_file, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), "w") as file:
            file.write(token)
        accounts.create_team("owner", human.client_id, "team")
        queue = cleanup.enter_context(closing(TeamQueue(db, accounts)))

        def setup(alias, port):
            folder, state = base / (alias + "-root"), base / (alias + "-state")
            folder.mkdir()
            state.mkdir(mode=0o700)
            invitation, credential = base / (alias + "-invite"), base / (alias + "-key")
            subprocess.run([server, "invite", db, "owner", invitation], check=True)
            subprocess.run([agent, "pair", str(port), invitation, credential], check=True)
            assert credential.stat().st_mode & 0o077 == 0
            args = (agent, "run", str(port), credential, folder, state)
            worker = start(*args)
            ids = json.loads(announced(worker))
            subprocess.run([server, "bind", db, token_file, "team", alias], check=True)
            grant = subprocess.check_output([server, "grant", db, "owner", ids["hostID"], ids["folderID"], "write"], text=True).strip()
            return args, worker, HostScope("owner", ids["hostID"], grant, ids["folderID"], "write", "brief"), folder

        args, alpha, a, folder_a = setup("alpha", proxy.server_port)
        _, beta, b, folder_b = setup("beta", port)
        queue.create_run("team", human, "run", "assistant:alpha", turn_limit=8)

        def post(alias, message, scope, body):
            subprocess.run([server, "post", db, token_file, "team", "run", alias, message, scope.host_id,
                            scope.grant_id, scope.folder_id, scope.action, scope.relative_path], input=body, check=True)

        def delivery(message):
            return next(row["deliveries"][0] for row in queue.history("team", human, "run") if row["message"] == message)

        os.kill(alpha.pid, signal.SIGSTOP)
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
        os.kill(alpha.pid, signal.SIGCONT)
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
        subprocess.run([server, "revoke", db, "owner", b.host_id, b.grant_id], check=True)
        denied = HostScope("owner", b.host_id, b.grant_id, b.folder_id, "write", "later")
        post("beta", "revoked", denied, b"never published")
        until(lambda: delivery("revoked")["state"] == "blocked", "revoked grant")
        assert not (folder_b / "later").exists()
        beta.terminate()
        assert beta.wait(timeout=12) == 0 and lease(b) is None
        print("PASS: two Swift host processes, independent progress, real exclusive creates, "
              "both process restarts, same-request receipt recovery, unchanged file, grant revocation")


if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve())
