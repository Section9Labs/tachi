import Foundation
import Testing
import TachiRuntime
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import TachiGrok

private func enrollmentDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("tachi-grok-enroll-\(UUID().uuidString)", isDirectory: true)
}

private func mode(of url: URL) throws -> mode_t {
    var info = stat()
    let rc = url.path.withCString { lstat($0, &info) }
    #expect(rc == 0)
    return info.st_mode & 0o777
}

@Test func enrolledGrantLoadsForThatHumanOnly() async throws {
    let directory = enrollmentDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let secret = "test-secret"
    let enrolled = try provisionRoutineGrant(
        humanID: "human-a",
        issuedURL: "https://HOOKS.Example.Invalid:443/routine",
        secret: secret,
        directory: directory
    )
    #expect(enrolled.destination == "https://hooks.example.invalid/routine")
    #expect(enrolled.humanID == "human-a")
    #expect(!String(describing: enrolled).contains(secret))
    #expect(!String(reflecting: enrolled).contains(secret))
    #expect(!String(describing: enrolled).contains("/routine"))
    #expect(!String(reflecting: enrolled).contains("/routine"))
    let binding = try Data(contentsOf: directory.appendingPathComponent("enrollment.json"))
    #expect(!binding.contains(Data(secret.utf8)))
    #expect(try mode(of: directory) == 0o700)
    #expect(try mode(of: directory.appendingPathComponent("secret")) == 0o600)
    #expect(try mode(of: directory.appendingPathComponent("enrollment.json")) == 0o600)

    let grant = try loadRoutineGrant(humanID: "human-a", directory: directory)
    let issued = try bindWebhook("https://hooks.example.invalid/routine", secret: secret)
    #expect(grant == issued)
    let posts = Posts()
    let transport: WebhookTransport = { call, _ in
        posts.record(call)
        return HttpResult(status: 200)
    }
    let adapter = try GrokBotAdapter(identity: try identity(), grant: grant, transport: transport)
    let events = try await adapter.dispatch(try taskRequest(adapter.identity))
    #expect(events.count == 1)
    #expect(events[0].kind == .accepted)
    #expect(posts.count == 1)
    #expect(posts.last?.url == grant.destination())
    #expect(posts.last?.authorization == "Bearer \(secret)")
    #expect(!String(describing: adapter).contains(secret))
    #expect(!String(describing: adapter).contains("/routine"))

    #expect(throws: GrokConnectorError.notSent) {
        try loadRoutineGrant(humanID: "human-b", directory: directory)
    }
}

@Test func aSecondProvisionDoesNotReplaceTheSecret() throws {
    let directory = enrollmentDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try provisionRoutineGrant(
        humanID: "human-a",
        issuedURL: "https://hooks.example.invalid/routine",
        secret: "test-secret",
        directory: directory
    )
    let original = try Data(contentsOf: directory.appendingPathComponent("secret"))
    #expect(throws: GrokConnectorError.notSent) {
        try provisionRoutineGrant(
            humanID: "human-a",
            issuedURL: "https://hooks.example.invalid/routine",
            secret: "replacement-secret",
            directory: directory
        )
    }
    #expect(try Data(contentsOf: directory.appendingPathComponent("secret")) == original)
}

@Test func looseOrRetargetedFilesDoNotLoad() throws {
    let directory = enrollmentDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try provisionRoutineGrant(
        humanID: "human-a",
        issuedURL: "https://hooks.example.invalid/routine",
        secret: "test-secret",
        directory: directory
    )
    let secretURL = directory.appendingPathComponent("secret")
    #expect(secretURL.path.withCString { chmod($0, 0o640) } == 0)
    #expect(throws: GrokConnectorError.notSent) {
        try loadRoutineGrant(humanID: "human-a", directory: directory)
    }
    #expect(secretURL.path.withCString { chmod($0, 0o600) } == 0)

    let bindingURL = directory.appendingPathComponent("enrollment.json")
    let retargeted = try String(contentsOf: bindingURL, encoding: .utf8)
        .replacingOccurrences(of: "hooks.example.invalid", with: "other.example.invalid")
    try retargeted.write(to: bindingURL, atomically: false, encoding: .utf8)
    #expect(bindingURL.path.withCString { chmod($0, 0o600) } == 0)
    #expect(throws: GrokConnectorError.notSent) {
        try loadRoutineGrant(humanID: "human-a", directory: directory)
    }
}

@Test func aNonRegularSecretFailsPromptly() throws {
    let directory = enrollmentDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try provisionRoutineGrant(
        humanID: "human-a",
        issuedURL: "https://hooks.example.invalid/routine",
        secret: "test-secret",
        directory: directory
    )
    let secretURL = directory.appendingPathComponent("secret")
    try FileManager.default.removeItem(at: secretURL)
    #expect(secretURL.path.withCString { mkfifo($0, 0o600) } == 0)
    #expect(secretURL.path.withCString { chmod($0, 0o600) } == 0)
    let started = ContinuousClock.now
    #expect(throws: GrokConnectorError.notSent) {
        try loadRoutineGrant(humanID: "human-a", directory: directory)
    }
    #expect(ContinuousClock.now - started < .seconds(2))
}

@Test func symlinkSecretAndBilledDestinationAreRefused() throws {
    let directory = enrollmentDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try provisionRoutineGrant(
        humanID: "human-a",
        issuedURL: "https://hooks.example.invalid/routine",
        secret: "test-secret",
        directory: directory
    )
    let secretURL = directory.appendingPathComponent("secret")
    let parked = directory.appendingPathComponent("parked")
    try FileManager.default.moveItem(at: secretURL, to: parked)
    #expect(symlink(parked.path, secretURL.path) == 0)
    #expect(throws: GrokConnectorError.notSent) {
        try loadRoutineGrant(humanID: "human-a", directory: directory)
    }

    let absent = enrollmentDirectory()
    #expect(throws: GrokConnectorError.notSent) {
        try provisionRoutineGrant(
            humanID: "human-a",
            issuedURL: "https://api.x.ai/v1/responses",
            secret: "test-secret",
            directory: absent
        )
    }
    #expect(!FileManager.default.fileExists(atPath: absent.path))
}

private final class Posts: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0
    private(set) var last: WebhookCall?
    func record(_ call: WebhookCall) {
        lock.lock()
        count += 1
        last = call
        lock.unlock()
    }
}

private func identity() throws -> AdapterIdentity {
    try AdapterIdentity(provider: grokBotProviderID, accountID: "synthetic-account", assistantID: "synthetic-bot")
}

private func taskRequest(_ id: AdapterIdentity) throws -> DispatchRequest {
    try DispatchRequest(
        identity: id,
        sessionID: "synthetic-session",
        requestID: "synthetic-request",
        capability: .task,
        payload: ["task": .string("synthetic pong")]
    )
}
