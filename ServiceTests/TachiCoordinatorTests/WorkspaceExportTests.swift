import Foundation
import NIOHTTP1
import Testing
import TachiAccounts
import TachiRuntime
@testable import TachiCoordinator

private struct ExportLab {
    let directory: URL
    let accounts: AccountStore
    let history: WorkspaceHistory
    let workspace = UUID().uuidString.lowercased()
    var team: String { "workspace/" + workspace }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let path = directory.appendingPathComponent("service.sqlite").path
        accounts = try AccountStore(path: path)
        history = try WorkspaceHistory(path: path, authority: CoordinatorAuthority(accounts: accounts))
    }

    func client(_ name: String, scopes: Set<String> = AccountStore.supportedScopes) throws -> ClientPrincipal {
        let invite = try accounts.issueClientInvitation(humanID: name, scopes: scopes)
        return try accounts.authenticate(token: accounts.redeemClient(invitation: invite).token)
    }

    func join(_ client: ClientPrincipal, owner: ClientPrincipal) throws {
        let invite = try accounts.inviteMember(humanID: owner.humanID, clientID: owner.clientID, teamID: team,
                                               recipientID: client.humanID)
        _ = try accounts.acceptInvitation(humanID: client.humanID, clientID: client.clientID,
                                          invitation: invite, expectedTeamID: team)
    }

    func read(_ client: ClientPrincipal, route: String = "export", status: HTTPResponseStatus = .ok) async throws -> JSONObject {
        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/v1/workspaces/" + workspace + "/" + route)
        let response = try await WorkspaceRoute.reply(head, body: Data(), headerError: nil, client: client,
                                                       accounts: accounts, history: history)
        #expect(response.status == status)
        return try JSONDecoder().decode(JSONObject.self, from: response.body)
    }

    func message(_ client: ClientPrincipal, to recipient: String? = nil) async throws {
        let id = UUID().uuidString.lowercased()
        try await history.post(team: team, principal: QueuePrincipal(humanID: client.humanID, clientID: client.clientID),
                               id: id, text: "Synthetic " + id, recipient: recipient)
    }

    @discardableResult
    func artifact(_ client: ClientPrincipal, bytes: Data, to recipient: String? = nil) async throws -> String {
        let id = UUID().uuidString.lowercased()
        let file = try WorkspaceArtifactUpload(id: id, name: "synthetic.bin", contentType: "application/octet-stream",
                                               bytes: bytes, recipient: recipient, sourceMessage: nil, sourceTask: nil, fixture: true)
        _ = try await history.shareArtifact(file, team: team, principal: QueuePrincipal(humanID: client.humanID, clientID: client.clientID),
                                            sha256: WorkspaceArtifactRoute.digest)
        return id
    }
}

@Test func workspaceExportMatchesLiveProjectionsAcrossRejoin() async throws {
    let lab = try ExportLab()
    defer { try? FileManager.default.removeItem(at: lab.directory) }
    let owner = try lab.client("owner"), sender = try lab.client("sender"), reader = try lab.client("reader")
    try lab.accounts.createTeam(humanID: owner.humanID, clientID: owner.clientID, teamID: lab.team)
    try lab.join(sender, owner: owner)
    try lab.join(reader, owner: owner)
    try await lab.message(sender)
    try await lab.message(sender, to: reader.humanID)
    try await lab.message(reader, to: sender.humanID)
    let room = try await lab.artifact(owner, bytes: Data([0, 1]))
    let dm = try await lab.artifact(sender, bytes: Data([255, 2]), to: reader.humanID)
    let reply = try await lab.artifact(reader, bytes: Data([3]), to: sender.humanID)
    _ = try lab.accounts.inviteMember(humanID: owner.humanID, clientID: owner.clientID, teamID: lab.team, recipientID: "pending")

    func check(_ client: ClientPrincipal, count: Int, ids: [String]) async throws {
        let messages = try await lab.read(client, route: "messages")
        guard case let .array(rows) = messages["messages"] else { Issue.record("Missing transcript"); return }
        #expect(rows.count == count)
        var files = [JSONValue]()
        for id in ids { files.append(.object(try await lab.read(client, route: "artifacts/" + id))) }
        let expected: JSONObject = ["workspace_id": .string(lab.workspace), "messages": .array(rows), "artifacts": .array(files)]
        #expect(try await lab.read(client) == expected)
    }

    try await check(owner, count: 1, ids: [room])
    try await check(reader, count: 3, ids: [room, dm, reply])
    try await check(sender, count: 3, ids: [room, dm, reply])
    let sendOnly = try lab.client("reader", scopes: ["messages:send"])
    _ = try await lab.read(sendOnly, status: .forbidden)
    try lab.accounts.revokeMember(humanID: owner.humanID, clientID: owner.clientID, teamID: lab.team, recipientID: reader.humanID)
    _ = try await lab.read(reader, status: .notFound)
    try lab.join(reader, owner: owner)
    try await check(reader, count: 1, ids: [room])
    try await check(sender, count: 3, ids: [room, dm, reply])
}

