import Foundation
import Testing
@testable import TachiRuntime

private struct ArtifactPolicy: QueueAuthority {
    func membershipID(team: String, humanID: String) throws -> String? {
        team == "workspace" && ["author", "reader", "other"].contains(humanID) ? humanID + "-generation" : nil
    }

    func authorize(_ principal: QueuePrincipal, team: String, scope: String, membershipID: String?) throws -> String {
        guard let current = try self.membershipID(team: team, humanID: principal.humanID),
              membershipID == nil || current == membershipID else { throw QueueError.denied }
        return current
    }
}

private struct ArtifactLab {
    let directory: URL
    let path: String
    let history: WorkspaceHistory
    let principal = QueuePrincipal(humanID: "author", clientID: "fixture-device")

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        path = directory.appendingPathComponent("fixture.sqlite").path
        history = try WorkspaceHistory(path: path, authority: ArtifactPolicy())
    }

    func upload(id: String = UUID().uuidString.lowercased(), bytes: Data = Data(), to: String? = nil,
                task: String? = nil) throws -> WorkspaceArtifactUpload {
        try WorkspaceArtifactUpload(id: id, name: "fixture.bin", contentType: "application/octet-stream",
                                    bytes: bytes, recipient: to, sourceMessage: nil, sourceTask: task, fixture: true)
    }

    func share(_ upload: WorkspaceArtifactUpload, on store: WorkspaceHistory) async throws -> JSONObject {
        // These store tests exercise authorization, concurrency and limits. HTTP tests use the production SHA-256.
        try await store.shareArtifact(upload, team: "workspace", principal: principal, sha256: { _ in "fixture-digest" })
    }
}

@Test func stableReplayAndCompetingWritersAtArtifactCountLimit() async throws {
    let lab = try ArtifactLab()
    defer { try? FileManager.default.removeItem(at: lab.directory) }
    let second = try WorkspaceHistory(path: lab.path, authority: ArtifactPolicy())
    for _ in 0..<254 { _ = try await lab.share(lab.upload(), on: lab.history) }
    let duplicate = try lab.upload()
    async let firstReceipt = lab.share(duplicate, on: lab.history)
    async let secondReceipt = lab.share(duplicate, on: second)
    let (left, right) = try await (firstReceipt, secondReceipt)
    #expect(left == right)
    let accepted = try await withThrowingTaskGroup(of: WorkspaceArtifactUpload?.self) { group in
        for store in [lab.history, second] {
            let item = try lab.upload()
            group.addTask {
                do {
                    _ = try await lab.share(item, on: store)
                    return item
                } catch WorkspaceArtifactError.limitExceeded { return nil }
            }
        }
        var accepted: [WorkspaceArtifactUpload] = []
        for try await result in group { if let result { accepted.append(result) } }
        return accepted
    }
    #expect(accepted.count == 1)
    let winner = try #require(accepted.first)
    _ = try await lab.share(winner, on: second)
    await #expect(throws: QueueError.conflict) { _ = try await lab.share(lab.upload(id: winner.id, bytes: Data([1])), on: second) }
    #expect(try await second.artifacts(team: "workspace", principal: lab.principal).count == 256)
    try await second.deleteArtifact(team: "workspace", principal: lab.principal, id: winner.id)
    _ = try await lab.share(lab.upload(), on: lab.history)
}

@Test func byteQuotaAllowsEmptyArtifactsAndReplayAtCapacity() async throws {
    let lab = try ArtifactLab()
    defer { try? FileManager.default.removeItem(at: lab.directory) }
    let full = Data(repeating: 0xFF, count: WorkspaceArtifactUpload.byteLimit)
    let original = try lab.upload(bytes: full)
    _ = try await lab.share(original, on: lab.history)
    for _ in 1..<64 { _ = try await lab.share(lab.upload(bytes: full), on: lab.history) }
    await #expect(throws: WorkspaceArtifactError.self) {
        _ = try await lab.share(lab.upload(bytes: Data([1])), on: lab.history)
    }
    _ = try await lab.share(original, on: lab.history)
    _ = try await lab.share(lab.upload(), on: lab.history)
    try await lab.history.deleteArtifact(team: "workspace", principal: lab.principal, id: original.id)
    _ = try await lab.share(lab.upload(bytes: full), on: lab.history)
}

@Test func privateTaskLinksKeepAudienceAndUploaderOrigin() async throws {
    let lab = try ArtifactLab()
    defer { try? FileManager.default.removeItem(at: lab.directory) }
    let queue = try TeamQueue(path: lab.path, authority: ArtifactPolicy())
    let identity = try AdapterIdentity(provider: "fixture", accountID: "fixture", assistantID: "lead")
    try await queue.addAssistant(team: "workspace", principal: lab.principal, alias: "lead", identity: identity, sessionID: "fixture")
    try await queue.createRun(team: "workspace", principal: lab.principal, run: "run", lead: "assistant:lead", turnLimit: 1)
    try await queue.post(team: "workspace", principal: lab.principal, run: "run", message: "task",
                         payload: [:], directTo: "human:reader", capability: .task)
    let item = try lab.upload(to: "reader", task: "task")
    let receipt = try await lab.share(item, on: lab.history)
    #expect(receipt["origin"] == .string("synthetic_fixture"))
    #expect(receipt["source_task_id"] == .string("task"))
    for recipient in [nil, "other"] as [String?] {
        await #expect(throws: QueueError.denied) { _ = try await lab.share(lab.upload(to: recipient, task: "task"), on: lab.history) }
    }
    await #expect(throws: QueueError.notFound) { _ = try await lab.share(lab.upload(task: "run"), on: lab.history) }
}

