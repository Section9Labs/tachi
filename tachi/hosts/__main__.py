"""Bootstrap or revoke a human client from the coordinator's local operator account."""

import argparse
import os

from . import AccessDenied, AccountStore
from .accounts import CLIENT_SCOPES


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    invite = commands.add_parser("invite-client", help="create a single-use client invitation")
    invite.add_argument("--scope", choices=sorted(CLIENT_SCOPES), action="append", required=True)
    invite.add_argument("--out", required=True, help="new private file to receive the invitation")
    revoke = commands.add_parser("revoke-client", help="revoke one human client's access")
    revoke.add_argument("--client-id", required=True)
    inventory = commands.add_parser("list-clients", help="list active client IDs for one human")
    for cmd in (invite, revoke, inventory):
        cmd.add_argument("--db", required=True, help="coordinator SQLite file in a private directory")
        cmd.add_argument("--human-id", required=True, help="stable operator-assigned human ID")
    args = parser.parse_args()
    store = AccountStore(args.db)
    try:
        if args.command == "invite-client":
            fd = os.open(args.out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as destination:
                destination.write(store.issue_client_invitation(args.human_id, args.scope) + "\n")
        elif args.command == "revoke-client":
            store.revoke_client(args.human_id, args.client_id)
        else:
            for client_id in store.list_clients(args.human_id):
                print(client_id)
    except AccessDenied:
        parser.exit(1, "operation denied\n")
    except FileExistsError:
        parser.exit(1, "invitation destination already exists\n")


if __name__ == "__main__":
    main()
