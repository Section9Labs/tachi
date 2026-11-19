import Foundation
import Testing
import RuntimeSQLite
import TachiRuntime

private let owner = QueuePrincipal(humanID: "owner", clientID: "client")
private let reader = QueuePrincipal(humanID: "reader", clientID: "reader-device")

private struct Policy: QueueAuthority {
    var readerGeneration = "reader-1"
    var revoked: String?
    func authorize(_ principal: QueuePrincipal, team: String, scope: String, membershipID: String?) throws -> String {
        guard team == "team", let current = try self.membershipID(team: team, humanID: principal.humanID),
              principal.clientID != revoked, membershipID == nil || membershipID == current,
              scope != "teams:manage" || principal.humanID == "owner" else { throw QueueError.denied }
        return current
    }
    func membershipID(team: String, humanID: String) throws -> String? {
        guard team == "team" else { return nil }
        return ["owner": "owner-1", "reader": readerGeneration][humanID]
    }
}

private func nativeID(_ alias: String) throws -> AdapterIdentity {
    try AdapterIdentity(provider: "fixture", accountID: "account", assistantID: alias)
}

private struct Lab {
    let path: String
    let queue: TeamQueue
    let registry: AdapterRegistry
    let peer: ReferenceAdapter

    init(folder: URL, lead: any Adapter, limit: Int = 10) async throws {
        path = folder.appendingPathComponent("work.sqlite").path
        queue = try TeamQueue(path: path, authority: Policy())
        registry = AdapterRegistry()
        peer = try ReferenceAdapter(identity: nativeID("peer"))
        for (alias, adapter): (String, any Adapter) in [("lead", lead), ("peer", peer)] {
            try await registry.register(adapter)
            try await queue.addAssistant(team: "team", principal: owner, alias: alias,
                                         identity: adapter.identity, sessionID: "session-" + alias)
        }
        try await queue.createRun(team: "team", principal: owner, run: "run", lead: "assistant:lead", turnLimit: limit)
    }
}

private func withFolder(_ body: (URL) async throws -> Void) async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try await body(folder)
}

private actor ReceiptOnly: Adapter {
    let identity: AdapterIdentity
    let version = 1
    let capabilities: Set<Capability> = [.task]
    private(set) var count = 0
    init() throws { identity = try nativeID("lead") }
    func dispatch(_ request: DispatchRequest) throws -> [AdapterEvent] {
        count += 1
        return [try AdapterEvent(identity: identity, sessionID: request.sessionID, requestID: request.requestID,
                                 eventID: "receipt", kind: .accepted, payload: ["native_reply": .bool(false)])]
    }
}

@Test func receiptSurvivesReopenHoldsLaneAndCannotHandoff() async throws {
    try await withFolder { folder in
        let adapter = try ReceiptOnly()
        let lab = try await Lab(folder: folder, lead: adapter)
        for id in ["first", "next"] {
            try await lab.queue.post(team: "team", principal: owner, run: "run", message: id, payload: [:],
                                     directTo: "assistant:lead", capability: .task)
        }
        _ = try await lab.queue.dispatchOne(registry: lab.registry)
        let reopened = try TeamQueue(path: lab.path, authority: Policy())
        let messages = try await reopened.history(team: "team", principal: owner, run: "run")
        #expect(messages.flatMap(\.deliveries).map(\.state) == ["active", "queued"])
        let receipt = try #require(messages.first?.deliveries.first?.events.first)
        #expect(receipt.payload == ["native_reply": .bool(false)])
        await #expect(throws: QueueError.denied) {
            try await reopened.postReply(parent: receipt, message: "handoff", payload: [:], directTo: "assistant:peer")
        }
        #expect(try await reopened.dispatchOne(registry: lab.registry) == nil)
        #expect(await adapter.count == 1)
    }
}

