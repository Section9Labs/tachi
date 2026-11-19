import Foundation
import Testing
import TachiAccounts
import TachiRuntime
@testable import TachiCoordinator

@Test func wrongWorkspaceRedemptionDoesNotConsumeTheInvitation() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let accounts = try AccountStore(path: folder.appendingPathComponent("workspace.sqlite").path)
    func client(_ human: String) throws -> String {
        let invitation = try accounts.issueClientInvitation(humanID: human, scopes: AccountStore.supportedScopes)
        return try accounts.redeemClient(invitation: invitation).clientID
    }
    let owner = try client("owner"), member = try client("member")
    for id in ["workspace/a", "workspace/b"] {
        try accounts.createTeam(humanID: "owner", clientID: owner, teamID: id)
    }
    let invite = try accounts.inviteMember(humanID: "owner", clientID: owner, teamID: "workspace/a", recipientID: "member")
    #expect(throws: AccountsError.denied) {
        _ = try accounts.acceptInvitation(humanID: "member", clientID: member, invitation: invite, expectedTeamID: "workspace/b")
    }
    #expect(try accounts.listTeams(humanID: "member", clientID: member).isEmpty)
    let joined = try accounts.acceptInvitation(humanID: "member", clientID: member, invitation: invite, expectedTeamID: "workspace/a")
    #expect(joined.role == "member")
    #expect(try accounts.listTeams(humanID: "member", clientID: member).map(\.teamID) == ["workspace/a"])
    #expect(throws: AccountsError.denied) {
        _ = try accounts.acceptInvitation(humanID: "member", clientID: member, invitation: invite, expectedTeamID: "workspace/a")
    }
}
