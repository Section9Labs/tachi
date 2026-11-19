import Foundation
import Testing
import TachiAccounts
import TachiRuntime
@testable import TachiCoordinator

@Test func queuedWorkRechecksAccountAndHostOnTheSharedDatabase() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("test.sqlite").path
    let accounts = try AccountStore(path: path)
    let hosts = try HostStore(path: path)
    func client() throws -> QueuePrincipal {
        let invitation = try accounts.issueClientInvitation(humanID: "owner", scopes: AccountStore.supportedScopes)
        let identity = try accounts.authenticate(token: accounts.redeemClient(invitation: invitation).token)
        return QueuePrincipal(humanID: identity.humanID, clientID: identity.clientID)
    }
    let origin = try client(), sibling = try client()
    try accounts.createTeam(humanID: sibling.humanID, clientID: sibling.clientID, teamID: "team")
    let policy = CoordinatorAuthority(accounts: accounts)
    let queue = try TeamQueue(path: path, authority: policy)
    let registry = AdapterRegistry()
    let adapter = try ReferenceAdapter(identity: AdapterIdentity(provider: "fixture", accountID: "local", assistantID: "one"))
    try await registry.register(adapter)
    try await queue.addAssistant(team: "team", principal: sibling, alias: "worker", identity: adapter.identity, sessionID: "session")
    try await queue.createRun(team: "team", principal: sibling, run: "work", lead: "assistant:worker", turnLimit: 10)

    let host = try hosts.pair(pairingSecret: hosts.issuePairing(ownerID: "owner"))
    let session = try hosts.connect(credential: host)
    let grant = try hosts.grant(ownerID: "owner", hostID: host.hostID, folderID: "folder", action: "read")
    let scope = try HostScope(ownerID: "owner", hostID: host.hostID, grantID: grant, folderID: "folder",
                              action: "read", relativePath: "note.txt")
    func post(_ id: String, from principal: QueuePrincipal) async throws {
        try await queue.post(team: "team", principal: principal, run: "work", message: id, payload: [:],
                             directTo: "assistant:worker", scope: scope)
    }
    try await post("revoked-client", from: origin)
    try await post("authorized-sibling", from: sibling)
    try await post("revoked-grant", from: sibling)
    try accounts.revokeClient(humanID: origin.humanID, clientID: origin.clientID)

    let worker = HostWorker(store: hosts, session: session)
    for _ in 0..<2 {
        _ = try await queue.dispatchOne(registry: registry, host: worker)
    }
    try hosts.revokeGrant(ownerID: "owner", hostID: host.hostID, grantID: grant)
    _ = try await queue.dispatchOne(registry: registry, host: worker)
    let messages = try await queue.history(team: "team", principal: sibling, run: "work")
    #expect(messages.flatMap(\.deliveries).map(\.state) == ["denied", "completed", "blocked"])
    #expect(await adapter.calls.count == 1)
}
