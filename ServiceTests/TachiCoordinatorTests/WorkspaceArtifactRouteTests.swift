import Foundation
import NIOHTTP1
import Testing
import TachiAccounts
import TachiRuntime
@testable import TachiCoordinator

@Test func artifactRouteDerivesOriginAndVerifiesKnownBytes() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.appendingPathComponent("store.sqlite").path
    let accounts = try AccountStore(path: path)
    let invitation = try accounts.issueClientInvitation(humanID: "editor", scopes: AccountStore.supportedScopes)
    let client = try accounts.authenticate(token: accounts.redeemClient(invitation: invitation).token)
    let workspace = UUID().uuidString.lowercased()
    try accounts.createTeam(humanID: client.humanID, clientID: client.clientID, teamID: "workspace/" + workspace)
    let history = try WorkspaceHistory(path: path, authority: CoordinatorAuthority(accounts: accounts))
    let collection = "/v1/workspaces/" + workspace + "/artifacts", id = UUID().uuidString.lowercased()
    func request(_ method: HTTPMethod, _ route: String, _ fields: JSONObject = [:]) async throws -> Reply {
        let head = HTTPRequestHead(version: .http1_1, method: method, uri: route)
        return try await WorkspaceRoute.reply(head, body: JSONEncoder().encode(fields), headerError: nil,
                                              client: client, accounts: accounts, history: history)
    }
    let input: JSONObject = ["artifact_id": .string(id), "name": .string("sample.txt"), "content_type": .string("text/plain"),
                             "audience": .string("room"), "content_base64": .string("YWJj")]
    var forged = input
    forged["origin"] = .string("provider")
    #expect(try await request(.POST, collection, forged).status == .badRequest)
    let saved = try await request(.POST, collection, input)
    #expect(saved.status == .created)
    let metadata = try JSONDecoder().decode(JSONObject.self, from: saved.body)
    #expect(metadata["sha256"] == .string("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
    #expect(metadata["size_bytes"] == .integer(3))
    #expect(metadata["author_id"] == .string("editor"))
    #expect(metadata["origin"] == .string("human_upload"))
    #expect(metadata["content_base64"] == nil)
    let download = try await request(.GET, collection + "/" + id)
    var expected = metadata
    expected["content_base64"] = .string("YWJj")
    #expect(try JSONDecoder().decode(JSONObject.self, from: download.body) == expected)
}
