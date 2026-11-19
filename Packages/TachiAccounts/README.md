# TachiAccounts

Swift 6 package for the Tachi coordinator and local operator. On Linux install the SQLite and OpenSSL development packages (on Ubuntu, `libsqlite3-dev` and `libssl-dev`). macOS uses system SQLite and CommonCrypto. No network dependency is resolved by SwiftPM.

From the repository root:

```sh
swift build --package-path Packages/TachiAccounts -c release
swift test --package-path Packages/TachiAccounts
TACHI_PYTHON_ORACLE="$PWD" swift test --package-path Packages/TachiAccounts --filter MigrationTests
```

The optional migration test exercises both SQLite writers using the historical Python implementation. The service and CLI run entirely in native code.

### Client bootstrap

Run the operator commands in a directory accessible only to the coordinator account. Use the same database path as the server.

```sh
swift run --package-path Packages/TachiAccounts tachi-accounts invite-client \
  --db coordinator.sqlite --human-id person-a --scope sessions:read --out client.invitation
swift run --package-path Packages/TachiAccounts tachi-accounts list-clients \
  --db coordinator.sqlite --human-id person-a
```

The executable writes a five-minute, single-use invitation only to the new mode-0600 file. Deliver it privately. Revoke one client with `revoke-client --db PATH --human-id ID --client-id CLIENT`. SQLite stores SHA-256 digests. The three supported scopes are `sessions:read`, `messages:send` and `teams:manage`.

HTTP handlers call `AccountStore(path:)`, `redeemClient(invitation:)` and `authenticate(token:)`. A successful authentication returns `ClientPrincipal(humanID, clientID, scopes)`. Workers use `authorizeClient(humanID:clientID:scope:)` on the captured origin at execution time and check resource grants separately. `AccountsError.denied` signals an authorization failure. Database failures propagate separately. Do not log invitations, bearer tokens, or authentication bodies.

### Teams and paired hosts

`AccountStore` owns the human roster. `createTeam` creates the owner membership atomically. `inviteMember` binds a single-use invitation to the recipient and issuing client. `acceptInvitation` requires a current client for that human. `revokeMember` withdraws a pending invite or removes membership. `authorizeMembership(humanID:clientID:teamID:scope:membershipID:)` checks current client scope, team role and an optional captured membership generation. Store this generation with queued work and recheck it before dispatch. Trusted DM recipient checks can use `teamMembership(teamID:humanID:)`. Rejoining creates a new generation. Existing provider, artifact and host grants have separate checks.

`HostStore(path:)` reads and writes the original host tables. A local owner calls `issuePairing(ownerID:)`. The host calls `pair(pairingSecret:)` within five minutes, then `connect(credential:)` to obtain a rotating 30-second session. `heartbeat(session:)` renews a live lease. `disconnect(session:)`, `revokeGrant` and `revokeHost` take effect at the next authorization check. The worker passes its own live session and the exact owner, grant, folder, action and relative path to `authorize`. Only nonsecret identifiers belong in queue records.

### Mac folder executor

The `tachi-folder` tool runs local operations with temporary pairing and grants. Run `tachi-folder capabilities` for limits. With the absolute physical path to a selected directory, use `tachi-folder read --folder PATH NAME` to read to stdout or `tachi-folder write --folder PATH NAME` to exclusively create a file from stdin.

An adapter constructs `FolderScope(ownerID:hostID:grantID:folderID:action:relativePath:)` from the trusted queue scope. `FolderExecutor(folder:hostID:authorize:)` pins the operator-selected directory and supplies its own fresh `folderID`. Its authorization closure calls the coordinator before file effects and before releasing read bytes. `execute(_:session:body:)` accepts at most 1 MiB and only a direct child. Reads require a single-link regular file and recheck its identity in the selected directory. Writes use an unlinked staging file and atomically clone to a new destination on a compatible volume. Calling `close()` ends the selection. Linux builds the coordinator policy and rejects filesystem execution. Nested paths and authenticated cross-machine transport remain open.
