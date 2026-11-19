# Onboard a Swift v1 adapter

Start with the person's existing assistant harness. It owns sign-in, subscriptions, conversation selection, model choices, tools, and approval prompts. Register an adapter after the harness supplies an authorized binding. When discovery cannot attach to an existing assistant, leave it unregistered. A Tachi-managed harness would need its own registration, identity, host selection, and explicit resource grants.

## Run the worked consumer

Use Swift 6.0 or later. On Ubuntu install `libsqlite3-dev`, `libcurl4-openssl-dev`, and `pkg-config`. From a checkout containing this guide:

```sh
swift test --package-path Examples/AdapterOnboarding -Xswiftc -warnings-as-errors
```

The example is a separate Swift package. To exercise the same imports from outside the repository, start at the checkout root:

```sh
export TACHI_PACKAGES="$PWD/Packages"
consumer=$(mktemp -d)
cp Examples/AdapterOnboarding/Package.swift "$consumer/"
cp -R Examples/AdapterOnboarding/Tests "$consumer/"
swift test --package-path "$consumer" -Xswiftc -warnings-as-errors
```

A new connector's manifest can use `.package(path: "/path/to/tachi/Packages/TachiRuntime")`. Add the product `TachiRuntime` to the connector target and `TachiAdapterConformance` from the same package to its test target. The worked example also imports `TachiGrok` to exercise the shipping adapter through an in-memory transport. All accounts, session IDs, and destinations in the example are synthetic. It runs offline with no provider credentials.

## Register a connector

Implement the public `Adapter` protocol with `version = 1`, a stable `AdapterIdentity`, a `Set<Capability>`, and an async throwing `dispatch(_:)`. Keep the provider, account, and assistant identifiers byte-exact. The registry snapshots the capabilities at registration. Declare only operations the authorized binding supports.

```swift
import TachiRuntime

func registeredConnector(_ adapter: any Adapter) async throws -> AdapterRegistry {
    let registry = AdapterRegistry()
    try await registry.register(adapter)
    return registry
}
```

Keep the registry for the binding's lifetime. Obtain an authorized session before constructing a request, then call `try await registry.dispatch(request)`. Each returned event must carry the request's exact identity, session ID, and request ID. Identical copies of one event collapse. A conflicting event ID or mismatched correlation makes the outcome uncertain. A caller-supplied correlation ID or an accepted webhook does not establish a provider conversation.

## Test your connector

Build the adapter with a scripted transport. Count **actual attempts at the transport boundary**, including attempts whose response is lost. Use a fresh fixture per test and call its checks sequentially. Supply the expected identity, session, and capabilities from your test case independently of the adapter.

```swift
import TachiAdapterConformance
import TachiRuntime

func checkLostSubmission(adapter: any Adapter, probe: DispatchRequest,
                         attemptCount: @escaping @Sendable () async -> Int) async throws {
    let suite = AdapterConformance(adapter: adapter, submissions: attemptCount)
    try await suite.checkRegistration(probe: probe, capabilities: [.task])
    try await suite.checkLostReply(to: probe)
}
```

- `checkRegistration` checks the advertised operations, duplicate registration, an unregistered account with the same assistant ID, and every unsupported v1 operation. These checks require zero transport attempts. An empty capability set is valid.
- `checkResponse(to:kinds:submitted:)` checks the ordered event kinds and submission count. Inspect its returned events for connector-specific payload and receipt semantics. A known local refusal can return a failed event with `submitted: false`.
- `checkLostReply` requires `RuntimeError.dispatchUncertain` after exactly one attempt. Registry dispatch alone has no persistent request ledger. The worked queue test closes its first queue and opens a new one on the same SQLite file. The ambiguous delivery retains its request ID and zero events, a queued successor stays held, and the new worker makes zero attempts.

The worked tests cover duplicate synthetic completions from `ReferenceAdapter`, the Grok adapter's task-only receipt and lost response, an unconfigured binding, and a deliberately broken fixture that submits twice. A Grok receipt reports `native_reply: false` and `native_session_observed: false`. Connector-specific evidence of a genuine native session, action, and retrievable result belongs in a separately authorized run. [Worked consumer](../Examples/AdapterOnboarding/Tests/OnboardingTests/ConnectorTests.swift) · [Native acceptance criteria](acceptance/README.md)
