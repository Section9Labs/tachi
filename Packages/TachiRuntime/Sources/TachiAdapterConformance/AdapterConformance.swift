import TachiRuntime

/// A failed check contains contract facts only. Provider payloads and identifiers stay in the fixture.
public enum ConformanceFailure: Error, Equatable, Sendable {
    case capabilitiesMismatch
    case expectedError(RuntimeError)
    case eventKinds(expected: [EventKind], actual: [EventKind])
    case submissionCount(expected: Int, actual: Int)
}

/// Run serially with a fresh adapter and an isolated, instrumented in-memory transport.
public struct AdapterConformance: Sendable {
    private let adapter: any Adapter
    private let registry = AdapterRegistry()
    private let submissions: @Sendable () async -> Int

    public init(adapter: any Adapter, submissions: @escaping @Sendable () async -> Int) {
        self.adapter = adapter
        self.submissions = submissions
    }

    /// Supply the expected identity and capabilities independently of the adapter under test.
    public func checkRegistration(probe: DispatchRequest, capabilities: Set<Capability>) async throws {
        let before = await submissions()
        try await expect(.unknownIdentity) { _ = try await registry.dispatch(probe) }
        try await registry.register(adapter)
        guard try await registry.capabilities(for: probe.identity) == capabilities else {
            throw ConformanceFailure.capabilitiesMismatch
        }
        try await expect(.duplicateIdentity) { try await registry.register(adapter) }
        let other = try AdapterIdentity(provider: probe.identity.provider,
                                        accountID: probe.identity.accountID + "-unregistered",
                                        assistantID: probe.identity.assistantID)
        func request(_ identity: AdapterIdentity, _ capability: Capability) throws -> DispatchRequest {
            try DispatchRequest(identity: identity, sessionID: probe.sessionID, requestID: probe.requestID,
                                capability: capability, payload: probe.payload)
        }
        try await expect(.unknownIdentity) { _ = try await registry.dispatch(request(other, probe.capability)) }
        let operations: [Capability] = [.message, .task, .attachment, .tools, .cancel, .recover]
        for operation in operations where !capabilities.contains(operation) {
            try await expect(.unsupportedCapability) {
                _ = try await registry.dispatch(request(probe.identity, operation))
            }
        }
        try await checkCount(since: before, expected: 0)
    }

    /// Runs one dispatch. The public registry checks event correlation and collapses identical duplicates.
    /// Inspect the returned events for connector-specific semantics. Pass submitted: false for a local refusal.
    public func checkResponse(to request: DispatchRequest, kinds: [EventKind],
                              submitted: Bool = true) async throws -> [AdapterEvent] {
        let before = await submissions()
        let events = try await registry.dispatch(request)
        let actual = events.map(\.kind)
        guard actual == kinds else { throw ConformanceFailure.eventKinds(expected: kinds, actual: actual) }
        try await checkCount(since: before, expected: submitted ? 1 : 0)
        return events
    }

    /// Configure the fixture to count a submission and then lose its response before calling this check.
    public func checkLostReply(to request: DispatchRequest) async throws {
        let before = await submissions()
        try await expect(.dispatchUncertain) { _ = try await registry.dispatch(request) }
        try await checkCount(since: before, expected: 1)
    }

    private func checkCount(since before: Int, expected: Int) async throws {
        let actual = await submissions() - before
        guard actual == expected else { throw ConformanceFailure.submissionCount(expected: expected, actual: actual) }
    }

    private func expect(_ error: RuntimeError, _ operation: () async throws -> Void) async throws {
        do { try await operation() } catch let actual as RuntimeError where actual == error { return }
        throw ConformanceFailure.expectedError(error)
    }
}
