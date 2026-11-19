import Foundation
import Testing
@testable import TachiRuntime

private let primary = QueuePrincipal(humanID: "human-a", clientID: "primary")
private let sibling = QueuePrincipal(humanID: "human-a", clientID: "sibling")
private let readerClient = QueuePrincipal(humanID: "human-a", clientID: "read-only")
private let outsider = QueuePrincipal(humanID: "human-b", clientID: "other")

/// Synchronous, process-local model of the two injected account operations. Shared across connections in a test.
private final class ReferencePolicy: ReferenceTeamAuthority, @unchecked Sendable {
    private let lock = NSLock()
    private var owners: [String: String] = [:]
    private var revoked: Set<String> = []
    func revoke(_ principal: QueuePrincipal) { lock.withLock { _ = revoked.insert(principal.clientID) } }

    func authorizeClient(_ principal: QueuePrincipal, scope: String) throws {
        guard !lock.withLock({ revoked.contains(principal.clientID) }),
              principal.clientID != readerClient.clientID || scope == "sessions:read" else { throw QueueError.denied }
    }

    func createTeam(_ principal: QueuePrincipal, team: String) throws {
        try authorizeClient(principal, scope: "teams:manage")
        try lock.withLock {
            guard owners[team] == nil else { throw QueueError.denied }
            owners[team] = principal.humanID
        }
    }

    func membershipID(team: String, humanID: String) throws -> String? {
        lock.withLock { owners[team] == humanID ? humanID + "-generation" : nil }
    }

    func authorize(_ principal: QueuePrincipal, team: String, scope: String, membershipID: String?) throws -> String {
        try authorizeClient(principal, scope: scope)
        guard let current = try self.membershipID(team: team, humanID: principal.humanID),
              membershipID == nil || membershipID == current else { throw QueueError.denied }
        return current
    }
}

private func withReferenceStore(_ test: (String, ReferencePolicy, ReferenceTeams) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("shared.sqlite").path
    let policy = ReferencePolicy()
    try await test(path, policy, ReferenceTeams(path: path, authority: policy))
}

@Test func referenceSiblingReopensPausedTeamAndCompletesWithinBudget() async throws {
    try await withReferenceStore { path, policy, service in
        let created = try await service.create(principal: primary, creationID: "one", turnLimit: 1)
        let team = created.teamID
        #expect(created.mode == "reference")
        #expect(try await service.list(principal: sibling) == [created])
        _ = try await service.intervene(teamID: team, principal: sibling, state: .paused)
        try await service.post(teamID: team, principal: primary, messageID: "brief", text: "One\u{1c}two three",
                               audience: "room", mentions: ["lead"])
        let reopened = try ReferenceTeams(path: path, authority: policy)
        try await reopened.post(teamID: team, principal: primary, messageID: "brief", text: "One\u{1c}two three",
                                audience: "room", mentions: ["lead"])
        try await reopened.post(teamID: team, principal: sibling, messageID: "edit", text: "edit",
                                audience: "peer", replyTo: "brief")
        #expect(try await reopened.workOnce() == 0)
        let queued = try await reopened.messages(teamID: team, principal: sibling)
        #expect(queued.flatMap(\.deliveries).map(\.state) == ["queued", "queued"])
        let obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(queued[0])) as? [String: Any])
        #expect(Set(obj.keys) == ["messageID", "text", "author", "audience", "mentions", "replyTo", "deliveries"])
        #expect(obj["replyTo"] is NSNull)
        let deliveries = try #require(obj["deliveries"] as? [[String: Any]])
        #expect(deliveries[0]["result"] is NSNull)
        _ = try await reopened.intervene(teamID: team, principal: sibling, state: .running)
        #expect(try await reopened.workOnce() == 1)
        #expect(try await reopened.workOnce() == 0)
        _ = try await reopened.intervene(teamID: team, principal: sibling, state: .running, turnLimit: 2)
        #expect(try await reopened.workOnce() == 1)
        let messages = try await reopened.messages(teamID: team, principal: primary)
        #expect(messages.map(\.audience) == ["room", "peer"])
        #expect(messages.map(\.replyTo) == [nil, "brief"])
        #expect(messages.flatMap(\.deliveries).map(\.result) == ["Reference lead counted 3 words.", "Reference peer counted 1 word."])
        let ended = try await reopened.intervene(teamID: team, principal: sibling, state: .completed)
        #expect(ended.turnsUsed == 2 && ended.runState == "completed")
        try await reopened.post(teamID: team, principal: primary, messageID: "brief", text: "One\u{1c}two three",
                                audience: "room", mentions: ["lead"])
        await #expect(throws: QueueError.conflict) {
            try await reopened.post(teamID: team, principal: primary, messageID: "brief", text: "changed", audience: "room")
        }
    }
}

