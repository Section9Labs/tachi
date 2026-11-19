import Foundation
import Testing
import TachiRuntime

private let grantor = QueuePrincipal(humanID: "owner", clientID: "granting-device")
private let sender = QueuePrincipal(humanID: "member", clientID: "sending-device")
private let sibling = QueuePrincipal(humanID: "member", clientID: "other-device")
private let workspace = "workspace/fixture"

private struct WorkspacePolicy: QueueAuthority {
    var ownerGeneration = "owner-1", senderGeneration = "member-1"
    var revoked: String?

    func membershipID(team: String, humanID: String) throws -> String? {
        guard [workspace, "workspace/other"].contains(team) else { return nil }
        return [grantor.humanID: ownerGeneration, sender.humanID: senderGeneration][humanID]
    }

    func authorize(_ principal: QueuePrincipal, team: String, scope: String, membershipID: String?) throws -> String {
        guard let generation = try self.membershipID(team: team, humanID: principal.humanID),
              principal.clientID != revoked, membershipID == nil || membershipID == generation,
              scope != "teams:manage" || principal.humanID == grantor.humanID else { throw QueueError.denied }
        return generation
    }
}

private actor RoutineReceipt: Adapter {
    let version = 1, capabilities: Set<Capability> = [.task]
    let identity: AdapterIdentity
    let kind: EventKind
    let afterSubmission: @Sendable () async throws -> Void
    private(set) var calls: [DispatchRequest] = []
    init(_ kind: EventKind = .accepted, afterSubmission: @escaping @Sendable () async throws -> Void = {}) throws {
        identity = try AdapterIdentity(provider: "grok-bot", accountID: "fixture-account", assistantID: "fixture-routine")
        self.kind = kind
        self.afterSubmission = afterSubmission
    }
    func dispatch(_ request: DispatchRequest) async throws -> [AdapterEvent] {
        calls.append(request)
        try await afterSubmission()
        return [try AdapterEvent(identity: identity, sessionID: request.sessionID, requestID: request.requestID,
                                 eventID: "receipt", kind: kind, payload: ["routine_accepted": .bool(true),
                                   "native_reply": .bool(false), "native_session_observed": .bool(false)])]
    }
}

private struct AssignmentLab {
    let folder: URL, db: String, queue: TeamQueue, registry: AdapterRegistry
    let adapter: RoutineReceipt, binding: String
    let task = UUID().uuidString.lowercased()
    let lookup: WorkspaceRoutineLookup

    init(kind: EventKind = .accepted) async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        db = folder.appendingPathComponent("workspace.sqlite").path
        queue = try TeamQueue(path: db, authority: WorkspacePolicy())
        adapter = try RoutineReceipt(kind)
        registry = AdapterRegistry()
        try await registry.register(adapter)
        let grant = WorkspaceRoutineGrant(identity: adapter.identity, generation: "credential-1")
        lookup = { human, alias in human == grantor.humanID && alias == "routine" ? grant : nil }
        let metadata = try await queue.bindWorkspaceRoutine(team: workspace, principal: grantor, routine: "routine", lookup: lookup)
        guard case let .string(id) = metadata["assistant_id"] else { throw QueueError.corruptStore }
        binding = id
        _ = try await queue.assign(team: workspace, principal: sender, id: task, assistantID: binding, text: "Count rows.", lookup: lookup)
    }
}

@Test(arguments: ["grantor-device","sender-device","grantor-generation","sender-generation","credential","removed"])
func pendingWorkspaceAssignmentKeepsBothAuthorities(after invalidation: String) async throws {
    let lab = try await AssignmentLab()
    defer { try? FileManager.default.removeItem(at: lab.folder) }
    _ = try await lab.queue.assign(team: workspace, principal: sibling, id: lab.task, assistantID: lab.binding,
                                    text: "Count rows.", lookup: lab.lookup)
    var policy = WorkspacePolicy()
    switch invalidation {
    case "grantor-device": policy.revoked = grantor.clientID
    case "sender-device": policy.revoked = sender.clientID
    case "grantor-generation": policy.ownerGeneration = "owner-2"
    case "sender-generation": policy.senderGeneration = "member-2"
    default: break
    }
    let restored = try TeamQueue(path: lab.db, authority: policy)
    let lookup: WorkspaceRoutineLookup = { human, routine in
        if invalidation == "removed" { return nil }
        guard let old = lab.lookup(human, routine) else { return nil }
        return WorkspaceRoutineGrant(identity: old.identity, generation: invalidation == "credential" ? "new" : old.generation)
    }
    #expect(try await restored.dispatchOne(registry: lab.registry) == nil)
    #expect(try await restored.dispatchWorkspaceAssignment(registry: lab.registry, lookup: lookup) != nil)
    let rows = try await restored.workspaceAssignments(team: workspace, principal: sibling, id: lab.task)
    #expect(rows.first?["state"] == .string("denied"))
    #expect(await lab.adapter.calls.isEmpty)
}

