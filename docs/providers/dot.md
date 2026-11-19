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

## Native acceptance still needed

A documented grant for Tachi to select the existing Dot is the first missing dependency. With that grant, bind the provider’s stable account and assistant identifiers and preserve its conversation identifier as the v1 session. Ask the Dot in a fresh conversation to create a text file containing `Tachi sample 42` on its own computer. Record a provider-native task or tool event, disconnect, then retrieve the same work and verify the file contents after reconnecting. A lost submission reply must surface as `DispatchUncertain`; recovery must avoid a second submission. Publish only the operation, outcome and whether the identities matched. Keep native identifiers and session links private.
