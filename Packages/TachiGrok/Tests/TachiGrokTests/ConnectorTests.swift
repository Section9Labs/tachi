import Foundation
import Testing
import TachiRuntime
@testable import TachiGrok

private func identity() throws -> AdapterIdentity {
    try AdapterIdentity(provider: grokBotProviderID, accountID: "synthetic-account", assistantID: "synthetic-bot")
}

private func taskRequest(_ id: AdapterIdentity, capability: Capability = .task) throws -> DispatchRequest {
    try DispatchRequest(
        identity: id,
        sessionID: "synthetic-session",
        requestID: "synthetic-request",
        capability: capability,
        payload: ["task": .string("Reply with the single word pong.")]
    )
}

private final class Posts: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0
    private(set) var last: WebhookCall?
    func record(_ call: WebhookCall) {
        lock.lock()
        count += 1
        last = call
        lock.unlock()
    }
}

private func decodeBody(_ data: Data) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: data)
}

@Test func boundGrantKeepsTheIssuedOriginAndHidesTheSecret() throws {
    let secret = "test-secret"
    let issued = try bindWebhook("https://hooks.example.invalid/routine", secret: secret)
    #expect(issued.destination() == "https://hooks.example.invalid/routine")
    let explicit = try bindWebhook("https://HOOKS.Example.Invalid:443/routine", secret: secret)
    #expect(explicit == issued)
    #expect(try bindWebhook("https://hooks.example.invalid/other", secret: secret).destination() != issued.destination())
    #expect(try bindWebhook("https://other.example.invalid/routine", secret: secret).destination() != issued.destination())
    #expect(try bindWebhook("https://hooks.example.invalid:8443/routine", secret: secret).destination()
        == "https://hooks.example.invalid:8443/routine")
    #expect(try bindWebhook("https://hooks.example.invalid/routine/", secret: secret).destination()
        == "https://hooks.example.invalid/routine/")
    #expect(!String(reflecting: issued).contains(secret))
    #expect(!String(describing: issued).contains("/routine"))
    #expect(!String(reflecting: issued).contains("/routine"))
    let call = WebhookCall(
        url: issued.destination(),
        method: "POST",
        authorization: "Bearer \(secret)",
        body: Data()
    )
    #expect(!String(describing: call).contains("/routine"))
    #expect(!String(reflecting: call).contains("/routine"))
    #expect(!String(describing: call).contains(secret))
    #expect(!String(reflecting: call).contains("hooks.example.invalid"))
    let loopback = try bindWebhook("http://127.0.0.1/routine", secret: secret, allowLoopback: true)
    #expect(loopback.destination() == "http://127.0.0.1/routine")
    #expect(try bindWebhook("http://localhost:9/lab", secret: secret, allowLoopback: true).destination()
        == "http://localhost:9/lab")
}

@Test func untrustedDestinationsAreNotSent() async throws {
    let posts = Posts()
    let transport: WebhookTransport = { call, _ in
        posts.record(call)
        return HttpResult(status: 200)
    }
    let refused = [
        "https://hooks.example.invalid/routine?token=test-secret",
        "https://hooks.example.invalid/routine#fragment",
        "https://user:test-secret@hooks.example.invalid/routine",
        "https://8.8.8.8/routine",
        "https://[::1]/routine",
        "https://api.x.ai/v1/responses",
        "https://mtls.api.x.ai/v1/responses",
        "https://api2.cursor.sh/updates/api/download/stable/darwin-arm64/sand",
        "http://hooks.example.invalid/routine",
        "https://hooks.example.invalid/",
        "https://hooks.example.invalid",
        "https://hooks.example.invalid/routine/../other",
        "https://hooks.example.invalid/routine/%2e%2e/other",
        "https://hooks.example.invalid/%2froutine",
        "https://hooks.example.invalid/./routine",
        "https://hooks.example.invalid//routine",
        "http://127.0.0.1/routine",
        "https://127.0.0.1/routine",
    ]
    for url in refused {
        #expect(throws: GrokConnectorError.notSent) { try bindWebhook(url, secret: "test-secret") }
    }
    let forged = WebhookGrant(scheme: "https", host: "api.x.ai", port: 443, path: "/v1/responses", secret: "test-secret")
    await #expect(throws: GrokConnectorError.notSent) {
        try await triggerRoutine(forged, body: ["task": .string("pong")], transport: transport)
    }
    #expect(throws: GrokConnectorError.notSent) {
        try bindWebhook("https://hooks.example.invalid/routine", secret: "test secret")
    }
    #expect(throws: GrokConnectorError.notSent) {
        try bindWebhook("http://hooks.example.invalid/routine", secret: "test-secret", allowLoopback: true)
    }
    #expect(throws: GrokConnectorError.notSent) {
        try bindWebhook("https://127.0.0.1/routine", secret: "test-secret", allowLoopback: true)
    }
    #expect(posts.count == 0)
}