@Test func corruptedArtifactBytesAreNeverReturned() async throws {
    let lab = try ArtifactLab()
    defer { try? FileManager.default.removeItem(at: lab.directory) }
    let item = try lab.upload(bytes: Data("a".utf8))
    let checksum: @Sendable (Data) -> String = { $0.base64EncodedString() }
    _ = try await lab.history.shareArtifact(item, team: "workspace", principal: lab.principal, sha256: checksum)
    let db = try RuntimeDatabase(path: lab.path)
    try db.query("UPDATE rt_workspace_artifact SET content_base64=? WHERE artifact=?", [Data("b".utf8).base64EncodedString(),item.id])
    await #expect(throws: QueueError.corruptStore) {
        _ = try await lab.history.artifact(team: "workspace", principal: lab.principal, id: item.id, sha256: checksum)
    }
    await #expect(throws: QueueError.corruptStore) {
        _ = try await lab.history.export(team: "workspace", principal: lab.principal, sha256: checksum)
    }
}

@Test func deletionUpgradesExistingArtifactRowsAndReservesOnlyTheirIDs() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("old.sqlite").path
    let db = try RuntimeDatabase(path: path)
    let schema = try #require(Bundle.module.url(forResource: "workspace-artifact-before-deletion", withExtension: "sql",
                                                subdirectory: "Fixtures"))
    try db.query(String(contentsOf: schema, encoding: .utf8))
    let principal = QueuePrincipal(humanID: "author", clientID: "original-device")
    let queue = try TeamQueue(path: path, authority: ArtifactPolicy())
    let identity = try AdapterIdentity(provider: "fixture", accountID: "synthetic", assistantID: "lead")
    try await queue.addAssistant(team: "workspace", principal: principal, alias: "lead", identity: identity, sessionID: "fixture")
    try await queue.createRun(team: "workspace", principal: principal, run: "run", lead: "assistant:lead", turnLimit: 1)
    try await queue.post(team: "workspace", principal: principal, run: "run", message: "source-task", payload: [:],
                         directTo: "assistant:lead", capability: .task)
    let deliveries = try db.query("SELECT * FROM rt_delivery")
    #expect(deliveries.count == 1 && deliveries.first?["state"] == "queued")
    let id = UUID().uuidString.lowercased()
    let oldInsert = """
        INSERT INTO rt_workspace_artifact(team,artifact,name,content_type,size_bytes,sha256,content_base64,
            origin,author,author_client,author_membership,source_task)
        VALUES ('workspace',?,'legacy.txt','text/plain',1,'fixture-digest','YQ==','human_upload',
                'author','original-device','author-generation','source-task')
        """
    try db.query(oldInsert, [id])
    let history = try WorkspaceHistory(path: path, authority: ArtifactPolicy())
    let sibling = QueuePrincipal(humanID: "author", clientID: "another-device")
    let file = try await history.artifact(team: "workspace", principal: sibling, id: id, sha256: { _ in "fixture-digest" })
    #expect(file["content_base64"] == .string("YQ=="))

    // A failed reservation must roll back the removal too.
    try db.query("""
        CREATE TRIGGER fail_test_reservation BEFORE INSERT ON rt_deleted_workspace_artifact
        BEGIN SELECT RAISE(ABORT,'test failure'); END
        """)
    await #expect(throws: QueueError.conflict) { try await history.deleteArtifact(team: "workspace", principal: sibling, id: id) }
    #expect(try await history.artifacts(team: "workspace", principal: sibling).count == 1)
    try db.query("DROP TRIGGER fail_test_reservation")
    try await history.deleteArtifact(team: "workspace", principal: sibling, id: id)

    let reopened = try WorkspaceHistory(path: path, authority: ArtifactPolicy())
    #expect(try await reopened.artifacts(team: "workspace", principal: sibling).isEmpty)
    #expect(try db.query("SELECT * FROM rt_workspace_artifact").isEmpty)
    #expect(try db.query("SELECT * FROM rt_deleted_workspace_artifact") == [["team":"workspace","artifact":id]])
    #expect(throws: QueueError.conflict) { try db.query(oldInsert, [id]) }
    #expect(try db.query("SELECT * FROM rt_delivery") == deliveries)
    #expect(try db.query("SELECT * FROM rt_event").isEmpty)
    await #expect(throws: QueueError.notFound) { try await reopened.deleteArtifact(team: "workspace", principal: sibling, id: id) }
}

@Test func concurrentUploadReplayCannotResurrectDeletedArtifact() async throws {
    let lab = try ArtifactLab()
    defer { try? FileManager.default.removeItem(at: lab.directory) }
    let other = try WorkspaceHistory(path: lab.path, authority: ArtifactPolicy())
    let item = try lab.upload(bytes: Data([0xff]), to: "reader")
    _ = try await lab.share(item, on: lab.history)
    try await withThrowingTaskGroup(of: Void.self) { tasks in
        tasks.addTask { try await lab.history.deleteArtifact(team: "workspace", principal: lab.principal, id: item.id) }
        tasks.addTask {
            do { _ = try await lab.share(item, on: other) }
            catch QueueError.notFound { /* Delete committed first. */ }
        }
        try await tasks.waitForAll()
    }
    #expect(try await other.artifacts(team: "workspace", principal: lab.principal).isEmpty)
    await #expect(throws: QueueError.notFound) { _ = try await lab.share(item, on: other) }
    await #expect(throws: QueueError.notFound) { _ = try await lab.share(lab.upload(id: item.id), on: other) }
    _ = try await lab.share(lab.upload(), on: other)
}
