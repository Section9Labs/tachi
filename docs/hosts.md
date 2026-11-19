# Host pairing and folder grants

A Tachi owner can pair independent hosts and grant access to a folder on one of them. The coordinator stores pairing, session and grant state in SQLite. The host initiates pairing and each connection. No host address is required. The package uses the Python standard library. An existing harness keeps its identity and applies its own permissions to every operation.

## Pair and connect

Use `HostStore(db_path)` from `tachi.hosts` with a file in a coordinator-private directory. Only trusted coordinator code may access the database or call the owner methods. Supply `owner_id` from authenticated account context. Accepting it from a client request body would let the caller impersonate an owner.

1. Call `issue_pairing(owner_id)` after the owner approves pairing. Transfer the returned secret privately to the intended host. Whoever redeems it first can bind one host to that owner.
2. The host calls `pair(pairing_secret)` over an encrypted outbound channel after verifying the coordinator's identity. Redemption consumes the invitation and returns a new `HostCredential(host_id, secret)` in the same transaction. The invitation expires after 300 seconds. If the response is lost after commit, the owner can issue a fresh invitation.
3. The host keeps its credential in private device storage and calls `connect(credential)` for each new connection. The returned `HostSession(host_id, secret)` supersedes any previous session for that host immediately. Hold it with the live connection. Pairing alone gives no folder access.
4. The connection handler calls `heartbeat(session)` while it can confirm host liveness, comfortably inside the 30-second lease. Call `disconnect(session)` on observed closure. A silent loss denies access when coordinator time reaches the deadline. An expired session requires a new authenticated connection. Late heartbeats and disconnects from the old session cannot affect its replacement.

All store instances must use the same database and coordinator clock. Device timestamps play no role. SQLite holds only SHA-256 digests of the generated 256-bit bearer secrets. Keep invitations, device credentials and session secrets out of task records, logs and diagnostics.

## Authorize work at execution

| Method | Authority and effect |
| --- | --- |
| `grant(owner_id, host_id, folder_id, action) -> grant_id` | The authenticated host owner grants one exact `read` or `write` action on one host-local folder handle. The same handle on another host is independent. |
| `authorize(owner_id, session, grant_id, folder_id, action, relative_path)` | Returns `None` only when the session is current, its lease is live and the named grant matches every scope field. Policy denials raise `AccessDenied`. |
| `revoke_grant(owner_id, host_id, grant_id)` | Removes that grant. Another connection checking after commit sees the revocation immediately. |
| `revoke_host(owner_id, host_id)` | Invalidates the device credential, current session and all of its grants in one transaction. Pairing again produces a new host identity. |

Runtime can persist the authenticated owner, target host, grant, folder handle, action and relative path with queued work. The registry routes the request. The host-side executor must match the target host to its connection and request a fresh coordinator authorization using that session immediately before **each** local effect, including a retry. Stop on denial or an unavailable coordinator. A queued job or a previous successful check conveys no continuing authority. Revocation applies to subsequent checks. Work already authorized or in flight can require separate cancellation and reconciliation.

The host maps an opaque folder handle to a specific owner-approved local directory. Never rebind a handle to a different directory while its grants exist. The store validates the relative path as slash-separated components and rejects absolute paths, dot components, empty components, backslashes, colons and control characters. The executor must use the checked path without a second decoding or expansion step. Only the host can enforce filesystem containment at the actual open, including symlinks, concurrent renames and platform-specific aliases. Use the host's confined filesystem primitive and check its native permissions. The coordinator performs no filesystem I/O on the requested path.

## Acceptance evidence

Run the deterministic store tests from the repository root.

```sh
python3 -m unittest discover -s tests -p 'test_hosts*.py' -v
```

The tests pair synthetic hosts independently, grant different owners access to identically named folders, reject cross-owner administration and reject a second host under the same owner using the first host's grant. Two store instances share a database. The cases cover simultaneous pairing redemption, queued-work rechecks following revocation, disconnect, silent loss, replacement sessions and device revocation across store reopen.

HTTP transport, account authentication, executor filesystem confinement, end-to-end cancellation and QA's mixed-host exercise belong to their respective integration stages. The policy package needs no T3 installation, Git checkout, Mac or tailnet on an end user's device.

## Design references