@Test func http200IsAcceptedAndPostsOnce() async throws {
    let posts = Posts()
    let transport: WebhookTransport = { call, _ in
        posts.record(call)
        return HttpResult(status: 200)
    }
    let grant = try bindWebhook("https://hooks.example.invalid/routine", secret: "test-secret")
    let result = try await triggerRoutine(
        grant,
        body: ["task": .string("Reply with the single word pong.")],
        transport: transport
    )
    #expect(result.accepted)
    #expect(!result.completed)
    #expect(result.status == 200)
    #expect(posts.count == 1)
    #expect(posts.last?.url == grant.destination())
    #expect(posts.last?.method == "POST")
    #expect(posts.last?.authorization == "Bearer test-secret")
    #expect(!String(reflecting: result).contains("test-secret"))
    let body = try decodeBody(posts.last?.body ?? Data())
    #expect(body == .object(["task": .string("Reply with the single word pong.")]))
}

@Test func wholeNumbersStayIntegersInTheWebhookBody() async throws {
    let posts = Posts()
    let transport: WebhookTransport = { call, _ in
        posts.record(call)
        return HttpResult(status: 200)
    }
    let grant = try bindWebhook("https://hooks.example.invalid/routine", secret: "test-secret")
    _ = try await triggerRoutine(grant, body: ["n": .integer(2)], transport: transport)
    let text = String(decoding: posts.last?.body ?? Data(), as: UTF8.self)
    #expect(text.contains("\"n\":2"))
    #expect(!text.contains("2.0"))
}

@Test func observedRejectionHidesTheSecretAndDoesNotReplay() async throws {
    let posts = Posts()
    let transport: WebhookTransport = { call, _ in
        posts.record(call)
        return HttpResult(status: 401)
    }
    let grant = try bindWebhook("https://hooks.example.invalid/routine", secret: "test-secret")
    await #expect(throws: GrokConnectorError.rejected(status: 401)) {
        try await triggerRoutine(grant, body: nil, transport: transport)
    }
    #expect(posts.count == 1)
}

@Test func observed500IsARejection() async throws {
    let posts = Posts()
    let transport: WebhookTransport = { call, _ in
        posts.record(call)
        return HttpResult(status: 500)
    }
    let grant = try bindWebhook("https://hooks.example.invalid/routine", secret: "test-secret")
    await #expect(throws: GrokConnectorError.rejected(status: 500)) {
        try await triggerRoutine(grant, body: ["task": .string("pong")], transport: transport)
    }
    #expect(posts.count == 1)
    #expect(!String(reflecting: GrokConnectorError.rejected(status: 500)).contains("test-secret"))
}

@Test func unobservedPostIsNotReplayed() async throws {
    let posts = Posts()
    let transport: WebhookTransport = { call, _ in
        posts.record(call)
        throw GrokConnectorError.submissionUnobserved
    }
    let grant = try bindWebhook("https://hooks.example.invalid/routine", secret: "test-secret")
    await #expect(throws: GrokConnectorError.submissionUnobserved) {
        try await triggerRoutine(grant, body: ["task": .string("pong")], transport: transport)
    }
    #expect(posts.count == 1)
}

@Test func otherProviderIdentityIsRejected() throws {
    let other = try AdapterIdentity(provider: "grok-build", accountID: "synthetic-account", assistantID: "synthetic-bot")
    #expect(throws: GrokConnectorError.providerIdentity) {
        try GrokBotAdapter(identity: other)
    }
}

@Test func unconfiguredAdapterAdvertisesNothing() async throws {
    let id = try identity()
    let adapter = try GrokBotAdapter(identity: id)
    #expect(adapter.capabilities.isEmpty)
    let registry = AdapterRegistry()
    try await registry.register(adapter)
    await #expect(throws: RuntimeError.unsupportedCapability) {
        try await registry.dispatch(try taskRequest(id))
    }
    let direct = try await adapter.dispatch(try taskRequest(id))
    #expect(direct.count == 1)
    #expect(direct[0].kind == .failed)
    #expect(direct[0].payload == ["reason": .string("webhook_unconfigured")])
    #expect(direct[0].eventID == "failed-1")
}

