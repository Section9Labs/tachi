# ADR 1 · Where an assistant team runs

Accepted for bootstrap, November 2026.

The iPhone may be suspended, every Mac may be offline, and a provider may continue a job after its connection drops. A coordinator on a persistent Linux or hosted service owns the team's assignments, routing and delivery history. Swift clients present that state and retain pending local sends until they can reconcile them. Team members need no development tools.

## Alternatives

A phone-only relay loses its opportunity to deliver when the OS suspends the app. A Mac-only execution hub makes a personal computer a dependency for cloud work. A managed queue and separate database service support multiple workers, but introduce two additional systems to deploy and restore before we have evidence of that need.

Deploy one standalone Swift executable on Linux using SwiftNIO for HTTP and SQLite for durable state. The Apple clients communicate over versioned HTTP, so deployment and release of the service are independent of either app. Rust is also viable for a Linux daemon. Swift lets the Apple and service teams maintain typed contracts and review concurrency in one language. The Python bootstrap provides compatibility fixtures for the migration. Linux CI must exercise the release binary in its runtime image before distribution. SQLite transactions offer a recoverable outbox and a single-node backup boundary. Cross-node scheduling would require a later storage decision. The bootstrap HTTP listener binds to loopback. Network deployments require authenticated user routes and a TLS endpoint.

## Ownership and routing

The coordinator owns human accounts, team membership, invitations, task audiences, routing budgets, artifact grants and the delivery journal. Provider adapters own their transport and bind each external identity and conversation to its provider account. The provider owns native state, tools, approvals and completion. Creating an assistant identity and opening another conversation with it are distinct operations. Team work starts in a fresh conversation unless an authorized user explicitly shares an existing one.

Persist the addressed message and stable request ID before dispatch. Serialize work per provider session. Record provider acknowledgement, terminal reply and uncertain outcome separately. A worker that loses the result of a non-idempotent action must reconcile before another dispatch. A peer can reference an artifact only through an audience-scoped grant. Execution rechecks membership, grant and host availability. Revocation stops pending dispatch and future access; already issued effects require reconciliation. Enforce assignment budgets and accept pause or cancellation from an authorized person.

A cloud adapter opens an outbound provider connection and polls or subscribes for events. Callbacks require provider support, verifiable origin and an endpoint reachable from the provider. Optional hosts open outbound connections and bind capabilities to an explicit owner, host and grant. Tailscale can protect a private client or host route. Cloud adapters can operate outside that network. Each connector must demonstrate its real execution and return path.

## Evidence

The initial implementation serves a versioned availability response. The adapter contract, authorization, outbox, host transport, isolation and Apple workflows have separate issues and tests. A deterministic fixture proves contract behavior. Each live milestone requires evidence from the actual named assistant. T3 supplies development sessions only. This decision incorporates design ideas from its [remote access guide](https://github.com/pingdotgg/t3code/blob/0226239a41e1fd0649fdd2562421d8950db7f39c/docs/user/remote-access.md). No T3 source was copied for the bootstrap coordinator.
