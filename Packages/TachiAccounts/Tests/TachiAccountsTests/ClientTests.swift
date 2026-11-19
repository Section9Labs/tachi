import Foundation
import XCTest
@testable import TachiAccounts

final class ClientTests: XCTestCase {
    func testScopedCredentialsAndRevocation() throws {
        let fixture = try Fixture()
        let api = try AccountStore(path: fixture.path)
        let worker = try AccountStore(path: fixture.path)
        let invite = try api.issueClientInvitation(humanID: "alice", scopes: ["messages:send"])
        let a = try worker.redeemClient(invitation: invite)
        assertDenied { try api.redeemClient(invitation: invite) }
        let b = try worker.redeemClient(invitation: api.issueClientInvitation(humanID: "alice", scopes: ["sessions:read"]))
        let other = try worker.redeemClient(invitation: api.issueClientInvitation(humanID: "bob", scopes: ["sessions:read"]))
        XCTAssertEqual(try api.authenticate(token: a.token).scopes, ["messages:send"])
        XCTAssertEqual(try api.authenticate(token: a.token).humanID, "alice")
        XCTAssertEqual(Set(try api.listClients(humanID: "alice")), [a.clientID, b.clientID])
        XCTAssertFalse(String(reflecting: a).contains(a.token))
        try api.authorizeClient(humanID: "alice", clientID: a.clientID, scope: "messages:send")
        assertDenied { try api.authorizeClient(humanID: "bob", clientID: a.clientID, scope: "messages:send") }
        assertDenied { try api.authorizeClient(humanID: "alice", clientID: a.clientID, scope: "teams:manage") }
        assertDenied { try api.revokeClient(humanID: "bob", clientID: a.clientID) }
        try api.revokeClient(humanID: "alice", clientID: a.clientID)
        assertDenied { try worker.authenticate(token: a.token) }
        assertDenied { try worker.authorizeClient(humanID: "alice", clientID: a.clientID, scope: "messages:send") }
        XCTAssertEqual(try worker.authenticate(token: other.token).humanID, "bob")
        XCTAssertEqual(try worker.authenticate(token: b.token).humanID, "alice")
    }

    func testDeadlineValidationAndAtomicRedemption() async throws {
        let fixture = try Fixture()
        let first = try AccountStore(path: fixture.path, clock: { 1_000 })
        let later = try AccountStore(path: fixture.path, clock: { 1_300 })
        let expired = try first.issueClientInvitation(humanID: "owner", scopes: ["sessions:read"])
        assertDenied { try later.redeemClient(invitation: expired) }
        assertDenied { try first.issueClientInvitation(humanID: "x\0y", scopes: ["sessions:read"]) }
        XCTAssertThrowsError(try first.issueClientInvitation(humanID: "user", scopes: ["*"]))
        let live = try later.issueClientInvitation(humanID: "user", scopes: ["sessions:read"])
        let winners = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    do { _ = try later.redeemClient(invitation: live); return 1 }
                    catch AccountsError.denied { return 0 }
                }
            }
            var count = 0
            for try await result in group { count += result }
            return count
        }
        XCTAssertEqual(winners, 1)
    }
}

final class Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var path: String { directory.appendingPathComponent("policy.sqlite").path }
    init() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

func assertDenied<T>(_ operation: () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try operation(), file: file, line: line) {
        XCTAssertEqual($0 as? AccountsError, .denied, file: file, line: line)
    }
}
