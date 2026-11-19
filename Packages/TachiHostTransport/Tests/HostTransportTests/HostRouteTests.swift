import Foundation
import Testing
import TachiAccounts
import TachiRuntime
@testable import TachiHostTransport

private struct Lab {
    let owner: QueuePrincipal
    let queue: TeamQueue
    let accounts: AccountStore
    let hosts: HostStore
    let routes: HostRoutes
    let path: String

    init(_ dir: URL) async throws {
        path = dir.appendingPathComponent("test.sqlite").path
        accounts = try AccountStore(path: path)
        hosts = try HostStore(path: path)
        routes = try HostRoutes(database: path)
        let ticket = try accounts.issueClientInvitation(humanID: "person", scopes: AccountStore.supportedScopes)
        let client = try accounts.redeemClient(invitation: ticket)
        owner = QueuePrincipal(humanID: "person", clientID: client.clientID)
        try accounts.createTeam(humanID: owner.humanID, clientID: owner.clientID, teamID: "team")
        queue = try TeamQueue(path: path, authority: OriginAuthority(accounts))
        for alias in ["folder", "other"] {
            let id = try AdapterIdentity(provider: alias == "folder" ? "tachi-folder" : "fixture", accountID: "person", assistantID: alias)
            try await queue.addAssistant(team: "team", principal: owner, alias: alias, identity: id, sessionID: alias)
        }
        try await queue.createRun(team: "team", principal: owner, run: "run", lead: "assistant:folder", turnLimit: 8)
    }

    func session() throws -> (HostCredential, HostSession) {
        let key = try hosts.pair(pairingSecret: hosts.issuePairing(ownerID: "person"))
        return try (key, hosts.connect(credential: key))
    }
    func scope(_ session: HostSession, folder: String = "selected") throws -> HostScope {
        let grant = try hosts.grant(ownerID: "person", hostID: session.hostID, folderID: folder, action: "write")
        return try HostScope(ownerID: "person", hostID: session.hostID, grantID: grant, folderID: folder,
                             action: "write", relativePath: "brief")
    }
    func post(_ id: String, _ scope: HostScope, alias: String = "folder") async throws {
        try await queue.post(team: "team", principal: owner, run: "run", message: id, payload: ["bodyBase64": .string("YQ==")],
                             directTo: "assistant:" + alias, capability: .task, scope: scope)
    }
    func call<T: Encodable>(_ path: String, _ session: HostSession, _ input: T) async throws -> Data {
        try await routes.handle(route: path, host: session.hostID, bearer: session.secret, body: JSONEncoder().encode(input))
    }
    func next(_ session: HostSession, _ folder: String = "selected") async throws -> HostFolderWork? {
        try await JSONDecoder().decode(Next.self, from: call("next", session, Select(folder))).work
    }
}

private func withLab(_ fn: (Lab) async throws -> Void) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try await fn(Lab(dir))
}

@Test func pulledWorkStaysUncertainAfterRestartAndOnlySameHostReconciles() async throws {
    try await withLab { lab in
        let (key, live) = try lab.session(), (_, other) = try lab.session(), scope = try lab.scope(live)
        try await lab.post("unrelated", scope, alias: "other")
        try await lab.post("selected", scope)
        #expect(try await lab.next(other) == nil)
        #expect(try await lab.next(live, "different-folder") == nil)
        let job = try #require(await lab.next(live))
        #expect(job.body == Data("a".utf8))
        _ = try await lab.call("check", live, Check(job.requestID, scope))
        let replaced = try lab.hosts.connect(credential: key)
        let reopened = try HostRoutes(database: lab.path)
        let encoded = try JSONEncoder().encode(Select("selected"))
        let recovered = try await reopened.handle(route: "next", host: key.hostID, bearer: replaced.secret, body: encoded)
        #expect(try JSONDecoder().decode(Next.self, from: recovered).work == nil)
        await #expect(throws: AccountsError.denied) { try await lab.next(live) }
        await #expect(throws: QueueError.denied) { try await lab.call("check", replaced, Check(job.requestID, scope)) }
        let receipt = HostFolderReceipt(requestID: job.requestID, outcome: .completed, byteCount: 1)
        await #expect(throws: QueueError.denied) { try await lab.call("finish", other, receipt) }
        _ = try await lab.call("finish", replaced, receipt)
        _ = try await lab.call("finish", replaced, receipt)
        await #expect(throws: QueueError.conflict) {
            try await lab.call("finish", replaced, HostFolderReceipt(requestID: job.requestID, outcome: .refused, byteCount: 0))
        }
        let history = try await lab.queue.history(team: "team", principal: lab.owner, run: "run")
        #expect(history[0].deliveries[0].state == "queued")
        #expect(history[1].deliveries[0].events.count == 1)
        #expect(history[1].deliveries[0].state == "completed")
    }
}

