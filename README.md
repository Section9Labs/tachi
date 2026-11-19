# Tachi

Tachi is an independent, MIT-licensed assistant harness for iOS and macOS. It is being built to connect people to their existing assistants and let assistants from different providers work together. Provider identities, tools and approval flows stay with the original assistant runtime.

## Run the development coordinator

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