@Test(arguments: ["messages", "artifacts", "bytes"])
func exportLimitsCountOnlyVisibleContent(_ dimension: String) async throws {
    let lab = try ExportLab()
    defer { try? FileManager.default.removeItem(at: lab.directory) }
    let owner = try lab.client("owner"), member = try lab.client("member")
    try lab.accounts.createTeam(humanID: owner.humanID, clientID: owner.clientID, teamID: lab.team)
    try lab.join(member, owner: owner)
    switch dimension {
    case "messages":
        for _ in 0..<100 { try await lab.message(member, to: member.humanID) }
    case "artifacts":
        for _ in 0..<16 { try await lab.artifact(member, bytes: Data(), to: member.humanID) }
    default:
        let data = Data(repeating: 0xff, count: 1_048_576)
        for _ in 0..<4 { try await lab.artifact(member, bytes: data, to: member.humanID) }
    }
    _ = try await lab.read(member)
    if dimension == "messages" { try await lab.message(member, to: member.humanID) }
    else { try await lab.artifact(member, bytes: Data([1]), to: member.humanID) }
    #expect(try await lab.read(member, status: .payloadTooLarge) == ["error": .string("export_limit")])
    #expect(try await lab.read(owner) == ["workspace_id": .string(lab.workspace), "messages": .array([]), "artifacts": .array([])])
}

@Test func onlyTheUploadingGenerationCanRemoveAnArtifactFromWorkspaceReads() async throws {
    let lab = try ExportLab()
    defer { try? FileManager.default.removeItem(at: lab.directory) }
    let owner = try lab.client("owner"), author = try lab.client("author")
    let readOnly = try lab.client("author", scopes: ["sessions:read"])
    let sibling = try lab.client("author", scopes: ["messages:send"])
    try lab.accounts.createTeam(humanID: owner.humanID, clientID: owner.clientID, teamID: lab.team)
    try lab.join(author, owner: owner)
    let direct = try await lab.artifact(author, bytes: Data([0xff]), to: owner.humanID)
    let room = try await lab.artifact(author, bytes: Data([0x7f]))
    func delete(_ id: String, as client: ClientPrincipal, length: String? = nil) async throws -> Reply {
        var head = HTTPRequestHead(version: .http1_1, method: .DELETE, uri: "/v1/workspaces/" + lab.workspace + "/artifacts/" + id)
        if let length { head.headers.add(name: "Content-Length", value: length) }
        return try await WorkspaceRoute.reply(head, body: Data(), headerError: nil, client: client,
                                              accounts: lab.accounts, history: lab.history)
    }

    #expect(try await delete(direct, as: owner).status == .notFound)
    #expect(try await delete(direct, as: readOnly).status == .forbidden)
    #expect(try await delete(direct, as: sibling, length: "1").status == .badRequest)
    let removed = try await delete(direct, as: sibling, length: "0")
    #expect(removed.status == .ok)
    #expect(try JSONDecoder().decode(JSONObject.self, from: removed.body) == ["deleted": .bool(true)])
    #expect(try await delete(direct, as: author).status == .notFound)
    for client in [owner, author] {
        _ = try await lab.read(client, route: "artifacts/" + direct, status: .notFound)
        let remaining = try await lab.read(client, route: "artifacts/" + room)
        #expect(try await lab.read(client)["artifacts"] == .array([.object(remaining)]))
    }

    try lab.accounts.revokeMember(humanID: owner.humanID, clientID: owner.clientID, teamID: lab.team, recipientID: author.humanID)
    #expect(try await delete(room, as: author).status == .notFound)
    try lab.join(author, owner: owner)
    _ = try await lab.read(author, route: "artifacts/" + room)
    #expect(try await delete(room, as: author).status == .notFound)
}
