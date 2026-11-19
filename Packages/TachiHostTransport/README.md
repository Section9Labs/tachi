# Optional host transport

The Swift sidecar serves only `/v1/host/` on loopback and opens the coordinator's existing SQLite file. A Mac agent initiates every connection and requires only its local credential, selected folder and private receipt directory. TeamQueue owns work state and request IDs. The solo coordinator and its HTTP routes run independently.

## Run locally

Build with `swift build --package-path Packages/TachiHostTransport`. On Linux the sidecar needs SQLite and OpenSSL development headers at build time. The filesystem agent requires macOS. The following commands assume the two resulting executables are on PATH, and use an operator-private working directory.

```sh
tachi-host-sidecar serve service.sqlite 8744
```

In another terminal, the operator creates an invitation for the authenticated owner's stable ID and delivers the file privately. On the host, select a physical directory and keep the agent running.

```sh
tachi-host-sidecar invite service.sqlite person-a new.invitation
tachi-host-agent pair 8744 new.invitation host.key
mkdir -m 700 receipt-state
tachi-host-agent run 8744 host.key /absolute/physical/selected-folder receipt-state
```

The agent prints a public host ID and a fresh folder handle once ready. Grant each action explicitly. The local operator commands below use an existing team and run. `client.token` contains the authenticated human client's bearer. Keep state and credential files outside the selected directory.

```sh
tachi-host-sidecar grant service.sqlite person-a HOST FOLDER write
tachi-host-sidecar bind service.sqlite client.token TEAM folder-helper
printf 'Synthetic brief\n' | tachi-host-sidecar post service.sqlite client.token TEAM RUN folder-helper message-1 HOST GRANT FOLDER write brief.txt
tachi-host-sidecar revoke service.sqlite person-a HOST GRANT
```

Reuse the same message ID when retrying a post. A process restart creates a new folder handle that the owner must grant explicitly. Work for the old handle stays queued until the operator intervenes. Renewals and reconnects in the same process retain the selected directory.

## Wire contract

Every route takes a bounded JSON POST. The bearer travels in the Authorization header. Connect and session routes also require the nonsecret `X-Tachi-Host` header. Responses use `Cache-Control: no-store`. There are no owner administration routes on the host listener.

| Route suffix | Credential and behavior |
| --- | --- |
| `pair` | One-time invitation and empty object. Returns the device ID and credential. |
| `connect` | Device credential and empty object. Rotates the 30-second session. |
| `heartbeat`, `disconnect` | Current session and empty object. Renew or release presence. The agent renews every eight seconds while polling. |
| `next` | Current session and `folderID`. Claims at most one matching queued task and returns its request ID, six-field scope and optional base64 body. An empty result has no work. |
| `check` | Current claiming session, request ID, exact scope. Checks live client, original team membership generation, running state, lease and matching host grant. |
| `finish` | Current session of the same paired device. Reports the request ID, completed or refused outcome, and byte count. Identical reports are idempotent. A conflicting report fails. |

A numeric port selects HTTP on trusted single-user loopback for local operation. For another machine the agent accepts only an HTTPS origin. Use a separately operated TLS endpoint that forwards to the loopback sidecar. The client uses platform certificate verification, binds its credential file to the selected origin and disallows redirects. Protect the loopback port from replacement by untrusted local processes, and exclude auth headers and bodies from proxy logs.

The Mac agent uses system trust by default. For a private issuer, pass `--ca-der /path/to/issuer.der` before both `pair` and `run`, using the same HTTPS origin. Obtain the public CA certificate from the operator through a trusted channel. This option selects that CA as the sole trust anchor for the invocation. macOS verifies the certificate chain, validity and requested hostname. Keychain trust settings are unchanged.

## Work and reconciliation

Bind an assistant using provider `tachi-folder` and post a directly addressed `task` with Runtime's existing `HostScope`. For a read, post an empty payload. For an exclusive create, set `bodyBase64` to canonical base64 encoding up to 1 MiB. Only direct children of the pinned directory can be touched. A read returns a byte count in the delivery event. File contents would require an artifact delivery policy.

The sidecar checks the durable origin and exact host grant, then commits the existing delivery row as uncertain **before** returning the work. The agent asks the sidecar to check its actual scope again at each FolderExecutor authorization point. Grant revocation after final authorization can overlap an already authorized effect.

After execution, the agent saves a receipt in its private state directory before sending it. On reconnect or process restart, it resends that receipt with the original request ID. A replacement session can report an outcome but cannot authorize an old claim for execution. If a handout or an observation is lost, the original row stays uncertain. An ambiguous effect is never republished by this transport. Leave that delivery for operator reconciliation. The sidecar records only the sanitized outcome and byte count, and file data stays out of receipts.

## Verification

```sh
swift test --package-path Packages/TachiHostTransport -Xswiftc -warnings-as-errors
PYTHONPATH=. python3 -W error Packages/TachiHostTransport/Tests/Acceptance/process_lab.py Packages/TachiHostTransport/.build/debug
PYTHONPATH=. python3 -W error Packages/TachiHostTransport/Tests/Acceptance/process_lab.py Packages/TachiHostTransport/.build/debug --https
```

The process lab exercises actual Swift binaries and files on one Mac, using Python for setup and observation. With `--https`, it uses the OpenSSL CLI to generate a disposable CA and localhost certificate in a private temporary directory. Both agents initiate HTTPS connections to a loopback TLS proxy. Pairing fails with an unknown issuer or mismatched hostname before an invitation reaches the proxy's HTTP handler.

The proxy drops one host's connections until its lease expires. The other host renews and publishes its file. After reconnection, the lab withholds the first host's completion, restarts its agent and the sidecar, and checks for one terminal event on the original request and unchanged file identity and timestamps. It also pauses a claimed write before the sidecar receives the execution check, revokes the grant, and verifies a 403, a zero-byte refusal and an absent file. Subsequent work on that grant stays blocked. Deployment through a remote TLS endpoint and physical cross-machine effects remain separate acceptance steps.
