"""Run one local Mac folder operation with an ephemeral coordinator and paired host."""

import argparse
import json
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

from tachi.runtime.queue import HostScope

from . import AccessDenied, HostStore
from .local_folder import MAX_BYTES, FolderExecutor, capabilities


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    commands.add_parser("capabilities")
    for action in ("read", "write"):
        command = commands.add_parser(action)
        command.add_argument("--folder", required=True, help="absolute path to your selected directory")
        command.add_argument("name", help="one direct child of the selected folder")
    args = parser.parse_args()
    if args.action == "capabilities":
        print(json.dumps(capabilities()))
        return

    try:
        with TemporaryDirectory() as state:
            store = HostStore(Path(state) / "stub.sqlite")
            owner = "local-demo"
            session = store.connect(store.pair(store.issue_pairing(owner)))
            with FolderExecutor(args.folder, session.host_id, store.authorize) as executor:
                grant = store.grant(owner, session.host_id, executor.folder_id, args.action)
                scope = HostScope(owner, session.host_id, grant, executor.folder_id, args.action, args.name)
                if args.action == "write":
                    executor.execute(scope, session, body=sys.stdin.buffer.read(MAX_BYTES + 1))
                else:
                    sys.stdout.buffer.write(executor.execute(scope, session))
    except (AccessDenied, ValueError, NotImplementedError) as error:
        parser.exit(1, f"{error or 'operation denied'}\n")
    except OSError as error:
        parser.exit(1, f"{error.strerror}\n")


if __name__ == "__main__":
    main()