@Test(arguments: [EventKind.accepted, .completed])
func workspaceReceiptCannotBecomeDelegationOrInventedCompletion(kind: EventKind) async throws {
    let lab = try await AssignmentLab(kind: kind)
    defer { try? FileManager.default.removeItem(at: lab.folder) }
    await #expect(throws: QueueError.denied) {
        try await lab.queue.post(team: workspace, principal: sender, run: lab.binding, message: "raw",
                                 payload: [:], mentions: ["assistant:" + lab.binding], capability: .task)
    }
    _ = try await lab.queue.dispatchWorkspaceAssignment(registry: lab.registry, lookup: lab.lookup)
    let calls = await lab.adapter.calls
    let request = try #require(calls.first)
    #expect(calls.count == 1 && request.payload == ["text": .string("Count rows.")])
    #expect(request.sessionID != lab.binding)
    let fake = try AdapterEvent(identity: request.identity, sessionID: request.sessionID, requestID: request.requestID,
                                eventID: "completion", kind: .completed, payload: [:])
    await #expect(throws: QueueError.denied) { try await lab.queue.record(fake) }
    await #expect(throws: QueueError.denied) { try await lab.queue.postReply(parent: fake, message: "hop", payload: [:]) }
    let successor = UUID().uuidString.lowercased()
    _ = try await lab.queue.assign(team: workspace, principal: sibling, id: successor, assistantID: lab.binding,
                                    text: "Second turn.", lookup: lab.lookup)
    #expect(try await lab.queue.dispatchWorkspaceAssignment(registry: lab.registry, lookup: lab.lookup) == nil)
    try await lab.queue.revokeWorkspaceAssistant(team: workspace, principal: grantor, id: lab.binding)
    let restored = try TeamQueue(path: lab.db, authority: WorkspacePolicy())
    let rows = try await restored.workspaceAssignments(team: workspace, principal: sibling, id: nil)
    #expect(rows.map { $0["state"] } == [.string(kind == .accepted ? "active" : "uncertain"), .string("denied")])
    #expect(try await restored.dispatchWorkspaceAssignment(registry: lab.registry, lookup: lab.lookup) == nil)
    #expect(await lab.adapter.calls.count == 1)
}

