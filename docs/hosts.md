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
