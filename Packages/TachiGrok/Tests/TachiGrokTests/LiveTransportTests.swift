import Foundation
import Testing
import TachiRuntime
@testable import TachiGrok

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Real loopback HTTP. These tests are the proxy and stalled-body evidence on Darwin and Linux.
@Suite(.serialized)
struct LiveWebhookTransportSuite {
    private let hold: TimeInterval = 5
    private let fast = Duration.seconds(2)

    @Test func held200SettlesBeforeTheBody() async throws {
        let server = try startServer(mode: "hold", status: 200, hold: hold)
        defer { server.stop() }
        let started = ContinuousClock.now
        let result = try await post(server)
        #expect(started.duration(to: .now) < fast)
        #expect(result.accepted)
        #expect(!result.completed)
        #expect(result.status == 200)
        #expect(!String(reflecting: result).contains("/routine"))
        let hits = try await server.hits(atLeast: 1)
        #expect(hits.count == 1)
        #expect(hits[0].hasPrefix("POST /routine HTTP/1."))
        #expect(hits[0].contains("auth=yes"))
        #expect(!hits[0].contains("test-secret"))
    }

    @Test func held503IsARejection() async throws {
        let server = try startServer(mode: "hold", status: 503, hold: hold)
        defer { server.stop() }
        let id = try identity()
        let adapter = try GrokBotAdapter(
            identity: id,
            webhookURL: "http://127.0.0.1:\(server.port)/routine",
            webhookSecret: "test-secret",
            allowLoopback: true
        )
        let started = ContinuousClock.now
        let events = try await adapter.dispatch(try taskRequest(id))
        #expect(started.duration(to: .now) < fast)
        #expect(events[0].kind == .failed)
        #expect(events[0].payload["reason"] == .string("rejected"))
        #expect(events[0].payload["status"] == .integer(503))
        #expect(try await server.hits(atLeast: 1).count == 1)
    }

    @Test func informational100DoesNotHideTheFinalStatus() async throws {
        let server = try startServer(mode: "continue", status: 200, hold: hold)
        defer { server.stop() }
        let started = ContinuousClock.now
        let result = try await post(server)
        #expect(started.duration(to: .now) < fast)
        #expect(result.accepted)
        #expect(result.status == 200)
        #expect(try await server.hits(atLeast: 1).count == 1)
    }

