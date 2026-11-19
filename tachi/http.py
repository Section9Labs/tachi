"""HTTP entry points shared by the native clients."""

import json
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler


class CoordinatorHandler(BaseHTTPRequestHandler):
    server_version = "Tachi"

    def do_GET(self) -> None:
        if self.path == "/v1/status":
            self.write_json(HTTPStatus.OK, {
                "service": "tachi",
                "protocolVersion": 1,
                "status": "ready",
            })
        else:
            self.write_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})

    def write_json(self, status: HTTPStatus, body: dict) -> None:
        encoded = json.dumps(body, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, format: str, *args: object) -> None:
        # Request targets can include secret query parameters. Keep them out of logs.
        pass
