"""HTTP entry points shared by the native clients."""

import json
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler

from .hosts import AccessDenied, AccountStore


class CoordinatorHandler(BaseHTTPRequestHandler):
    server_version = "Tachi"

    def __init__(self, *args, accounts: AccountStore | None = None, **kwargs):
        self.accounts = accounts
        super().__init__(*args, **kwargs)

    def do_GET(self) -> None:
        if self.path == "/v1/status":
            self.write_json(HTTPStatus.OK, {
                "service": "tachi",
                "protocolVersion": 1,
                "status": "ready",
            })
        elif self.path == "/v1/client/me":
            self.client_identity()
        else:
            self.write_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})

    def client_identity(self) -> None:
        if self.accounts is None:
            self.write_json(HTTPStatus.SERVICE_UNAVAILABLE, {"error": "accounts_disabled"})
            return
        headers = self.headers.get_all("Authorization", [])
        parts = headers[0].split() if len(headers) == 1 else []
        if len(parts) != 2 or parts[0].lower() != "bearer":
            self.write_json(HTTPStatus.UNAUTHORIZED, {"error": "unauthorized"})
            return
        try:
            principal = self.accounts.authenticate(parts[1])
        except AccessDenied:
            self.write_json(HTTPStatus.UNAUTHORIZED, {"error": "unauthorized"})
            return
        self.write_json(HTTPStatus.OK, {
            "humanID": principal.human_id,
            "clientID": principal.client_id,
            "scopes": sorted(principal.scopes),
        })

    def do_POST(self) -> None:
        if self.path != "/v1/client/pair":
            self.write_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
            return
        if self.accounts is None:
            self.write_json(HTTPStatus.SERVICE_UNAVAILABLE, {"error": "accounts_disabled"})
            return
        if self.headers.get_content_type() != "application/json":
            self.write_json(HTTPStatus.UNSUPPORTED_MEDIA_TYPE, {"error": "expected_json"})
            return
        lengths = self.headers.get_all("Content-Length", [])
        if self.headers.get("Transfer-Encoding") or len(lengths) != 1:
            self.write_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_length"})
            return
        length = lengths[0]
        if len(length) > 4 or not length.isascii() or not length.isdecimal() or int(length) > 2048:
            self.write_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_length"})
            return
        try:
            raw = self.rfile.read(int(length))
            if len(raw) != int(length):
                raise ValueError("incomplete body")
            data = json.loads(raw.decode("utf-8"))
            if not isinstance(data, dict) or set(data) != {"invitation"} or not isinstance(data["invitation"], str):
                raise ValueError("invalid invitation object")
        except (ValueError, RecursionError):
            self.write_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_request"})
            return
        try:
            client = self.accounts.redeem_client(data["invitation"])
        except AccessDenied:
            self.write_json(HTTPStatus.UNAUTHORIZED, {"error": "unauthorized"})
            return
        self.write_json(HTTPStatus.CREATED, {"clientID": client.client_id, "token": client.token})

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
