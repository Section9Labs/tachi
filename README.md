# Tachi

Tachi is an independent, MIT-licensed assistant harness for iOS and macOS. It is being built to connect people to their existing assistants and let assistants from different providers work together. Provider identities, tools and approval flows stay with the original assistant runtime.

Connector authors can [register a Swift v1 adapter and run the out-of-tree conformance suite](docs/adapter-onboarding.md).

## Run the Swift coordinator

From the repository root, run `swift run tachi-coordinator` and request `http://127.0.0.1:8743/v1/status`. The default listener is loopback. Use `--port 0` for an available port or `--host` to set the listen address.

On Ubuntu 24.04 amd64, install the packaged Swift executables as a [systemd service](docs/sqlite-recovery.md#install-the-standalone-service). To run in a container:

```sh
docker build -t tachi-service .
docker run --rm -p 127.0.0.1:8743:8743 tachi-service
```

The image runs under an unprivileged account on Ubuntu 24.04 and includes the Swift operator tool `tachi-accounts`. Linux CI packages both executables in the amd64 archive. See the [Linux deployment and recovery instructions](docs/sqlite-recovery.md) to pair clients and keep their data across container replacements. The Swift service serves status and client pairing. Pass `--db /path/to/coordinator.sqlite --reference-teams` to enable authenticated synthetic teams. Their worker can finish queued tasks while clients are offline and resumes eligible work when restarted. This mode uses reference assistants that count words. Native provider dispatch is being ported under [#55](https://github.com/Section9Labs/tachi/issues/55).

## Run the compatibility reference

From a checkout with Python 3.11 or newer, run:

```sh
python3 -m tachi
```

In a second terminal, request the service status:

```sh
curl --fail http://127.0.0.1:8743/v1/status
python3 -m unittest discover -s tests -v
```

A ready coordinator returns `{"service":"tachi","protocolVersion":1,"status":"ready"}`. Use `python3 -m tachi --port 0` to select an available loopback port. This bootstrap endpoint reports the coordinator's availability. Native assistant qualification and team delivery have separate acceptance milestones.

See the [architecture decision](docs/architecture.md), the [implementation issues](https://github.com/Section9Labs/tachi/issues) and the [milestone exit criteria](https://github.com/Section9Labs/tachi/milestones).

## Pair a client

Create a private state directory outside the checkout. Start the coordinator with the same SQLite path used by the invitation command.

```sh
umask 077
mkdir -p "$HOME/.local/state/tachi"
TACHI_DB="$HOME/.local/state/tachi/coordinator.sqlite"
swift run --package-path Packages/TachiAccounts tachi-accounts invite-client --db "$TACHI_DB" --human-id example-user \
  --scope sessions:read --out "$HOME/.local/state/tachi/first.invitation"
swift run tachi-coordinator --db "$TACHI_DB"
```

The operator delivers the invitation privately to the intended person. Within five minutes the client sends `POST /v1/client/pair` with a JSON object containing the `invitation` string. A successful redemption returns HTTP 201 and the new `clientID` and `token`. Store the token in the client's credential store for that coordinator. `GET /v1/client/me` with bearer authorization returns the bound human, client and scopes. Remote clients require an HTTPS endpoint and a proxy that keeps credentials and request bodies out of logs. Revoking a client through `tachi-accounts revoke-client` invalidates its bearer on the next request.

## Export a human workspace

A paired client with `sessions:read` can send an authenticated `GET /v1/workspaces/{workspace_id}/export` to a Swift coordinator started with `--db`. Use the workspace's lowercase canonical UUID. The JSON response contains `workspace_id`, ordered `messages`, and ordered `artifacts`. Each artifact includes its metadata and SHA-256-verified `content_base64`.

Current members can export room history. A direct message or artifact is visible to a sender or recipient whose current membership generation matches the one recorded when it was shared. Rejoining restores room history and starts a new generation for private exchanges.

The export returns the whole visible result up to 100 messages, 16 artifacts, and 4 MiB of decoded artifact content combined. Crossing any limit returns HTTP 413 with `{"error":"export_limit"}`. Private rows outside the caller's audience do not contribute to these limits.

## Assign workspace text to a Grok Bot routine

A workspace owner can share one of their configured Grok Bot routines with the room. Every current member with permission to send messages can then send assignment text to that routine. The assignment and its delivery state are visible to members with read access. See the [Grok provider guide](docs/providers/grok.md) for grant setup. The coordinator accepts the owner's private configuration through `--solo-routines-file`.

1. As the owner, use a paired client with `sessions:read` to list your enabled aliases at `GET /v1/solo/routines`.
2. With `teams:manage` and `messages:send`, send `POST /v1/workspaces/{workspace_id}/assistants` with `{"routine_id":"my-routine","allow_room_assignments":true}`. The response contains a workspace-local `assistant_id`, provider `grok-bot`, capability `task`, and `native_session_observed:false`.
3. As a member with `messages:send`, send `POST /v1/workspaces/{workspace_id}/assignments` with `assignment_id` (a fresh lowercase UUID), the returned `assistant_id`, and `text`. The webhook receives only the JSON object containing `text`. Use the same assignment ID and content if a client needs to retry.
4. Read `GET /v1/workspaces/{workspace_id}/assignments/{assignment_id}` with `sessions:read`. An HTTP 200 from the webhook leaves the assignment active. A lost response leaves it uncertain. Tachi preserves that state across restart and keeps the next assignment to that binding queued. Check Grok Bot for the provider's result.
5. To withdraw the grant, the owner sends `POST /v1/workspaces/{workspace_id}/assistants/{assistant_id}/revoke` with an empty JSON object. Revocation stops future dispatch. Work already submitted retains its recorded receipt or uncertainty.
