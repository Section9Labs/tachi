import Foundation
import Testing
import TachiAccounts
import TachiGrok
import TachiRuntime
@testable import TachiCoordinator

private struct SoloLab {
    let folder, file: URL
    let database: String
    let accounts: AccountStore

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        file = folder.appendingPathComponent("routines.json")
        database = folder.appendingPathComponent("state.sqlite").path
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        accounts = try AccountStore(path: database)
    }

    func configure(secret: String) throws {
        let entry = ["human_id": "fixture-owner", "routine_id": "sample",
                     "webhook_url": "http://127.0.0.1:1/fixture", "webhook_secret": secret]
        let data = try JSONEncoder().encode(["routines": [entry]])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func client() throws -> QueuePrincipal {
        let invitation = try accounts.issueClientInvitation(humanID: "fixture-owner", scopes: ["sessions:read", "messages:send"])
        let principal = try accounts.authenticate(token: accounts.redeemClient(invitation: invitation).token)
        return QueuePrincipal(humanID: principal.humanID, clientID: principal.clientID)
    }

    func service() async throws -> SoloRoutines {
        try await SoloRoutines(path: database, accounts: accounts, config: file.path, fixture: true)
    }
}

@Test(arguments: [false, true])
func reopenedSoloWorkerRechecksOriginAndCredential(rotateCredential: Bool) async throws {
    let lab = try SoloLab()
    defer { try? FileManager.default.removeItem(at: lab.folder) }
    try lab.configure(secret: "fixture-first")
    let origin = try lab.client(), sibling = try lab.client()
    let id = UUID().uuidString.lowercased(), payload: JSONObject = ["text": .string("Count the rows.")]
    let first = try await lab.service()
    let queued = try await first.task(origin, routineID: "sample", taskID: id, payload: payload)
    #expect(queued["state"] == .string("queued"))
    if rotateCredential {
        try lab.configure(secret: "fixture-replacement")
    } else {
        try lab.accounts.revokeClient(humanID: origin.humanID, clientID: origin.clientID)
    }
    let reopened = try await lab.service()
    // An identical submission must retain the original device and captured generation.
    let duplicate = try await reopened.task(sibling, routineID: "sample", taskID: id, payload: payload)
    #expect(duplicate == queued)
    let worker = Task { try await reopened.runWorker() }
    defer { worker.cancel() }
    for _ in 0..<100 {
        let result = try await reopened.task(sibling, routineID: "sample", taskID: id, payload: nil)
        if result["state"] == .string("denied") {
            #expect(result["result"] == .null)
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("The reopened worker did not deny the stale grant.")
}

@Test func operatorConfigurationRequiresAPrivateRegularFile() async throws {
    let lab = try SoloLab()
    defer { try? FileManager.default.removeItem(at: lab.folder) }
    try lab.configure(secret: "fixture")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lab.file.path)
    await #expect(throws: SoloConfigurationError.self) { _ = try await lab.service() }
    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: lab.file.path)
    let link = lab.folder.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: lab.file)
    await #expect(throws: SoloConfigurationError.self) {
        _ = try await SoloRoutines(path: lab.database, accounts: lab.accounts, config: link.path, fixture: true)
    }
}

@Test func enrollmentDirectoryLoadsWithoutRewritingTheSecret() async throws {
    let lab = try SoloLab()
    defer { try? FileManager.default.removeItem(at: lab.folder) }
    let directory = lab.folder.appendingPathComponent("enroll", isDirectory: true)
    let secret = "directory-secret"
    _ = try provisionRoutineGrant(humanID: "fixture-owner", issuedURL: "http://127.0.0.1:9/fixture",
                                  secret: secret, directory: directory, allowLoopback: true)
    let stored = try Data(contentsOf: directory.appendingPathComponent("secret"))
    let service = try await SoloRoutines(path: lab.database, accounts: lab.accounts, directory: directory.path,
                                         humanID: "fixture-owner", routineID: "sample", fixture: true)
    let catalogue = service.list(try lab.client())
    let summary = try #require(catalogue.first)
    #expect(catalogue.count == 1 && summary.provider == "grok-bot" && summary.routine_id == "sample")
    #expect(summary.origin.scheme == "http" && summary.origin.host == "127.0.0.1" && summary.origin.port == 9)
    #expect(!FileManager.default.fileExists(atPath: lab.file.path))
    #expect(try Data(contentsOf: directory.appendingPathComponent("secret")) == stored)
    await #expect(throws: SoloConfigurationError.self) {
        _ = try await SoloRoutines(path: lab.database, accounts: lab.accounts, directory: directory.path,
                                   humanID: "other-human", routineID: "sample", fixture: true)
    }
}

