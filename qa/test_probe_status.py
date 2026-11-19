"""Synthetic wire fixtures for the independent HTTP probe."""

import http.server
from pathlib import Path
import subprocess
import sys
import threading
import unittest


PROBE = Path(__file__).with_name("probe_status.py")
READY = b'{ "status": "ready", "protocolVersion": 1, "service": "tachi" }'


class ProbeTests(unittest.TestCase):
    def probe(self, code=200, media="application/json", body=READY, length=None):
        class Fixture(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(code if self.path == "/v1/status" else 404)
                self.send_header("Content-Type", media)
                if length is not None:
                    self.send_header("Content-Length", str(length))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        with http.server.HTTPServer(("127.0.0.1", 0), Fixture) as server:
            server.timeout = 5
            worker = threading.Thread(target=server.handle_request)
            worker.start()
            try:
                return subprocess.run(
                    [sys.executable, str(PROBE), "--port", str(server.server_port)],
                    capture_output=True, text=True, timeout=6,
                )
            finally:
                worker.join()

    def test_ready(self):
        result = self.probe(media="application/json; charset=utf-8")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_invalid_responses(self):
        for change in (
            {"code": 302}, {"code": 503}, {"media": "text/plain"},
            {"length": len(READY) + 1}, {"body": b" " * 65537 + READY},
            {"body": b"{"}, {"body": b"[]"}, {"body": b"\xff"},
            {"body": READY.replace(b"1", b"true")},
            {"body": READY.replace(b"1", b"1.0")},
            {"body": READY.replace(b"ready", b"starting")},
            {"body": READY.replace(b'"service":', b'"other":0,"service":')},
            {"body": READY.replace(b'"service":', b'"service":"old","service":')},
        ):
            with self.subTest(change=change):
                self.assertEqual(self.probe(**change).returncode, 1)


if __name__ == "__main__":
    unittest.main()