    @Test func redirectIsNotFollowed() async throws {
        let landing = try startServer(mode: "silent", status: 200, hold: hold)
        defer { landing.stop() }
        let origin = try startServer(
            mode: "hold",
            status: 302,
            hold: hold,
            location: "http://127.0.0.1:\(landing.port)/landed"
        )
        defer { origin.stop() }
        let grant = try bindWebhook(
            "http://127.0.0.1:\(origin.port)/routine",
            secret: "test-secret",
            allowLoopback: true
        )
        let started = ContinuousClock.now
        await #expect(throws: GrokConnectorError.rejected(status: 302)) {
            try await triggerRoutine(grant, body: ["task": .string("synthetic pong")], timeout: hold)
        }
        #expect(started.duration(to: .now) < fast)
        #expect(try await origin.hits(atLeast: 1).count == 1)
        #expect(landing.currentHits().isEmpty)
        #expect(!String(reflecting: GrokConnectorError.rejected(status: 302)).contains("/routine"))
    }

    @Test func silentTimeoutIsUnobservedOnce() async throws {
        let server = try startServer(mode: "silent", status: 200, hold: hold)
        defer { server.stop() }
        let grant = try bindWebhook(
            "http://127.0.0.1:\(server.port)/routine",
            secret: "test-secret",
            allowLoopback: true
        )
        let started = ContinuousClock.now
        await #expect(throws: GrokConnectorError.submissionUnobserved) {
            try await triggerRoutine(grant, body: ["task": .string("synthetic pong")], timeout: 1)
        }
        #expect(started.duration(to: .now) < fast)
        #expect(try await server.hits(atLeast: 1).count == 1)
        try await Task.sleep(for: .milliseconds(400))
        #expect(server.currentHits().count == 1)
    }

    @Test func cancellationBeforeDispatchSendsNothing() async throws {
        let server = try startServer(mode: "hold", status: 200, hold: hold)
        defer { server.stop() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await post(server)
        }
        await #expect(throws: GrokConnectorError.notSent) { try await task.value }
        #expect(server.currentHits().isEmpty)
    }

    @Test func cancelBeforeStatusIsUnobservedOnce() async throws {
        let server = try startServer(mode: "silent", status: 200, hold: hold)
        defer { server.stop() }
        let grant = try bindWebhook(
            "http://127.0.0.1:\(server.port)/routine",
            secret: "test-secret",
            allowLoopback: true
        )
        let started = ContinuousClock.now
        let task = Task {
            try await triggerRoutine(grant, body: ["task": .string("synthetic pong")], timeout: hold)
        }
        _ = try await server.hits(atLeast: 1)
        task.cancel()
        await #expect(throws: GrokConnectorError.submissionUnobserved) {
            try await task.value
        }
        #expect(started.duration(to: .now) < fast)
        try await Task.sleep(for: .milliseconds(400))
        #expect(server.currentHits().count == 1)
    }

    @Test func statusWinsWhenCancelRacesTheHeader() async throws {
        let server = try startServer(mode: "hold", status: 200, hold: hold)
        defer { server.stop() }
        armLiveWebhookCancelAfterStatus(true)
        defer { armLiveWebhookCancelAfterStatus(false) }
        let started = ContinuousClock.now
        let result = try await post(server)
        #expect(started.duration(to: .now) < fast)
        #expect(result.accepted)
        #expect(!result.completed)
        #expect(try await server.hits(atLeast: 1).count == 1)
    }

    @Test func environmentProxyIsNotUsed() async throws {
        let origin = try startServer(mode: "hold", status: 200, hold: 0)
        defer { origin.stop() }
        let proxy = try startServer(mode: "proxy", status: 503, hold: hold)
        defer { proxy.stop() }
        let saved = pushProxyEnvironment("http://127.0.0.1:\(proxy.port)")
        defer { popProxyEnvironment(saved) }
        let started = ContinuousClock.now
        let result = try await post(origin, timeout: 2)
        #expect(started.duration(to: .now) < fast)
        #expect(result.accepted)
        let hits = try await origin.hits(atLeast: 1)
        #expect(hits.count == 1)
        #expect(hits[0].hasPrefix("POST /routine HTTP/1."))
        #expect(!hits[0].contains("http://"))
        #expect(proxy.currentHits().isEmpty)
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

private func post(_ server: LoopbackHTTP, timeout: TimeInterval = 5) async throws -> RoutineAcceptance {
    let grant = try bindWebhook(
        "http://127.0.0.1:\(server.port)/routine",
        secret: "test-secret",
        allowLoopback: true
    )
    return try await triggerRoutine(grant, body: ["task": .string("synthetic pong")], timeout: timeout)
}

private final class LoopbackHTTP: @unchecked Sendable {
    let process: Process
    let port: Int
    let hitFile: URL

    init(process: Process, port: Int, hitFile: URL) {
        self.process = process
        self.port = port
        self.hitFile = hitFile
    }

    func currentHits() -> [String] {
        guard let text = try? String(contentsOf: hitFile, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    func hits(atLeast count: Int) async throws -> [String] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            let lines = currentHits()
            if lines.count >= count { return lines }
            try await Task.sleep(for: .milliseconds(20))
        }
        let lines = currentHits()
        try #require(lines.count >= count, "expected \(count) requests, saw \(lines.count)")
        return lines
    }

    func stop() {
        let pid = process.processIdentifier
        if pid > 0 {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        try? FileManager.default.removeItem(at: hitFile)
    }
}

private func startServer(mode: String, status: Int, hold: TimeInterval, location: String? = nil) throws -> LoopbackHTTP {
    let script = try #require(
        Bundle.module.url(forResource: "local_http", withExtension: "py", subdirectory: "Fixtures")
    )
    let directory = FileManager.default.temporaryDirectory
    let hitFile = directory.appendingPathComponent("tachi-grok-\(UUID().uuidString).hits")
    let portFile = directory.appendingPathComponent("tachi-grok-\(UUID().uuidString).port")
    if !FileManager.default.createFile(atPath: hitFile.path, contents: Data()) {
        throw LiveFixtureError.port
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    var arguments = [
        "python3", script.path,
        "--hit-file", hitFile.path,
        "--port-file", portFile.path,
        "--mode", mode,
        "--status", String(status),
        "--hold", String(hold),
    ]
    if let location {
        arguments.append("--location")
        arguments.append(location)
    }
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    try process.run()
    do {
        let port = try waitForPort(portFile, process)
        try? FileManager.default.removeItem(at: portFile)
        return LoopbackHTTP(process: process, port: port, hitFile: hitFile)
    } catch {
        let pid = process.processIdentifier
        if pid > 0 {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        try? FileManager.default.removeItem(at: portFile)
        throw error
    }
}

private func waitForPort(_ portFile: URL, _ process: Process) throws -> Int {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if let text = try? String(contentsOf: portFile, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let port = Int(trimmed), (1...65535).contains(port) {
                return port
            }
        }
        if !process.isRunning { break }
        Thread.sleep(forTimeInterval: 0.02)
    }
    throw LiveFixtureError.port
}

private struct LiveFixtureError: Error {
    static let port = LiveFixtureError()
}

private let proxyEnvironmentKeys = [
    "http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY",
    "all_proxy", "ALL_PROXY", "no_proxy", "NO_PROXY",
]

private func pushProxyEnvironment(_ proxy: String) -> [String: String?] {
    var saved: [String: String?] = [:]
    for key in proxyEnvironmentKeys {
        if let value = getenv(key) {
            saved[key] = String(cString: value)
        } else {
            saved[key] = nil
        }
    }
    for key in ["http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "all_proxy", "ALL_PROXY"] {
        setenv(key, proxy, 1)
    }
    unsetenv("no_proxy")
    unsetenv("NO_PROXY")
    return saved
}

private func popProxyEnvironment(_ saved: [String: String?]) {
    for key in proxyEnvironmentKeys {
        if let value = saved[key] ?? nil {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }
}
