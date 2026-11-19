import Foundation
import TachiAdapterConformance
import TachiGrok
import TachiRuntime
import Testing

private let payload: JSONObject = ["text": .string("Count the synthetic pages.")]

private func task(_ identity: AdapterIdentity) throws -> DispatchRequest {
    try DispatchRequest(identity: identity, sessionID: "fixture-session", requestID: "fixture-request",
                        capability: .task, payload: payload)
}

@Test func referenceCompletesWithOneCorrelatedEvent() async throws {
    let identity = try AdapterIdentity(provider: "tachi-reference", accountID: "fixture-account", assistantID: "fixture-bot")
    let request = try task(identity)
    let reference = ReferenceAdapter(identity: identity, duplicateEvent: true)
    let suite = AdapterConformance(adapter: reference) { await reference.calls.count }
    try await suite.checkRegistration(probe: request, capabilities: [.message, .task])
    let events = try await suite.checkResponse(to: request, kinds: [.completed])
    #expect(events.first?.payload == ["operation": .string("task")])
}

// Inject this transport for every Grok dispatch. Record the method and decoded payload only.
private actor WebhookFixture {
    enum Reply { case accept, lose }
    let reply: Reply
    private(set) var bodies: [Data] = []
    private(set) var methods: [String] = []
    init(_ reply: Reply) { self.reply = reply }

    func send(_ call: WebhookCall) throws -> HttpResult {
        methods.append(call.method)
        bodies.append(call.body)
        switch reply {
        case .accept: return HttpResult(status: 200)
        case .lose: throw GrokConnectorError.submissionUnobserved
        }
    }
}

private func routine(_ identity: AdapterIdentity, _ transport: WebhookFixture) throws -> GrokBotAdapter {
    try GrokBotAdapter(identity: identity, webhookURL: "https://routine.invalid/fixture",
                       webhookSecret: "fixture-only", transport: { call, _ in try await transport.send(call) })
}

private func routineIdentity() throws -> AdapterIdentity {
    try AdapterIdentity(provider: grokBotProviderID, accountID: "fixture-account", assistantID: "fixture-routine")
}

@Test func routineAdvertisesTaskAndReturnsOnlyAReceipt() async throws {
    let id = try routineIdentity()
    let request = try task(id)
    let transport = WebhookFixture(.accept)
    let suite = try AdapterConformance(adapter: routine(id, transport)) { await transport.bodies.count }
    try await suite.checkRegistration(probe: request, capabilities: [.task])
    let events = try await suite.checkResponse(to: request, kinds: [.accepted])
    #expect(events.first?.payload == ["routine_accepted": .bool(true), "native_reply": .bool(false),
                                     "native_session_observed": .bool(false)])
    #expect(await transport.methods == ["POST"])
    let body = try #require(await transport.bodies.first)
    #expect(try JSONDecoder().decode(JSONObject.self, from: body) == payload)
}

@Test func routineLosesOneSubmission() async throws {
    let id = try routineIdentity()
    let request = try task(id)
    let transport = WebhookFixture(.lose)
    let suite = try AdapterConformance(adapter: routine(id, transport)) { await transport.bodies.count }
    try await suite.checkRegistration(probe: request, capabilities: [.task])
    try await suite.checkLostReply(to: request)
}

@Test func unconfiguredRoutineAdvertisesNoOperations() async throws {
    let id = try routineIdentity()
    let transport = WebhookFixture(.accept)
    let adapter = try GrokBotAdapter(identity: id, transport: { call, _ in try await transport.send(call) })
    let suite = AdapterConformance(adapter: adapter) { await transport.bodies.count }
    try await suite.checkRegistration(probe: task(id), capabilities: [])
}

@Test func suiteDetectsAnExtraTransportAttempt() async throws {
    let id = try routineIdentity()
    let transport = WebhookFixture(.accept)
    // Deliberately faulty synthetic transport records a second attempt before reporting loss.
    let adapter = try GrokBotAdapter(identity: id, webhookURL: "https://routine.invalid/fixture",
                                     webhookSecret: "fixture-only", transport: { call, _ in
        _ = try await transport.send(call)
        _ = try await transport.send(call)
        throw GrokConnectorError.submissionUnobserved
    })
    let suite = AdapterConformance(adapter: adapter) { await transport.bodies.count }
    let request = try task(id)
    try await suite.checkRegistration(probe: request, capabilities: [.task])
    await #expect(throws: ConformanceFailure.submissionCount(expected: 1, actual: 2)) {
        try await suite.checkLostReply(to: request)
    }
}

// Authority for one isolated SQLite fixture. Shipping services supply live account policy.
private struct FixtureAuthority: QueueAuthority {
    let owner = QueuePrincipal(humanID: "fixture-owner", clientID: "fixture-client")

    func membershipID(team: String, humanID: String) -> String? {
        team == "fixture-team" && humanID == owner.humanID ? "fixture-membership" : nil
    }

    func authorize(_ principal: QueuePrincipal, team: String, scope: String, membershipID: String?) throws -> String {
        guard let generation = self.membershipID(team: team, humanID: principal.humanID),
              principal.clientID == owner.clientID, membershipID == nil || membershipID == generation,
              ["teams:manage", "sessions:read", "messages:send"].contains(scope)
        else { throw QueueError.denied }
        return generation
    }
}

@Test func reopenedWorkerDoesNotReplayAnAmbiguousRoutine() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.appendingPathComponent("queue.sqlite").path
    let id = try routineIdentity()
    let authority = FixtureAuthority()
    let team = "fixture-team", run = "fixture-run"
    let requestID: String
    do {
        let queue = try TeamQueue(path: path, authority: authority)
        let registry = AdapterRegistry()
        let transport = WebhookFixture(.lose)
        try await registry.register(routine(id, transport))
        try await queue.addAssistant(team: team, principal: authority.owner, alias: "bot", identity: id,
                                     sessionID: "fixture-session")
        try await queue.createRun(team: team, principal: authority.owner, run: run, lead: "assistant:bot", turnLimit: 4)
        for message in ["first", "second"] {
            try await queue.post(team: team, principal: authority.owner, run: run, message: message,
                                 payload: payload, directTo: "assistant:bot", capability: .task)
        }
        requestID = try #require(try await queue.dispatchOne(registry: registry))
        #expect(await transport.methods == ["POST"])
    }
    let reopened = try TeamQueue(path: path, authority: authority)
    let registry = AdapterRegistry()
    let fresh = WebhookFixture(.accept)
    try await registry.register(routine(id, fresh))
    await #expect(throws: QueueError.conflict) {
        try await reopened.retryBlocked(team: team, principal: authority.owner, requestID: requestID)
    }
    #expect(try await reopened.dispatchOne(registry: registry) == nil)
    let history = try await reopened.history(team: team, principal: authority.owner, run: run)
    let deliveries = history.flatMap(\.deliveries)
    #expect(deliveries.map(\.state) == ["uncertain", "queued"])
    #expect(deliveries.first?.requestID == requestID)
    #expect(deliveries.allSatisfy { $0.events.isEmpty })
    #expect(await fresh.methods.isEmpty)
}