@Test func referenceClientRevocationLeavesSiblingWorkAuthorized() async throws {
    try await withReferenceStore { _, policy, service in
        let team = try await service.create(principal: primary, creationID: "project", turnLimit: 1).teamID
        for origin in [primary, sibling] {
            try await service.post(teamID: team, principal: origin, messageID: origin.clientID, text: "brief", audience: "lead")
        }
        policy.revoke(primary)
        await #expect(throws: QueueError.denied) { try await service.list(principal: primary) }
        let worker = Task { try await service.runWorker() }
        defer { worker.cancel() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while try await service.summary(teamID: team, principal: sibling).turnsUsed == 0 && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        // A claimed turn may still be awaiting its result.
        while try await service.messages(teamID: team, principal: sibling).last?.deliveries.first?.state != "completed"
                && clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        worker.cancel()
        await #expect(throws: CancellationError.self) { try await worker.value }
        let messages = try await service.messages(teamID: team, principal: sibling)
        #expect(messages.flatMap(\.deliveries).map(\.state) == ["denied", "completed"])
        #expect(try await service.summary(teamID: team, principal: sibling).turnsUsed == 1)
    }
}

@Test func referenceOwnershipScopesConflictsAndFreshSessions() async throws {
    try await withReferenceStore { path, _, service in
        let first = try await service.create(principal: primary, creationID: "same", turnLimit: 8)
        let second = try await service.create(principal: outsider, creationID: "same", turnLimit: 8)
        #expect(first.teamID != second.teamID)
        #expect(try await service.list(principal: outsider) == [second])
        #expect(try await service.summary(teamID: first.teamID, principal: readerClient) == first)
        await #expect(throws: QueueError.notFound) { try await service.messages(teamID: first.teamID, principal: outsider) }
        await #expect(throws: QueueError.notFound) {
            try await service.intervene(teamID: first.teamID, principal: outsider, state: .paused)
        }
        await #expect(throws: QueueError.denied) {
            try await service.post(teamID: first.teamID, principal: readerClient, messageID: "m", text: "a", audience: "peer")
        }
        await #expect(throws: QueueError.denied) {
            try await service.intervene(teamID: first.teamID, principal: readerClient, state: .paused)
        }
        await #expect(throws: QueueError.denied) {
            try await service.create(principal: readerClient, creationID: "no", turnLimit: 1)
        }
        await #expect(throws: QueueError.invalidInput) {
            try await service.post(teamID: first.teamID, principal: primary, messageID: "bad", text: "text", audience: "external")
        }
        await #expect(throws: QueueError.conflict) {
            try await service.post(teamID: first.teamID, principal: primary, messageID: "m", text: "text", audience: "room", replyTo: "absent")
        }
        let bindings = try RuntimeDatabase(path: path).query("SELECT DISTINCT session FROM rt_assistant WHERE provider='tachi-reference'")
        #expect(bindings.count == 4)
    }
}

@Test func referenceProvisionIsAtomicRetryableAndHiddenUntilReady() async throws {
    try await withReferenceStore { path, policy, service in
        let db = try RuntimeDatabase(path: path)
        try db.query("""
            CREATE TRIGGER interrupt_provision BEFORE INSERT ON rt_assistant WHEN NEW.member='assistant:peer'
            BEGIN SELECT RAISE(ABORT, 'simulated interruption'); END
            """)
        await #expect(throws: QueueError.conflict) {
            try await service.create(principal: primary, creationID: "recover", turnLimit: 9)
        }
        #expect(try db.query("SELECT * FROM rt_assistant").isEmpty)
        #expect(try db.query("SELECT * FROM rt_run").isEmpty)
        let row = try #require(db.query("SELECT team,ready FROM rt_reference_team").first)
        let reserved = try #require(row["team"])
        #expect(row["ready"] == "0")
        #expect(try await service.list(principal: sibling).isEmpty)
        await #expect(throws: QueueError.notFound) { try await service.summary(teamID: reserved, principal: sibling) }
        try db.query("DROP TRIGGER interrupt_provision")
        let other = try ReferenceTeams(path: path, authority: policy)
        async let left = service.create(principal: primary, creationID: "recover", turnLimit: 9)
        async let right = other.create(principal: sibling, creationID: "recover", turnLimit: 9)
        let (a, b) = try await (left, right)
        #expect(a == b && a.teamID == reserved)
        #expect(try db.query("SELECT * FROM rt_run").count == 1)
        #expect(try db.query("SELECT * FROM rt_assistant").count == 2)
        await #expect(throws: QueueError.conflict) {
            try await service.create(principal: primary, creationID: "recover", turnLimit: 2)
        }
    }
}

@Test func referenceWorkerSkipsUnrelatedNativeAndHostWork() async throws {
    try await withReferenceStore { path, policy, service in
        let team = try await service.create(principal: primary, creationID: "reference", turnLimit: 8).teamID
        let other = "other-team"
        try policy.createTeam(primary, team: other)
        let queue = try TeamQueue(path: path, authority: policy)
        let external = try AdapterIdentity(provider: "other-fixture", accountID: "account", assistantID: "assistant")
        for (id, alias) in [(team, "external"), (other, "lead")] {
            try await queue.addAssistant(team: id, principal: primary, alias: alias, identity: external, sessionID: id)
            if id == other { try await queue.createRun(team: id, principal: primary, run: "assignment", lead: "assistant:lead", turnLimit: 1) }
            try await queue.post(team: id, principal: primary, run: "assignment", message: "native", payload: [:], directTo: "assistant:" + alias)
        }
        let scope = try HostScope(ownerID: primary.humanID, hostID: "local", grantID: "read", folderID: "folder", action: "read", relativePath: "brief")
        try await queue.post(team: team, principal: primary, run: "assignment", message: "host", payload: [:], directTo: "assistant:peer", scope: scope)
        try await service.post(teamID: team, principal: primary, messageID: "public", text: "brief", audience: "lead")
        #expect(try await service.workOnce() == 1)
        #expect(try await service.workOnce() == 0)
        #expect(try await queue.history(team: team, principal: primary, run: "assignment").flatMap(\.deliveries).map(\.state)
                == ["queued", "queued", "completed"])
        #expect(try await service.messages(teamID: team, principal: primary).map(\.messageID) == ["public"])
        #expect(try await queue.runStatus(team: other, principal: primary, run: "assignment").turns == 0)
    }
}