@Test func pausedBindingSurvivesReopenWhileAnotherWorkspaceRuns() async throws {
    let lab = try await AssignmentLab()
    defer { try? FileManager.default.removeItem(at: lab.folder) }
    let ownerSibling = QueuePrincipal(humanID: grantor.humanID, clientID: "owner-sibling")
    let other = "workspace/other"
    let summary = try await lab.queue.bindWorkspaceRoutine(team: other, principal: grantor, routine: "routine", lookup: lab.lookup)
    guard case let .string(otherID) = summary["assistant_id"] else { throw QueueError.corruptStore }
    _ = try await lab.queue.assign(team: other, principal: sender, id: UUID().uuidString.lowercased(),
                                   assistantID: otherID, text: "Other workspace.", lookup: lab.lookup)
    let control = try TeamQueue(path: lab.db, authority: WorkspacePolicy())
    #expect(try await !control.workspaceDispatchPaused(team: workspace, principal: sender, id: lab.binding))
    await #expect(throws: QueueError.denied) {
        try await control.setWorkspaceDispatchPaused(team: workspace, principal: sender, id: lab.binding, paused: true)
    }
    await #expect(throws: QueueError.notFound) {
        try await control.setWorkspaceDispatchPaused(team: other, principal: grantor, id: lab.binding, paused: true)
    }
    try await control.setWorkspaceDispatchPaused(team: workspace, principal: ownerSibling, id: lab.binding, paused: true)
    try await control.setWorkspaceDispatchPaused(team: workspace, principal: ownerSibling, id: lab.binding, paused: true)
    let queued = try await lab.queue.assign(team: workspace, principal: sibling, id: UUID().uuidString.lowercased(),
                                           assistantID: lab.binding, text: "While paused.", lookup: lab.lookup)
    #expect(queued["state"] == .string("queued"))
    // A different connection claims after pause has committed. Only the other workspace is eligible.
    #expect(try await lab.queue.dispatchWorkspaceAssignment(registry: lab.registry, lookup: lab.lookup) != nil)
    #expect(try await lab.queue.dispatchWorkspaceAssignment(registry: lab.registry, lookup: lab.lookup) == nil)
    #expect(await lab.adapter.calls.map(\.payload) == [["text": .string("Other workspace.")]])

    let reopened = try TeamQueue(path: lab.db, authority: WorkspacePolicy(revoked: sender.clientID))
    #expect(try await reopened.workspaceDispatchPaused(team: workspace, principal: sibling, id: lab.binding))
    try await reopened.setWorkspaceDispatchPaused(team: workspace, principal: ownerSibling, id: lab.binding, paused: false)
    try await reopened.setWorkspaceDispatchPaused(team: workspace, principal: ownerSibling, id: lab.binding, paused: false)
    // The first sender was revoked during pause. Resuming preserves the original sender of each post.
    #expect(try await reopened.dispatchWorkspaceAssignment(registry: lab.registry, lookup: lab.lookup) != nil)
    #expect(await lab.adapter.calls.count == 1)
    #expect(try await reopened.dispatchWorkspaceAssignment(registry: lab.registry, lookup: lab.lookup) != nil)
    #expect(try await reopened.dispatchWorkspaceAssignment(registry: lab.registry, lookup: lab.lookup) == nil)
    let rows = try await reopened.workspaceAssignments(team: workspace, principal: sibling, id: nil)
    #expect(rows.map { $0["state"] } == [.string("denied"), .string("active")])
    #expect(await lab.adapter.calls.map(\.payload) == [["text": .string("Other workspace.")], ["text": .string("While paused.")]])
    try await reopened.revokeWorkspaceAssistant(team: workspace, principal: ownerSibling, id: lab.binding)
    await #expect(throws: QueueError.notFound) {
        try await reopened.setWorkspaceDispatchPaused(team: workspace, principal: ownerSibling, id: lab.binding, paused: false)
    }
}

@Test(arguments: [false, true])
func pauseAfterClaimPreservesOutstandingSubmission(loseReply: Bool) async throws {
    let lab = try await AssignmentLab()
    defer { try? FileManager.default.removeItem(at: lab.folder) }
    let control = try TeamQueue(path: lab.db, authority: WorkspacePolicy())
    let registry = AdapterRegistry()
    let adapter = try RoutineReceipt {
        // Pause from an independent connection after the submission, before the adapter returns.
        try await control.setWorkspaceDispatchPaused(team: workspace, principal: grantor, id: lab.binding, paused: true)
        if loseReply { throw RuntimeError.dispatchUncertain }
    }
    try await registry.register(adapter)
    #expect(try await lab.queue.dispatchWorkspaceAssignment(registry: registry, lookup: lab.lookup) != nil)
    #expect(try await control.workspaceDispatchPaused(team: workspace, principal: sender, id: lab.binding))
    _ = try await control.assign(team: workspace, principal: sender, id: UUID().uuidString.lowercased(),
                                 assistantID: lab.binding, text: "Next.", lookup: lab.lookup)
    try await control.setWorkspaceDispatchPaused(team: workspace, principal: grantor, id: lab.binding, paused: false)
    #expect(try await lab.queue.dispatchWorkspaceAssignment(registry: registry, lookup: lab.lookup) == nil)
    let deliveries = try await control.history(team: workspace, principal: sender, run: lab.binding).flatMap(\.deliveries)
    #expect(deliveries.map(\.state) == [loseReply ? "uncertain" : "active", "queued"])
    #expect(deliveries.first?.events.map(\.kind) == (loseReply ? [] : [.accepted]))
    #expect(await adapter.calls.count == 1)
}
