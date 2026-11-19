import Foundation
import XCTest
import TachiAccounts

final class FolderTests: XCTestCase {
    #if os(macOS)
    func testConfinementAndExclusivePublication() throws {
        let fixture = try Fixture()
        let host = try HostStore(path: fixture.path)
        let session = try host.connect(credential: host.pair(pairingSecret: host.issuePairing(ownerID: "a")))
        let parent = try physicalPath(fixture.directory)
        let selected = parent.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        let executor = try FolderExecutor(folder: selected.path, hostID: session.hostID, authorize: check(host))
        let reader = try scoped(host, session, executor, "read")
        let writer = try scoped(host, session, executor, "write")
        let bytes = Data("synthetic".utf8)
        _ = try executor.execute(writer, session: session, body: bytes)
        XCTAssertThrowsError(try executor.execute(writer, session: session, body: Data()))
        XCTAssertEqual(try executor.execute(reader, session: session), bytes)
        let file = selected.appendingPathComponent("brief")
        let outside = parent.appendingPathComponent("outside")
        try FileManager.default.linkItem(at: file, to: outside)
        assertDenied { try executor.execute(reader, session: session) }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        assertDenied { try executor.execute(reader, session: session) }
        XCTAssertThrowsError(try executor.execute(writer, session: session, body: Data()))
        XCTAssertEqual(try Data(contentsOf: outside), bytes)
        let nested = try scoped(host, session, executor, "write", name: "child/file")
        XCTAssertThrowsError(try executor.execute(nested, session: session, body: bytes)) {
            XCTAssertEqual($0 as? FolderError, .directChildrenOnly)
        }
        let moved = parent.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: selected, to: moved)
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: parent)
        let pinned = try scoped(host, session, executor, "write", name: "pinned")
        _ = try executor.execute(pinned, session: session, body: bytes)
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("pinned")), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("pinned").path))
        executor.close()
        assertDenied { try executor.execute(reader, session: session) }
    }

    func testRevocationAfterStagingAndReplacementBeforeRelease() throws {
        let fixture = try Fixture()
        let host = try HostStore(path: fixture.path)
        let session = try host.connect(credential: host.pair(pairingSecret: host.issuePairing(ownerID: "a")))
        let root = try physicalPath(fixture.directory)
        let file = root.appendingPathComponent("brief")
        let writes = Counter()
        let writer = try FolderExecutor(folder: root.path, hostID: session.hostID) { scope, session in
            if writes.next() == 2 {
                try host.revokeGrant(ownerID: scope.ownerID, hostID: scope.hostID, grantID: scope.grantID)
            }
            try check(host)(scope, session)
        }
        let scope = try scoped(host, session, writer, "write")
        assertDenied { try writer.execute(scope, session: session, body: Data("never published".utf8)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try Data("selected".utf8).write(to: file)
        let reads = Counter()
        let reader = try FolderExecutor(folder: root.path, hostID: session.hostID) { scope, session in
            if reads.next() == 4 {
                try Data("replacement".utf8).write(to: file, options: .atomic)
            }
            try check(host)(scope, session)
        }
        let read = try scoped(host, session, reader, "read")
        XCTAssertThrowsError(try reader.execute(read, session: session)) {
            XCTAssertEqual($0 as? FolderError, .fileChanged)
        }
        try host.disconnect(session: session)
        assertDenied { try reader.execute(read, session: session) }
    }
    #else
    func testUnavailablePlatformFailsClosed() {
        XCTAssertThrowsError(try FolderExecutor(folder: "/", hostID: "host") { _, _ in }) {
            XCTAssertEqual($0 as? FolderError, .unavailable)
        }
    }
    #endif
}

#if os(macOS)
private func physicalPath(_ directory: URL) throws -> URL {
    guard let physical = realpath(directory.path, nil) else { throw FolderError.posix(errno) }
    defer { free(physical) }
    return URL(fileURLWithPath: String(cString: physical))
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

private func check(_ host: HostStore) -> FolderExecutor.Authorize {
    { scope, session in
        try host.authorize(ownerID: scope.ownerID, session: session, grantID: scope.grantID,
                           folderID: scope.folderID, action: scope.action, relativePath: scope.relativePath)
    }
}

private func scoped(_ host: HostStore, _ session: HostSession, _ executor: FolderExecutor,
                    _ action: String, name: String = "brief") throws -> FolderScope {
    let grant = try host.grant(ownerID: "a", hostID: session.hostID, folderID: executor.folderID, action: action)
    return FolderScope(ownerID: "a", hostID: session.hostID, grantID: grant, folderID: executor.folderID,
                       action: action, relativePath: name)
}
#endif