@Test func migrationReadsPythonStateAndPreservesStableRetries() async throws {
    try await withFolder { folder in
        let path = folder.appendingPathComponent("legacy.sqlite").path
        let fixture = try #require(Bundle.module.url(forResource: "python-v1", withExtension: "sql", subdirectory: "Fixtures"))
        let sql = try String(contentsOf: fixture, encoding: .utf8)
        var handle: OpaquePointer?
        #expect(sqlite3_open(path, &handle) == SQLITE_OK)
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        sqlite3_close(handle)
        #expect(result == SQLITE_OK)
        let q = try TeamQueue(path: path, authority: Policy())
        let before = try await q.history(team: "team", principal: owner, run: "run")
        try await q.post(team: "team", principal: owner, run: "run", message: "legacy",
                         payload: ["text": .string("café / brief")], mentions: ["assistant:lead", "assistant:peer"])
        let after = try await q.history(team: "team", principal: owner, run: "run")
        #expect(after.flatMap(\.deliveries).map(\.requestID) == before.flatMap(\.deliveries).map(\.requestID))
        #expect(after.flatMap(\.deliveries).map(\.state) == ["completed","uncertain","queued"])
        let registry = AdapterRegistry()
        #expect(try await q.dispatchOne(registry: registry) == nil)
        try await q.intervene(team: "team", principal: owner, run: "run", state: .running)
        let peer = try ReferenceAdapter(identity: nativeID("peer"))
        try await registry.register(peer)
        #expect(try await q.dispatchOne(registry: registry) == before.last?.deliveries.first?.requestID)
        #expect(await peer.calls.count == 1)
        let uncertain = try #require(before[0].deliveries.last)
        await #expect(throws: QueueError.conflict) {
            try await q.retryBlocked(team: "team", principal: owner, requestID: uncertain.requestID)
        }
    }
}

@Test func delegationRechecksGenerationAndPrivateAudiences() async throws {
    try await withFolder { folder in
        let lab = try await Lab(folder: folder, lead: ReferenceAdapter(identity: nativeID("lead")))
        try await lab.queue.post(team: "team", principal: reader, run: "run", message: "brief", payload: [:], mentions: ["assistant:lead"])
        _ = try await lab.queue.dispatchOne(registry: lab.registry)
        let original = try await lab.queue.history(team: "team", principal: reader, run: "run")
        let event = try #require(original.first?.deliveries.first?.events.first)
        try await lab.queue.postReply(parent: event, message: "check", payload: [:], directTo: "assistant:peer")
        try await lab.queue.post(team: "team", principal: owner, run: "run", message: "private",
                                 payload: ["text": .string("synthetic")], directTo: "human:reader")
        let q = try TeamQueue(path: lab.path, authority: Policy(readerGeneration: "reader-2"))
        await #expect(throws: QueueError.denied) {
            try await q.postReply(parent: event, message: "revived", payload: [:], directTo: "assistant:peer")
        }
        let visible = try await q.history(team: "team", principal: reader, run: "run")
        #expect(visible.map(\.messageID) == ["brief"])
        _ = try await q.dispatchOne(registry: lab.registry)
        #expect(await lab.peer.calls.isEmpty)
        await #expect(throws: QueueError.denied) {
            try await q.post(team: "team", principal: reader, run: "run", message: "leak",
                             payload: [:], directTo: "human:owner", replyTo: "private")
        }
    }
}

