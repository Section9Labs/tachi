import XCTest
import TachiAccounts

final class TeamHostTests: XCTestCase {
    func testMembershipGenerationAndIssuedInvitationRevocation() throws {
        let fixture = try Fixture()
        let store = try AccountStore(path: fixture.path)
        let worker = try AccountStore(path: fixture.path)
        func client(_ human: String) throws -> String {
            try store.redeemClient(invitation: store.issueClientInvitation(humanID: human, scopes: AccountStore.supportedScopes)).clientID
        }
        let a = try client("a"), b = try client("b"), c = try client("c")
        try store.createTeam(humanID: "a", clientID: a, teamID: "team")
        assertDenied { try store.createTeam(humanID: "b", clientID: b, teamID: "team") }
        func invite() throws -> String { try store.inviteMember(humanID: "a", clientID: a, teamID: "team", recipientID: "b") }
        let old = try invite(), ticket = try invite()
        assertDenied { try worker.acceptInvitation(humanID: "b", clientID: b, invitation: old) }
        assertDenied { try worker.acceptInvitation(humanID: "c", clientID: c, invitation: ticket) }
        let original = try worker.acceptInvitation(humanID: "b", clientID: b, invitation: ticket)
        XCTAssertEqual(try store.teamRole(teamID: "team", humanID: "b"), "member")
        assertDenied { try worker.authorizeTeam(humanID: "b", clientID: b, teamID: "team", scope: "teams:manage") }
        try store.revokeMember(humanID: "a", clientID: a, teamID: "team", recipientID: "b")
        XCTAssertNil(try worker.teamMembership(teamID: "team", humanID: "b"))
        let next = try worker.acceptInvitation(humanID: "b", clientID: b, invitation: invite())
        XCTAssertNotEqual(original.membershipID, next.membershipID)
        assertDenied { try worker.authorizeMembership(humanID: "b", clientID: b, teamID: "team",
                                                       scope: "messages:send", membershipID: original.membershipID) }
        XCTAssertEqual(try worker.authorizeTeam(humanID: "b", clientID: b, teamID: "team", scope: "messages:send"), "member")
        let pending = try store.inviteMember(humanID: "a", clientID: a, teamID: "team", recipientID: "c")
        try store.revokeClient(humanID: "a", clientID: a)
        assertDenied { try worker.acceptInvitation(humanID: "c", clientID: c, invitation: pending) }
    }

    func testHostIsolationLeaseAndRevocationAcrossReopen() throws {
        let fixture = try Fixture()
        let hosts = try HostStore(path: fixture.path, clock: { 1000 })
        let worker = try HostStore(path: fixture.path, clock: { 1001 })
        let invite = try hosts.issuePairing(ownerID: "owner")
        let credential = try worker.pair(pairingSecret: invite)
        assertDenied { try hosts.pair(pairingSecret: invite) }
        let first = try hosts.connect(credential: credential)
        let live = try hosts.connect(credential: credential)
        assertDenied { try worker.disconnect(session: first) }
        assertDenied { try worker.heartbeat(session: first) }
        let other = try hosts.connect(credential: hosts.pair(pairingSecret: hosts.issuePairing(ownerID: "owner")))
        assertDenied { try hosts.grant(ownerID: "other", hostID: live.hostID, folderID: "books", action: "read") }
        let grant = try hosts.grant(ownerID: "owner", hostID: live.hostID, folderID: "books", action: "read")
        func check(_ session: HostSession, _ store: HostStore, _ action: String = "read", _ path: String = "a/b") throws {
            try store.authorize(ownerID: "owner", session: session, grantID: grant, folderID: "books", action: action, relativePath: path)
        }
        try check(live, worker)
        assertDenied { try check(other, worker) }
        assertDenied { try check(live, worker, "write") }
        for path in ["", ".", "a/../b", "/file", "a//b", "a\\b", "a:\u{301}b", "a\0b"] {
            assertDenied { try check(live, worker, "read", path) }
        }
        try worker.heartbeat(session: live)
        assertDenied { try check(live, HostStore(path: fixture.path, clock: { 1031 })) }
        try hosts.revokeGrant(ownerID: "owner", hostID: live.hostID, grantID: grant)
        assertDenied { try check(live, worker) }
        try hosts.disconnect(session: live)
        assertDenied { try hosts.heartbeat(session: live) }
        _ = try hosts.connect(credential: credential)
        try hosts.revokeHost(ownerID: "owner", hostID: live.hostID)
        assertDenied { try worker.connect(credential: credential) }
        try worker.heartbeat(session: other)
    }
}
