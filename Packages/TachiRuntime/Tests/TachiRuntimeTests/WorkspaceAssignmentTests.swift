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
        guard team == workspace else { return nil }
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
    private(set) var calls: [DispatchRequest] = []
    init(_ kind: EventKind = .accepted) throws {
        identity = try AdapterIdentity(provider: "grok-bot", accountID: "fixture-account", assistantID: "fixture-routine")
        self.kind = kind
    }
    func dispatch(_ request: DispatchRequest) throws -> [AdapterEvent] {
        calls.append(request)
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
