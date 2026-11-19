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