@Test func checkRevalidatesExactScopeOriginRunAndGrant() async throws {
    try await withLab { lab in
        let (_, live) = try lab.session(), scope = try lab.scope(live)
        try await lab.post("work", scope)
        let job = try #require(await lab.next(live))
        let wrong = try HostScope(ownerID: scope.ownerID, hostID: scope.hostID, grantID: scope.grantID,
                                  folderID: scope.folderID, action: "write", relativePath: "other")
        await #expect(throws: QueueError.denied) { try await lab.call("check", live, Check(job.requestID, wrong)) }
        try await lab.queue.intervene(team: "team", principal: lab.owner, run: "run", state: .paused)
        await #expect(throws: QueueError.denied) { try await lab.call("check", live, Check(job.requestID, scope)) }
        try await lab.queue.intervene(team: "team", principal: lab.owner, run: "run", state: .running)
        try lab.hosts.revokeGrant(ownerID: scope.ownerID, hostID: scope.hostID, grantID: scope.grantID)
        await #expect(throws: QueueError.denied) { try await lab.call("check", live, Check(job.requestID, scope)) }
    }
    try await withLab { lab in
        let (_, live) = try lab.session(), scope = try lab.scope(live)
        try await lab.post("work", scope)
        let job = try #require(await lab.next(live))
        try lab.accounts.revokeClient(humanID: lab.owner.humanID, clientID: lab.owner.clientID)
        await #expect(throws: QueueError.denied) { try await lab.call("check", live, Check(job.requestID, scope)) }
    }
}

@Test func pairingIsOneUseAndWireCanCarryMaximumWriteWithoutEscapingExpansion() async throws {
    try await withLab { lab in
        let invitation = try lab.hosts.issuePairing(ownerID: "person")
        let empty = try JSONEncoder().encode(Empty())
        let pair = try await lab.routes.handle(route: "pair", host: nil, bearer: invitation, body: empty)
        let key = try JSONDecoder().decode(Key.self, from: pair)
        await #expect(throws: AccountsError.denied) {
            try await lab.routes.handle(route: "pair", host: nil, bearer: invitation, body: empty)
        }
        let connected = try await lab.routes.handle(route: "connect", host: key.hostID, bearer: key.secret, body: empty)
        let lease = try JSONDecoder().decode(Key.self, from: connected)
        let live = HostSession(hostID: key.hostID, secret: lease.secret)
        let scope = try lab.scope(live), bytes = Data(repeating: 255, count: 1_048_576)
        try await lab.queue.post(team: "team", principal: lab.owner, run: "run", message: "maximum",
                                 payload: ["bodyBase64": .string(bytes.base64EncodedString())],
                                 directTo: "assistant:folder", capability: .task, scope: scope)
        let reply = try await lab.call("next", live, Select("selected"))
        #expect(reply.count <= maxResponseBytes)
        #expect(try JSONDecoder().decode(Next.self, from: reply).work?.body == bytes)
        _ = try await lab.call("disconnect", live, Empty())
        await #expect(throws: AccountsError.denied) { try await lab.call("heartbeat", live, Empty()) }
    }
}
