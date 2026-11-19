import Foundation
import XCTest
import TachiAccounts

final class MigrationTests: XCTestCase {
    // Opt in only in a source checkout. The library, CLI and ordinary swift test
    // do not need the historical runtime installed.
    func testBidirectionalPythonStoreCompatibility() throws {
        guard let checkout = ProcessInfo.processInfo.environment["TACHI_PYTHON_ORACLE"] else {
            throw XCTSkip("Set TACHI_PYTHON_ORACLE to the repository root to run the compatibility oracle")
        }
        let fixture = try Fixture()

        func python(_ script: String, input: String = "") throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "-c", """
                import sys
                from tachi.hosts import AccountStore
                store = AccountStore(sys.argv[1])
                """ + "\n" + script, fixture.path]
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

        let old = try python("print(store.issue_client_invitation('person', ['messages:send']))")
        let api = try AccountStore(path: fixture.path)
        let swiftCredential = try api.redeemClient(invitation: old)
        XCTAssertEqual(try python("print(store.authenticate(sys.stdin.read()).human_id)", input: swiftCredential.token), "person")
        let invite = try api.issueClientInvitation(humanID: "person", scopes: ["sessions:read"])
        let oldToken = try python("print(store.redeem_client(sys.stdin.read()).token)", input: invite)
        let principal = try AccountStore(path: fixture.path).authenticate(token: oldToken)
        XCTAssertEqual(principal.humanID, "person")
        XCTAssertEqual(principal.scopes, ["sessions:read"])
        _ = try python("store.revoke_client('person', sys.stdin.read())", input: principal.clientID)
        assertDenied { try api.authenticate(token: oldToken) }
    }
}
