# OpenAI Dot

**Status, 2026-11-18.** Tachi has verified public sign-in metadata and inspected the Codex protocol. We have not identified a documented third-party operation that binds a Tachi sign-in to the account’s existing Dot and opens a native conversation. The runtime therefore registers no Dot adapter and advertises no v1 capabilities. Issue [#3](https://github.com/Section9Labs/tachi/issues/3) remains open.

## Capability evidence

“Reference” means read-only inspection of another client’s behavior notes. The reference client was not run. The Tachi live column records only operations performed through a fresh Tachi connection to a real Dot.

| Operation | Reference behavior | Independent Tachi live proof |
| --- | --- | --- |
| Account and existing Dot identity | The signed-in account selects its existing Dot and can read its profile and linked work. | Unavailable. Public issuer discovery succeeded anonymously. No user grant or Dot identity was acquired. |
| Fresh conversation and `message` | The client can present a conversation with the selected Dot. | Unavailable. No native conversation created or message sent. |
| `task` | The client displays work linked to the Dot and opens a task to inspect its progress. | Unavailable. No task submitted or result retrieved. |
| `tools` | The reference distinguishes Dot-owned work, connected computer permissions and local helper actions. | Unavailable. No native tool invocation observed through Tachi. |
| `attachment` | The reference records attachment presentation with fixtures. | Unavailable. No native upload or download verified. |
| `cancel` | Native cancellation was not established by this inspection. | Unavailable. No cancellation attempted. |
| Reconnect and `recover` | The reference describes returning to linked work by its existing identity. | Unavailable. No reconnect or readback of the same result. |

## Public interfaces checked

- OpenAI’s open-source Sign in with ChatGPT flow lets a client register under its own name. Account identity and optional subscription-funded inference have distinct grants. Neither documents access to existing ChatGPT conversations. Starting an inference thread would leave the selected Dot unidentified. [Registration and sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in) · [Scope of the grant](https://developers.openai.com/siwc/token-sharing-open-source)
- ChatGPT lets people communicate with their Dot and review its tasks. A linked phone or Slack account is a separate user-facing channel. The documented plugin event flow starts when ChatGPT subscribes on the user’s behalf. Its webhook receipt confirms delivery to the subscription. It does not identify a newly opened Dot conversation or carry the completed result. [Getting started with your dot](https://help.openai.com/en/articles/20001530-getting-started-with-your-dot) · [MCP Events](https://developers.openai.com/plugins/build/mcp-events)
- OpenAI’s public issuer metadata returned HTTP 200 and declared OpenID and S256 PKCE. Codex CLI 0.169.0 generated 109 distinct stable and 184 experimental-inclusive client request methods. Both schemas include login, thread start, turn start and thread resume. Neither contains a method name with the substring `dot`. Inspection of the generated start/resume parameters also found no explicit existing-Dot selector. These findings apply to the inspected protocol version. [Issuer metadata](https://auth.openai.com/.well-known/openid-configuration) · [Codex app-server](https://developers.openai.com/codex/app-server)

## Reproduce discovery

Run from the source tree with Python and the Codex CLI. The temporary Codex home isolates schema generation. Only the public metadata download uses the network. This is an engineering check, independent of product sign-in.

```sh
(
  set -eu
  scratch=$(mktemp -d)
  trap 'rm -rf "$scratch"' EXIT
  export CODEX_HOME="$scratch/codex"
  mkdir -p "$CODEX_HOME"
  curl --fail --silent --show-error https://auth.openai.com/.well-known/openid-configuration -o "$scratch/issuer.json"
  codex --version
  codex app-server generate-json-schema --out "$scratch/stable"
  codex app-server generate-json-schema --experimental --out "$scratch/experimental"
  for variant in stable experimental; do
    python3 -m tachi.providers.dot.discovery "$scratch/issuer.json" "$scratch/$variant/ClientRequest.json"
  done
)
python3 -m unittest discover -s tests -p 'test_dot*.py'
```

The inspector projects allowlisted method names and counts. A new Dot-named declaration prompts a documentation review. Schema presence alone never grants a runtime capability.

## Experimental plugin attachment

**Verified locally.** The plugin application layer in `tachi/providers/dot/claim_check.py` builds event and tool catalogs, signs webhook bytes, and correlates a synthetic result to a verified subscription lease in SQLite. The fixture supplies an authenticated-owner context and echoes the signed callback challenge in memory. It exercises the same tool handlers a plugin gateway would call. Run `python3 -m unittest discover -s tests -p 'test_dot_claim_check.py' -v`.

**Provider flow.** The account holder selects their existing Dot and asks it to monitor a Tachi event. ChatGPT initiates the subscription in that context. Tachi receives no documented stable Dot identifier or fresh conversation identifier in the subscription contract. The Tachi owner comes from its own plugin authorization. [OpenAI MCP Events](https://developers.openai.com/plugins/build/mcp-events) · [Plugin authentication](https://developers.openai.com/plugins/build/auth)

| Step | Provider and Tachi responsibilities | Evidence in this increment |
| --- | --- | --- |
| Discover and consent | A reachable authenticated MCP server advertises `events` and `tools` in Streamable HTTP initialization, or through MCP 2.0 discovery. The workspace must allow the plugin and event-triggered tasks. The owner connects their Tachi account, authorizes the sample tools and tells the selected Dot how to respond. | `event_catalog()` and `tool_catalog()` produce the result bodies for `events/list` and `tools/list`. No endpoint or consent screen has been installed. |
| Subscribe and verify | ChatGPT calls `events/subscribe` with `tachi.sample.ready`, empty filter arguments, webhook URL and signing secret. The gateway authenticates the principal, authorizes the event, and derives the subscription ID from that owner, URL, event name and canonical filters. It verifies the callback with a short-lived signed challenge and a matching echo on a 2xx response. | `verify_callback` signs a fresh challenge and checks the timely, successful echo from the gateway’s destination-bound transport. After validation the gateway calls `activate(owner, subscription, expires)`. The SQLite store keeps the finite lease and no callback credentials. |
| Issue and deliver | For a producer request, `event` stores two synthetic counts and emits a stable event ID, timestamp, null cursor, subscription ID and opaque claim. A separately authorized delivery worker addresses the active callback, signs the exact serialized bytes and posts one event. A retry keeps the event ID and uses a new signing timestamp. | The signer returns the bytes and Standard Webhooks headers, including the subscription ID. Duplicate and concurrent producer requests reuse the same sample. Delivery through ChatGPT has not been exercised. |
| Read and return | Under the user’s instruction, ChatGPT can call `read_sample(subscription, claim)` and then `return_sample_total(subscription, claim, total)` through MCP `tools/call`. The gateway derives the Tachi owner and scopes from a current access token for this resource on **each** call. The subscription and claim in tool arguments only select the sample. | The first tool requires `sample.read`. The second requires `sample.return`, checks the sum, and records it once. `returned_total` retrieves it by owner, subscription and producer request. Webhook acknowledgement never sets the result. |
| Refresh or stop | The gateway refreshes the same subscription when its owner, callback and filters match. It applies the granted TTL and handles key rotation. It processes `events/unsubscribe` for that owner's matching callback and filter, and stops delivery on expiry, account disconnect or loss of access. | Refresh preserves live claims. `deactivate` retires the lease and claims. Reattachment after expiry or revocation starts clean. The gateway must invalidate matching leases when access is withdrawn. |

**Operator trial once an endpoint is authorized.** The plugin must be available in the intended workspace, with the Tachi OAuth resource and tool scopes configured. Install or rescan the event and tool catalogs. In the selected Dot, ask “Monitor the Tachi synthetic sample event. For each sample, read its counts and return their sum using the Tachi tools.” Review any provider approval prompt. Issue one sample, verify the signed delivery receipt, then independently read the stored return. Reopen the same work in ChatGPT and check its native activity before attributing the operation to that Dot. Stop monitoring and verify the old claim is rejected.

**Remaining engineering and evidence.** The live gateway must validate OAuth issuer, audience, expiry, scopes and resource access, protect callback URLs and keys, and verify callback ownership before accepting subscriptions. For both verification and delivery, resolve and pin a public HTTPS destination at connection time, validate TLS, and disable redirects. Persist the verified callback and rotation state, recheck access before each send, and handle delivery timeouts and provider status codes. The bridge opens no listener and sends no network requests. Tools may be invoked by another authorized caller with the same owner, scope and claim. The fixture proves correlation and content, while native Dot identity, live execution, and independent conversation creation remain open. [Callback and delivery requirements](https://developers.openai.com/plugins/build/mcp-events)

## Native acceptance still needed

A documented grant for Tachi to select the existing Dot is the first missing dependency. With that grant, bind the provider’s stable account and assistant identifiers and preserve its conversation identifier as the v1 session. Ask the Dot in a fresh conversation to create a text file containing `Tachi sample 42` on its own computer. Record a provider-native task or tool event, disconnect, then retrieve the same work and verify the file contents after reconnecting. A lost submission reply must surface as `DispatchUncertain`; recovery must avoid a second submission. Publish only the operation, outcome and whether the identities matched. Keep native identifiers and session links private.
