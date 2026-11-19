"""Run the development coordinator with python3 -m tachi."""

import argparse
from functools import partial
from http.server import ThreadingHTTPServer
from pathlib import Path

from .hosts import AccountStore

from .http import CoordinatorHandler


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8743)
    parser.add_argument("--db", type=Path, help="enable client pairing with a SQLite file in a private directory")
    args = parser.parse_args()
    accounts = AccountStore(args.db) if args.db else None
    handler = partial(CoordinatorHandler, accounts=accounts)
    with ThreadingHTTPServer(("127.0.0.1", args.port), handler) as server:
        print(f"Tachi listening on http://127.0.0.1:{server.server_port}", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