@Test func soloCatalogueUsesEffectiveHTTPSPortWithoutSending() async throws {
    let lab = try SoloLab()
    defer { try? FileManager.default.removeItem(at: lab.folder) }
    let entry = ["human_id": "fixture-owner", "routine_id": "sample",
                 "webhook_url": "https://example.invalid/private-route", "webhook_secret": "private-fixture"]
    try JSONEncoder().encode(["routines": [entry]]).write(to: lab.file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lab.file.path)
    let service = try await SoloRoutines(path: lab.database, accounts: lab.accounts, config: lab.file.path, fixture: false)
    let encoded = try JSONEncoder().encode(service.list(try lab.client()))
    let summaries = try JSONDecoder().decode([JSONObject].self, from: encoded)
    #expect(summaries == [["routine_id": .string("sample"), "provider": .string("grok-bot"),
                           "origin": .object(["scheme": .string("https"), "host": .string("example.invalid"),
                                              "port": .integer(443)])]])
}

@Test func enrollmentDirectoryRejectsARelativePath() async throws {
    let lab = try SoloLab()
    defer { try? FileManager.default.removeItem(at: lab.folder) }
    let directory = lab.folder.appendingPathComponent("enroll", isDirectory: true)
    _ = try provisionRoutineGrant(humanID: "fixture-owner", issuedURL: "http://127.0.0.1:9/fixture",
                                  secret: "directory-secret", directory: directory, allowLoopback: true)
    let loaded = try await SoloRoutines(path: lab.database, accounts: lab.accounts, directory: directory.path,
                                        humanID: "fixture-owner", routineID: "sample", fixture: true)
    #expect(loaded.list(try lab.client()).map(\.routine_id) == ["sample"])

    let parent = directory.deletingLastPathComponent()
    let name = directory.lastPathComponent
    let relative = [name, "./" + name, "../" + parent.lastPathComponent + "/" + name]
    #expect(foundationResolves(relative, to: directory))
    for input in relative {
        await #expect(throws: SoloConfigurationError.self) {
            _ = try await SoloRoutines(path: lab.database, accounts: lab.accounts, directory: input,
                                       humanID: "fixture-owner", routineID: "sample", fixture: true)
        }
    }
    let dotted = parent.deletingLastPathComponent().path + "/../" + parent.lastPathComponent + "/" + name
    #expect(dotted.contains(".."))
    await #expect(throws: SoloConfigurationError.self) {
        _ = try await SoloRoutines(path: lab.database, accounts: lab.accounts, directory: dotted,
                                   humanID: "fixture-owner", routineID: "sample", fixture: true)
    }
}

private let enrollmentPathLock = NSLock()

private func foundationResolves(_ inputs: [String], to directory: URL) -> Bool {
    enrollmentPathLock.lock()
    defer { enrollmentPathLock.unlock() }
    let saved = FileManager.default.currentDirectoryPath
    defer { _ = FileManager.default.changeCurrentDirectoryPath(saved) }
    guard FileManager.default.changeCurrentDirectoryPath(directory.deletingLastPathComponent().path) else { return false }
    return inputs.allSatisfy {
        URL(fileURLWithPath: $0).standardizedFileURL.path == directory.standardizedFileURL.path
    }
}
