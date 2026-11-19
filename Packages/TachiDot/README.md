# Linux operator image for the Dot plugin

This standalone image serves the existing `read_connection_sample` MCP tool. A gateway on the same Linux host terminates HTTPS. The Swift process listens on IPv4 loopback. A separate OAuth issuer supplies the user's existing grant and verifies it through introspection on every call.

## Obtain the image

The **Linux Dot plugin** workflow builds the image, runs the production entry point behind a local TLS gateway, and checks its reply against the private receipt file. It exports the tested linux/amd64 Docker archive plus a SHA-256 checksum as a seven-day workflow artifact. The image tag and artifact name include the full revision checked out by the workflow. Pull request builds use the reviewed head revision. For example, download a specific successful run with `gh run download RUN_ID --repo Section9Labs/tachi --pattern 'tachi-dot-plugin-linux-amd64-*' --dir ./dot-download`. In the extracted artifact directory run:

```sh
sha256sum -c SHA256SUMS
docker load -i tachi-dot-plugin-linux-amd64.tar.gz
```

Use the tag printed by `docker load` as `DOT_IMAGE` below. To build from the current checkout on a Linux machine instead:

```sh
DOT_IMAGE="tachi-dot-plugin:$(git rev-parse HEAD)"
docker build -t "$DOT_IMAGE" Packages/TachiDot
python3 -W error Packages/TachiDot/Tests/container_https.py "$DOT_IMAGE"
```

The probe generates a temporary test CA and grants, makes requests over loopback, and removes its test containers. It exercises protected resource metadata, MCP initialization and catalog discovery, a tool-level OAuth challenge, authorized readback, receipt persistence across container replacement and revoked access. It requires a Linux Docker host with host networking, Python 3 and OpenSSL. Production startup requires only the built image and the operator's gateway, issuer and persistent receipt directory.

## Run with an existing gateway and issuer

Choose a dedicated unprivileged Linux user. Create the trial directory as that user and use a fresh directory for each acceptance run:

```sh
umask 077
mkdir -m 700 ./dot-trial
touch ./dot-trial.env
chmod 600 ./dot-trial.env
```

Using a private editor or secret manager, populate the environment file. The following entries are placeholders. The Basic value is the base64 encoding of the credential issued **to this resource server** for its introspection request. Treat the environment file and Docker daemon access as privileged.

```dotenv
TACHI_DOT_RESOURCE=https://plugin.example.org/mcp
TACHI_DOT_ISSUER=https://identity.example.org
TACHI_DOT_INTROSPECTION=https://identity.example.org/oauth/introspect
TACHI_DOT_INTROSPECTION_BASIC=<operator-provisioned-base64-credential>
TACHI_DOT_SUBJECT=<authorized-Tachi-subject>
TACHI_DOT_PORT=8745
```

```sh
docker run -d --name tachi-dot-plugin \
  --network host --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  --user "$(id -u):$(id -g)" --env-file ./dot-trial.env \
  --mount "type=bind,src=$PWD/dot-trial,dst=/var/lib/tachi-dot" \
  "$DOT_IMAGE"
```

Host networking lets the existing host gateway reach `127.0.0.1:8745`. Restrict both gateway routes to the configured public hostname. Forward the path, POST body, Authorization and content negotiation headers and preserve the response's OAuth challenge. For example, these locations go **inside the operator’s existing HTTPS NGINX server**:

```nginx
location = /mcp {
    proxy_pass http://127.0.0.1:8745;
    proxy_set_header Authorization $http_authorization;
}
location = /.well-known/oauth-protected-resource/mcp {
    proxy_pass http://127.0.0.1:8745;
}
```

Use the issuer's exact HTTPS identifier and the full resource URL as token audience. Configure the issuer to return an active bearer token with the authorized subject, expiration and `sample.read` scope. The container validates TLS for introspection. For a private CA, mount the operator's PEM trust bundle read-only at `/etc/ssl/certs/ca-certificates.crt`. Keep credentials out of proxy logs. Recreating the container with the same configuration and mounted directory preserves the owner-bound receipt.

Verify the metadata URL through your gateway and compare its resource and issuer with your configured values. In the authorized workspace, enable the MCP server as described in the [plugin setup](../../docs/providers/dot.md#connect-an-authorized-deployment). Once the user has authorized the grant and confirmed included quota, ask the selected existing Dot to read its Tachi connection sample. Compare the visible tool return with the `sample` field in `dot-trial/receipt.json` privately. The image qualification itself exercises a synthetic client and issuer. Live Dot identity, native turn and result retrieval still require separate evidence.
