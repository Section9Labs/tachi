"""Run the development coordinator with python3 -m tachi."""

import argparse
from http.server import ThreadingHTTPServer

from .http import CoordinatorHandler


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8743)
    args = parser.parse_args()
    with ThreadingHTTPServer(("127.0.0.1", args.port), CoordinatorHandler) as server:
        print(f"Tachi listening on http://127.0.0.1:{server.server_port}", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
