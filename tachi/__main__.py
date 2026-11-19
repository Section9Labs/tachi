"""Run the development coordinator with python3 -m tachi."""

import argparse
from contextlib import nullcontext
from functools import partial
from http.server import ThreadingHTTPServer
from pathlib import Path

from .hosts import AccountStore

from .http import CoordinatorHandler
from .runtime.reference_service import ReferenceTeams


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8743)
    parser.add_argument("--db", type=Path, help="enable client pairing with a SQLite file in a private directory")
    parser.add_argument("--reference-teams", action="store_true",
                        help="enable authenticated synthetic reference teams and their local worker")
    args = parser.parse_args()
    if args.reference_teams and not args.db:
        parser.error("--reference-teams requires --db")
    accounts = AccountStore(args.db) if args.db else None
    teams = ReferenceTeams(args.db, accounts) if args.reference_teams else None
    handler = partial(CoordinatorHandler, accounts=accounts, reference_teams=teams)
    with ThreadingHTTPServer(("127.0.0.1", args.port), handler) as server, (teams.worker() if teams else nullcontext()):
        print(f"Tachi listening on http://127.0.0.1:{server.server_port}", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