- T3 Code documents single-use pairing, persistent device authorization, alternative routes to one machine and explicit device revocation. Tachi adopts the separation between reaching a host and authorizing it. The reference is pinned at `0226239a41e1fd0649fdd2562421d8950db7f39c`, under MIT. [Remote access](https://github.com/pingdotgg/t3code/blob/0226239a41e1fd0649fdd2562421d8950db7f39c/docs/user/remote-access.md) · [License](https://github.com/pingdotgg/t3code/blob/0226239a41e1fd0649fdd2562421d8950db7f39c/LICENSE)
- Tailscale documents approval before network admission, application grants and device removal. A private route can carry an outbound host connection. Tachi still checks the host's credential and folder grant. Documentation reviewed November 18, 2026. The approval and removal pages show a January 5, 2026 validation date. [Device approval](https://tailscale.com/docs/features/access-control/device-management/device-approval) · [Grants](https://tailscale.com/docs/features/access-control/grants) · [Remove a device](https://tailscale.com/docs/features/access-control/device-management/how-to/remove)
- The public Tailscale client repository identifies its license as BSD-3-Clause at revision `c4d689ce42ac11ca70a546c6ed8958e88d05a573`. That license identifies the client source. The web documentation above is cited by reference. The Tachi implementation is original MIT code with no vendored upstream material. [Client license](https://github.com/tailscale/tailscale/blob/c4d689ce42ac11ca70a546c6ed8958e88d05a573/LICENSE)

## Human client pairing

On the coordinator, a local operator assigns a stable human ID and chooses the operations allowed on each client. Reuse the exact human ID when pairing another client for that person. Use a new human ID for each account and never recycle one. From a directory private to the operator, run the following command with the coordinator's database path.

```sh
python3 -m tachi.hosts invite-client --db coordinator.sqlite --human-id person-a \
  --scope sessions:read --scope messages:send --out client.invitation
```

The command creates a new owner-readable file (mode 0600) and writes nothing to stdout or stderr on success. Deliver its contents privately to the intended client and remove the file after redemption. The invitation expires after five minutes. Only the local operator may call `AccountStore.issue_client_invitation(human_id, scopes)`. The CLI's authority comes from the operating system account with write access to the coordinator database.

- `redeem_client(invitation) -> ClientCredential(client_id, token)` consumes the invitation once and issues a per-client bearer. The client cannot choose its human ID or scopes at redemption.
- `authenticate(token) -> ClientPrincipal(human_id, client_id, scopes)` resolves the bearer for each request. The client keeps its token in secure storage. A request handler must derive the origin from this principal, exclude authentication headers, cookies and bodies from logs, and store only nonsecret origin IDs with queued work.
- `authorize_client(human_id, client_id, scope)` rechecks the originating client in SQLite immediately before a trusted worker dispatches an effect. `sessions:read` covers status and history, `messages:send` covers addressed turns, and `teams:manage` covers team and run administration. The worker must also verify the current grants on the specific resource. The registry can do the client recheck without a bearer.
- `list_clients(human_id)` lists that human's active client IDs. `revoke_client(human_id, client_id)` removes one client. Both methods are operator-only. CLI equivalents are `list-clients --db … --human-id …` and `revoke-client --db … --human-id … --client-id …`. The next authentication and dispatch recheck fail for that client, including on a separate store connection.

Client tokens are independent of host credentials. Local bootstrap and revocation are available through the CLI. The lead owns HTTP redemption, bearer handling and resource enforcement at the coordinator entry points.

### Team membership

`AccountStore` owns the human roster. The coordinator supplies the authenticated human and client IDs to each mutation. The queue owns runs, assistant addresses, and resource-specific access.

| Method | Result |
| --- | --- |
| `create_team(human_id, client_id, team_id)` | A client with `teams:manage` creates an unused team ID and its sole owner in one transaction. |
| `invite_member(human_id, client_id, team_id, recipient_id)` | The owner with `teams:manage` issues a five-minute invitation for one specific human. Reissuing replaces the pending invitation. Revoking the issuing client withdraws its outstanding invitations. |
| `accept_invitation(human_id, client_id, invitation)` | A current client for the invited human consumes the invitation and receives a `TeamMembership` with role `member`. Acceptance preserves the client's existing scopes. |
| `revoke_member(human_id, client_id, team_id, recipient_id)` | The owner with `teams:manage` withdraws a pending invitation or removes membership in one transaction. The owner role is retained. |
| `authorize_team(human_id, client_id, team_id, scope)` | Checks current client scope and current team role. Returns `owner` or `member`. Only owners may use `teams:manage` within the team. |
| `authorize_membership(human_id, client_id, team_id, scope, *, membership_id=None)` | Also returns the unique ID for this period of membership. Supplying an ID requires an exact match. |
| `team_membership(team_id, human_id)` and `team_role(team_id, human_id)` | Trusted recipient lookups return the current membership or role, respectively, or `None`. |

At ingress, capture the originating human, client and membership ID with a pending turn. Before each dispatch, including an assistant handoff, pass that membership ID to `authorize_membership`. Removal immediately denies new checks, and rejoining creates a fresh ID. For human DMs the queue can bind recipient access to the recipient's membership ID as well. Room history, DMs, provider accounts, assistant bindings, and artifacts each require their own resource checks. Device and folder grants remain host-specific. Effects already submitted may require reconciliation.

## Local Mac folder executor

The operator selects one existing directory. Each selection gets a fresh opaque folder ID, tied to the open directory and paired host for the life of that selection. Reconnecting the same host can reuse the selection. Closing it and opening another directory requires the owner to issue new grants.

### Try it with a synthetic coordinator

These commands use a temporary folder on a Mac with Python 3.11 or later. Run them from the checkout.

```sh
python3 -m tachi.hosts.folder_demo capabilities
folder=$(mktemp -d)
folder=$(cd "$folder" && pwd -P)
printf 'Synthetic brief\n' | python3 -m tachi.hosts.folder_demo write --folder "$folder" brief.txt
python3 -m tachi.hosts.folder_demo read --folder "$folder" brief.txt
```

The demo pairs a temporary host, grants exactly the requested action and uses a local SQLite transport stub. Each invocation discards its temporary coordinator state. The file remains in the selected directory. Read emits file bytes on stdout. Write reads bytes from stdin and preserves an existing destination. The physical path from `pwd -P` avoids macOS symlink aliases such as `/var`.

### Runtime contract

```python
from tachi.hosts.local_folder import FolderExecutor
from tachi.runtime.queue import HostScope

# In the trusted host process, keep the selection open across operations.
with FolderExecutor(selected_folder, local_session.host_id, store.authorize) as executor:
    # The owner grants an action for executor.folder_id using the coordinator.
    # The adapter receives a coordinator-authored scope after queued dispatch.
    scope = HostScope(**request.payload["_tachi_host_scope"])
    result = executor.execute(scope, local_session, body=write_bytes_or_none)
```

The six fields are `owner_id`, `host_id`, `grant_id`, `folder_id`, `action` and `relative_path`. The session comes from the host connection. Body bytes travel separately in this stub. A read takes no body and returns bytes. A write takes bytes and returns `None`. The authorizer must return `None` on approval and raise on denial or unavailability. The executor checks the grant immediately before publication and again before releasing read bytes. A revocation after publication cannot undo that file creation.

### Filesystem boundary

- The Mac opens the selected directory with `O_DIRECTORY | O_NOFOLLOW_ANY` and retains its descriptor. Paths to the selection containing symlinks fail. If another process renames that directory and replaces the old pathname, operations still target the selected directory object.
- Only **direct children** are supported. Paths with a slash fail before filesystem access, including when another process moves an intermediate directory. Reads accept only singly linked regular files. The executor checks the opened descriptor and the current entry beneath the root, rejects symlinks and changed identity or change time, and withholds the result on a mismatch. Other processes can still rename files after an operation completes.
- A write prepares at most 1 MiB in an unlinked temporary file, rechecks authority and publishes the complete file with one root-relative `fclonefileat` call. A pre-existing regular file, hard link, or symlink prevents publication. The executor never opens the destination for subsequent writes. The selected volume must support cloning from the system temporary volume. Unsupported platforms, cross-volume writes and unsupported filesystems fail closed. [Apple clonefile manual](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/clonefile.2)
- The same 1 MiB limit applies to a read. This increment has no directory listing, nested traversal, overwrite or removal operation. Nested access and an authenticated remote transport remain follow-ups under #22.

Run `python3 -W error -m unittest discover -s tests -p 'test_hosts_local_folder.py' -v` on macOS. The mixed-host fixture pairs two synthetic hosts on one Mac and sends separate turns through TeamQueue. While the first host is disconnected, a reference cloud adapter completes and the second host publishes a real file. Reconnecting the first host publishes its queued file once. Revoking its grant blocks the next write. The fixture uses local bytes and makes no live provider or cross-machine connection.
