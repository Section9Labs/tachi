# Tachi

Tachi is an independent, MIT-licensed assistant harness for iOS and macOS. It is being built to connect people to their existing assistants and let assistants from different providers work together. Provider identities, tools and approval flows stay with the original assistant runtime.

## Run the Swift coordinator

From the repository root, run `swift run tachi-coordinator` and request `http://127.0.0.1:8743/v1/status`. The default listener is loopback. Use `--port 0` for an available port or `--host` to set the listen address.

For a standalone Linux service, build and run the container:

```sh
docker build -t tachi-service .
docker run --rm -p 127.0.0.1:8743:8743 tachi-service
```

The image runs the release executable as an unprivileged user on Ubuntu 24.04. Linux CI packages the same executable as a downloadable amd64 archive. The Swift service currently serves the status endpoint. Pairing, team delivery and provider dispatch are being ported under [#55](https://github.com/Section9Labs/tachi/issues/55).

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
python3 -m tachi.hosts invite-client --db "$TACHI_DB" --human-id example-user \
  --scope sessions:read --out "$HOME/.local/state/tachi/first.invitation"
python3 -m tachi --db "$TACHI_DB"
```

The operator delivers the invitation privately to the intended person. Within five minutes the client sends `POST /v1/client/pair` with a JSON object containing the `invitation` string. A successful redemption returns HTTP 201 and the new `clientID` and `token`. Store the token in the client's credential store for that coordinator. `GET /v1/client/me` with bearer authorization returns the bound human, client and scopes. Remote clients require an HTTPS endpoint and a proxy that keeps credentials and request bodies out of logs. Revoking a client through `python3 -m tachi.hosts revoke-client` invalidates its bearer on the next request.
