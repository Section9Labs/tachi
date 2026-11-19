import Testing
import TachiRuntime

private struct Broken: Adapter {
    let identity: AdapterIdentity
    let version: Int
    let capabilities: Set<Capability> = [.task]
    let behavior: @Sendable (DispatchRequest) throws -> [AdapterEvent]
    func dispatch(_ request: DispatchRequest) async throws -> [AdapterEvent] { try behavior(request) }
}

@Test func independentAccountsAndStableOpaqueIDs() async throws {
    let registry = AdapterRegistry()
    for account in ["a", "b", "é", "e\u{301}"] {
        let id = try AdapterIdentity(provider: "fixture", accountID: account, assistantID: "same")
        let adapter = ReferenceAdapter(identity: id, duplicateEvent: true)
        try await registry.register(adapter)
        #expect(try await registry.capabilities(for: id) == [.message, .task])
        let request = try DispatchRequest(identity: id, sessionID: "s", requestID: "r", capability: .task, payload: [:])
        let events = try await registry.dispatch(request)
        #expect(events.count == 1)
        #expect(events.first?.identity == id)
        #expect(events.first?.payload == ["operation": .string("task")])
        await #expect(throws: RuntimeError.duplicateIdentity) { try await registry.register(adapter) }
        let cancel = try DispatchRequest(identity: id, sessionID: "s", requestID: "r", capability: .cancel, payload: [:])
        await #expect(throws: RuntimeError.unsupportedCapability) { try await registry.dispatch(cancel) }
        #expect(await adapter.calls.count == 1)
    }
}

@Test func malformedRequestsAndLostReply() async throws {
    #expect(throws: RuntimeError.invalidIdentifier) {
        try AdapterIdentity(provider: "fixture", accountID: " ", assistantID: "bot")
    }
    let id = try AdapterIdentity(provider: "fixture", accountID: "a", assistantID: "bot")
    #expect(throws: RuntimeError.invalidPayload) {
        try DispatchRequest(identity: id, sessionID: "s", requestID: "r", capability: .task,
                            payload: ["nested": .array([.double(.infinity)])])
    }
    let registry = AdapterRegistry()
    let request = try DispatchRequest(identity: id, sessionID: "s", requestID: "r", capability: .task, payload: [:])
    await #expect(throws: RuntimeError.unknownIdentity) { try await registry.dispatch(request) }
    await #expect(throws: RuntimeError.unsupportedVersion) {
        try await registry.register(Broken(identity: id, version: 2) { _ in [] })
    }
    let adapter = ReferenceAdapter(identity: id, loseReply: true)
    try await registry.register(adapter)
    await #expect(throws: RuntimeError.dispatchUncertain) { try await registry.dispatch(request) }
    #expect(await adapter.calls.count == 1)
}

@Test(arguments: ["cancelled", "cross-session", "conflict"])
func postSubmissionErrorsAreUncertain(failure: String) async throws {
    let id = try AdapterIdentity(provider: "fixture", accountID: "a", assistantID: "b")
    let registry = AdapterRegistry()
    try await registry.register(Broken(identity: id, version: 1) { req in
        if failure == "cancelled" { throw CancellationError() }
        return try [EventKind.accepted, .completed].map { kind in
            try AdapterEvent(identity: id, sessionID: failure == "cross-session" ? "other" : req.sessionID,
                             requestID: req.requestID, eventID: "one", kind: kind, payload: [:])
        }
    })
    let req = try DispatchRequest(identity: id, sessionID: "s", requestID: "r", capability: .task, payload: [:])
    await #expect(throws: RuntimeError.dispatchUncertain) { try await registry.dispatch(req) }
}

@Test func publicEventEqualityPreservesOpaqueIDBytes() throws {
    let id = try AdapterIdentity(provider: "fixture", accountID: "a", assistantID: "assistant")
    func event(_ session: String, _ request: String, _ event: String) throws -> AdapterEvent {
        try AdapterEvent(identity: id, sessionID: session, requestID: request,
                         eventID: event, kind: .accepted, payload: [:])
    }
    let composed = "é", decomposed = "e\u{301}"
    let base = try event(composed, composed, composed)
    #expect(try base != event(decomposed, composed, composed))
    #expect(try base != event(composed, decomposed, composed))
    #expect(try base != event(composed, composed, decomposed))
}