@Test func hostRecheckLimitsDuplicateEventsAndIntervention() async throws {
    try await withFolder { folder in
        let lead = try ReferenceAdapter(identity: nativeID("lead"), duplicateEvent: true)
        let lab = try await Lab(folder: folder, lead: lead, limit: 1)
        let scope = try HostScope(ownerID: "owner", hostID: "local", grantID: "read-brief", folderID: "folder",
                                  action: "read", relativePath: "brief.txt")
        try await lab.queue.post(team: "team", principal: owner, run: "run", message: "file",
                                 payload: [:], directTo: "assistant:lead", scope: scope)
        #expect(try await lab.queue.dispatchOne(registry: lab.registry) == nil)
        let denied = HostWorker(hostID: "local") { _ in throw QueueError.denied }
        let blocked = try await lab.queue.dispatchOne(registry: lab.registry, host: denied)
        let rid = try #require(blocked)
        try await lab.queue.retryBlocked(team: "team", principal: owner, requestID: rid)
        let allowed = HostWorker(hostID: "local") { actual in #expect(actual == scope) }
        #expect(try await lab.queue.dispatchOne(registry: lab.registry, host: allowed) == rid)
        let messages = try await lab.queue.history(team: "team", principal: owner, run: "run")
        let terminal = try #require(messages.first?.deliveries.first?.events.first)
        try await lab.queue.record(terminal)
        let late = try AdapterEvent(identity: terminal.identity, sessionID: terminal.sessionID, requestID: rid,
                                    eventID: "late-ack", kind: .accepted, payload: [:])
        try await lab.queue.record(late)
        let settled = try await lab.queue.history(team: "team", principal: owner, run: "run")
        #expect(settled.first?.deliveries.first?.state == "completed")
        #expect(settled.first?.deliveries.first?.events.count == 2)
        #expect(await lead.calls.count == 1)
        try await lab.queue.post(team: "team", principal: owner, run: "run", message: "next", payload: [:], directTo: "assistant:peer")
        #expect(try await lab.queue.dispatchOne(registry: lab.registry) == nil)
        try await lab.queue.intervene(team: "team", principal: owner, run: "run", state: .paused, turnLimit: 2)
        #expect(try await lab.queue.dispatchOne(registry: lab.registry) == nil)
        try await lab.queue.intervene(team: "team", principal: owner, run: "run", state: .cancelled)
        let closed = try await lab.queue.history(team: "team", principal: owner, run: "run")
        #expect(closed.last?.deliveries.first?.state == "cancelled")
    }
}

private actor HeldAdapter: Adapter {
    let identity: AdapterIdentity
    let version = 1
    let capabilities: Set<Capability> = [.message]
    let entered: AsyncStream<Void>.Continuation
    let release: AsyncStream<Void>
    private(set) var count = 0
    init(entered: AsyncStream<Void>.Continuation, release: AsyncStream<Void>) throws {
        self.identity = try nativeID("lead")
        self.entered = entered
        self.release = release
    }
    func dispatch(_ request: DispatchRequest) async throws -> [AdapterEvent] {
        count += 1
        entered.finish()
        for await _ in release { break }
        throw CancellationError()
    }
}

@Test func twoWorkersRespectDurableClaimAndUnrelatedSessionProgress() async throws {
    try await withFolder { folder in
        let entered = AsyncStream<Void>.makeStream(), release = AsyncStream<Void>.makeStream()
        defer { release.continuation.finish() }
        let lead = try HeldAdapter(entered: entered.continuation, release: release.stream)
        let lab = try await Lab(folder: folder, lead: lead)
        for (message, target) in [("first", "lead"), ("next", "lead"), ("independent", "peer")] {
            try await lab.queue.post(team: "team", principal: owner, run: "run", message: message,
                                     payload: [:], directTo: "assistant:" + target)
        }
        let first = Task { try await lab.queue.dispatchOne(registry: lab.registry) }
        for await _ in entered.stream {}
        let second = try TeamQueue(path: lab.path, authority: Policy())
        _ = try await second.dispatchOne(registry: lab.registry)
        #expect(try await second.dispatchOne(registry: lab.registry) == nil)
        release.continuation.finish()
        let firstID = try await first.value
        let messages = try await second.history(team: "team", principal: owner, run: "run")
        #expect(messages.flatMap(\.deliveries).map(\.state) == ["uncertain", "queued", "completed"])
        #expect(messages[0].deliveries.first?.requestID == firstID)
        #expect(await lead.count == 1)
        #expect(await lab.peer.calls.count == 1)
        let rid = try #require(firstID)
        await #expect(throws: QueueError.conflict) {
            try await second.retryBlocked(team: "team", principal: owner, requestID: rid)
        }
        let event = try AdapterEvent(identity: lead.identity, sessionID: "session-lead", requestID: rid,
                                     eventID: "later-native-result", kind: .completed, payload: ["value": .double(1)])
        try await second.record(event)
        try await second.record(event)
        let wrong = try AdapterEvent(identity: lead.identity, sessionID: "other", requestID: rid,
                                     eventID: "misrouted", kind: .completed, payload: [:])
        await #expect(throws: QueueError.conflict) { try await second.record(wrong) }
        let revised = try AdapterEvent(identity: lead.identity, sessionID: "session-lead", requestID: rid,
                                       eventID: "later-native-result", kind: .completed, payload: ["value": .integer(2)])
        await #expect(throws: QueueError.conflict) { try await second.record(revised) }
    }
}

@Test func invalidCapabilityBlocksBeforeInvocationAndRevocationDoesNotHoldSiblings() async throws {
    try await withFolder { folder in
        let lead = try ReferenceAdapter(identity: nativeID("lead"))
        let lab = try await Lab(folder: folder, lead: lead)
        for (id, human) in [("revoked", reader), ("authorized", owner)] {
            try await lab.queue.post(team: "team", principal: human, run: "run", message: id,
                                     payload: [:], mentions: ["assistant:lead"])
        }
        try await lab.queue.post(team: "team", principal: owner, run: "run", message: "cancel",
                                 payload: [:], directTo: "assistant:peer", capability: .cancel)
        let live = try TeamQueue(path: lab.path, authority: Policy(revoked: reader.clientID))
        for _ in 0..<3 { _ = try await live.dispatchOne(registry: lab.registry) }
        let messages = try await live.history(team: "team", principal: owner, run: "run")
        #expect(messages.flatMap(\.deliveries).map(\.state) == ["denied", "completed", "blocked"])
        #expect(messages.last?.deliveries.first?.reason == "unsupported_capability")
        #expect(try await live.runStatus(team: "team", principal: owner, run: "run").turns == 1)
        #expect(await lead.calls.count == 1)
        #expect(await lab.peer.calls.isEmpty)
    }
}