@Test func taskFixtureIsAcceptedAndNotAReply() async throws {
    let id = try identity()
    let posts = Posts()
    let transport: WebhookTransport = { call, _ in
        posts.record(call)
        return HttpResult(status: 200)
    }
    let adapter = try GrokBotAdapter(
        identity: id,
        webhookURL: "https://hooks.example.invalid/routine",
        webhookSecret: "synthetic-secret",
        transport: transport
    )
    let registry = AdapterRegistry()
    try await registry.register(adapter)
    let request = try taskRequest(id)
    let events = try await registry.dispatch(request)
    #expect(try await registry.capabilities(for: id) == [.task])
    #expect(events.count == 1)
    #expect(events[0].kind == .accepted)
    #expect(events[0].eventID == "accepted-1")
    #expect(events[0].identity == id)
    #expect(events[0].sessionID.utf8.elementsEqual(request.sessionID.utf8))
    #expect(events[0].requestID.utf8.elementsEqual(request.requestID.utf8))
    #expect(events[0].payload == [
        "routine_accepted": .bool(true),
        "native_reply": .bool(false),
        "native_session_observed": .bool(false),
    ])
    #expect(events[0].kind != .completed)
    let encoded = try JSONEncoder().encode(JSONValue.object(events[0].payload))
    #expect(!String(decoding: encoded, as: UTF8.self).contains("synthetic-secret"))
    let body = try decodeBody(posts.last?.body ?? Data())
    #expect(body == .object(["task": .string("Reply with the single word pong.")]))
    #expect(posts.count == 1)
    await #expect(throws: RuntimeError.unsupportedCapability) {
        try await registry.dispatch(try taskRequest(id, capability: .message))
    }
    let direct = try await adapter.dispatch(try taskRequest(id, capability: .message))
    #expect(direct[0].kind == .failed)
    #expect(direct[0].payload == ["reason": .string("unsupported")])
    #expect(posts.count == 1)
    #expect(!String(reflecting: adapter).contains("synthetic-secret"))
    #expect(!String(describing: adapter).contains("/routine"))
    #expect(!String(reflecting: adapter).contains("hooks.example.invalid"))
}

@Test func billedHostAndQueryAreLocalFailures() async throws {
    let id = try identity()
    let posts = Posts()
    let transport: WebhookTransport = { call, _ in
        posts.record(call)
        return HttpResult(status: 200)
    }
    let billed = try GrokBotAdapter(
        identity: id,
        webhookURL: "https://api.x.ai/v1/responses",
        webhookSecret: "synthetic-secret",
        transport: transport
    )
    let registry = AdapterRegistry()
    try await registry.register(billed)
    let failed = try await registry.dispatch(try taskRequest(id))
    #expect(failed[0].kind == .failed)
    #expect(failed[0].payload == ["reason": .string("not_sent")])
    let queried = try GrokBotAdapter(
        identity: id,
        webhookURL: "https://hooks.example.invalid/routine?x=1",
        webhookSecret: "synthetic-secret",
        transport: transport
    )
    let queryEvents = try await queried.dispatch(try taskRequest(id))
    #expect(queryEvents[0].payload == ["reason": .string("not_sent")])
    #expect(posts.count == 0)
}

@Test func observed500FailsOnceAndDoesNotComplete() async throws {
    let id = try identity()
    let posts = Posts()
    let transport: WebhookTransport = { call, _ in
        posts.record(call)
        return HttpResult(status: 503)
    }
    let adapter = try GrokBotAdapter(
        identity: id,
        webhookURL: "https://hooks.example.invalid/routine",
        webhookSecret: "synthetic-secret",
        transport: transport
    )
    let events = try await adapter.dispatch(try taskRequest(id))
    #expect(posts.count == 1)
    #expect(events[0].kind == .failed)
    #expect(events[0].kind != .completed)
    guard case .integer(let status) = events[0].payload["status"] else {
        Issue.record("rejected status must stay an integer")
        return
    }
    #expect(status == 503)
    #expect(events[0].payload["reason"] == .string("rejected"))
}

@Test func lostPostIsUncertainAfterOneAttempt() async throws {
    let id = try identity()
    let posts = Posts()
    let transport: WebhookTransport = { call, _ in
        posts.record(call)
        throw GrokConnectorError.submissionUnobserved
    }
    let adapter = try GrokBotAdapter(
        identity: id,
        webhookURL: "https://hooks.example.invalid/routine",
        webhookSecret: "synthetic-secret",
        transport: transport
    )
    let registry = AdapterRegistry()
    try await registry.register(adapter)
    await #expect(throws: RuntimeError.dispatchUncertain) {
        try await registry.dispatch(try taskRequest(id))
    }
    #expect(posts.count == 1)
    await #expect(throws: RuntimeError.dispatchUncertain) {
        try await adapter.dispatch(try taskRequest(id))
    }
    #expect(posts.count == 2)
}

@Test func cancellationAfterTheCallIsNotAFailedReceipt() async throws {
    let id = try identity()
    let posts = Posts()
    let transport: WebhookTransport = { call, _ in
        posts.record(call)
        throw CancellationError()
    }
    let adapter = try GrokBotAdapter(
        identity: id,
        webhookURL: "https://hooks.example.invalid/routine",
        webhookSecret: "synthetic-secret",
        transport: transport
    )
    let registry = AdapterRegistry()
    try await registry.register(adapter)
    await #expect(throws: RuntimeError.dispatchUncertain) {
        try await registry.dispatch(try taskRequest(id))
    }
    #expect(posts.count == 1)
}

