import Foundation
import XCTest
import TachiAccounts

final class MigrationTests: XCTestCase {
    // Opt in only in a source checkout. The library, CLI and ordinary swift test
    // do not need the historical runtime installed.
    func testBidirectionalPythonStoreCompatibility() throws {
        let fixture = try Fixture()
        let old = try python(fixture.path, "print(store.issue_client_invitation('person', ['messages:send']))")
        let api = try AccountStore(path: fixture.path)
        let swiftCredential = try api.redeemClient(invitation: old)
        XCTAssertEqual(try python(fixture.path, "print(store.authenticate(sys.stdin.read()).human_id)", input: swiftCredential.token), "person")
        let invite = try api.issueClientInvitation(humanID: "person", scopes: ["sessions:read"])
        let oldToken = try python(fixture.path, "print(store.redeem_client(sys.stdin.read()).token)", input: invite)
        let principal = try AccountStore(path: fixture.path).authenticate(token: oldToken)
        XCTAssertEqual(principal.humanID, "person")
        XCTAssertEqual(principal.scopes, ["sessions:read"])
        _ = try python(fixture.path, "store.revoke_client('person', sys.stdin.read())", input: principal.clientID)
        assertDenied { try api.authenticate(token: oldToken) }
    }
    func testLegacyTeamAndLiveHostGrantSurviveSwitchingWriters() throws {
        let fixture = try Fixture()
        let seed = try python(fixture.path, """
            import json
            def client(human):
                return store.redeem_client(store.issue_client_invitation(human, ['teams:manage','messages:send'])).client_id
            a, b = client('a'), client('b')
            store.create_team('a', a, 'team')
            membership = store.accept_invitation('b', b, store.invite_member('a', a, 'team', 'b'))
            hosts = HostStore(sys.argv[1], clock=lambda: 1000)
            session = hosts.connect(hosts.pair(hosts.issue_pairing('a')))
            grant = hosts.grant('a', session.host_id, 'shared', 'read')
            print(json.dumps([a, b, membership.membership_id, session.host_id, session.secret, grant]))
            """)
        let values = try JSONDecoder().decode([String].self, from: Data(seed.utf8))
        let api = try AccountStore(path: fixture.path)
        _ = try api.authorizeMembership(humanID: "b", clientID: values[1], teamID: "team",
                                        scope: "messages:send", membershipID: values[2])
        let hosts = try HostStore(path: fixture.path, clock: { 1001 })
        let session = HostSession(hostID: values[3], secret: values[4])
        try hosts.authorize(ownerID: "a", session: session, grantID: values[5], folderID: "shared",
                            action: "read", relativePath: "brief")
        try api.revokeMember(humanID: "a", clientID: values[0], teamID: "team", recipientID: "b")
        try hosts.revokeGrant(ownerID: "a", hostID: session.hostID, grantID: values[5])
        _ = try python(fixture.path, """
            import json
            a, b, membership, host, secret, grant = json.load(sys.stdin)
            assert store.team_membership('team', 'b') is None
            hosts = HostStore(sys.argv[1], clock=lambda: 1001)
            try:
                hosts.authorize('a', HostSession(host, secret), grant, 'shared', 'read', 'brief')
            except PermissionError:
                pass
            else:
                raise AssertionError('revoked grant accepted')
            """, input: seed)
    }

    private func python(_ path: String, _ script: String, input: String = "") throws -> String {
        guard let checkout = ProcessInfo.processInfo.environment["TACHI_PYTHON_ORACLE"] else {
            throw XCTSkip("Set TACHI_PYTHON_ORACLE to the repository root to run the compatibility oracle")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", """
            import sys
            from tachi.hosts import AccountStore, HostStore, HostSession
            store = AccountStore(sys.argv[1])
            """ + "\n" + script, path]
        process.currentDirectoryURL = URL(fileURLWithPath: checkout)
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let result = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: result, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}
