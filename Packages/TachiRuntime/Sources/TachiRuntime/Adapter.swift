import Foundation

public enum RuntimeError: Error, Equatable, Sendable {
    case invalidIdentifier, invalidPayload, unsupportedVersion, duplicateIdentity
    case unknownIdentity, unsupportedCapability, identityChanged, dispatchUncertain
}

func requireIDs(_ ids: String...) throws {
    guard ids.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
        throw RuntimeError.invalidIdentifier
    }
}

// Provider IDs are opaque. Swift String equality otherwise folds distinct Unicode spellings.
func sameID(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }

public struct AdapterIdentity: Sendable, Hashable {
    public let provider: String
    public let accountID: String
    public let assistantID: String

    public init(provider: String, accountID: String, assistantID: String) throws {
        try requireIDs(provider, accountID, assistantID)
        self.provider = provider
        self.accountID = accountID
        self.assistantID = assistantID
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        sameID(lhs.provider, rhs.provider) && sameID(lhs.accountID, rhs.accountID)
            && sameID(lhs.assistantID, rhs.assistantID)
    }

    public func hash(into hasher: inout Hasher) {
        for id in [provider, accountID, assistantID] { hasher.combine(Data(id.utf8)) }
    }
}

public enum Capability: String, Codable, Sendable {
    case message, task, attachment, tools, cancel, recover
}

public enum EventKind: String, Codable, Sendable {
    case accepted, progress, completed, failed, cancelled
}

public struct DispatchRequest: Sendable {
    public let identity: AdapterIdentity
    public let sessionID, requestID: String
    public let capability: Capability
    public let payload: JSONObject

    public init(identity: AdapterIdentity, sessionID: String, requestID: String,
                capability: Capability, payload: JSONObject) throws {
        try requireIDs(sessionID, requestID)
        try JSONValue.object(payload).validate()
        self.identity = identity
        self.sessionID = sessionID
        self.requestID = requestID
        self.capability = capability
        self.payload = payload
    }
}

public struct AdapterEvent: Sendable, Equatable {
    public let identity: AdapterIdentity
    public let sessionID, requestID, eventID: String
    public let kind: EventKind
    public let payload: JSONObject

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identity == rhs.identity && sameID(lhs.sessionID, rhs.sessionID)
            && sameID(lhs.requestID, rhs.requestID) && sameID(lhs.eventID, rhs.eventID)
            && lhs.kind == rhs.kind && lhs.payload == rhs.payload
    }

    public init(identity: AdapterIdentity, sessionID: String, requestID: String,
                eventID: String, kind: EventKind, payload: JSONObject) throws {
        try requireIDs(sessionID, requestID, eventID)
        try JSONValue.object(payload).validate()
        self.identity = identity
        self.sessionID = sessionID
        self.requestID = requestID
        self.eventID = eventID
        self.kind = kind
        self.payload = payload
    }
}

public protocol Adapter: Sendable {
    var version: Int { get }
    var identity: AdapterIdentity { get }
    var capabilities: Set<Capability> { get }
    func dispatch(_ request: DispatchRequest) async throws -> [AdapterEvent]
}

public actor AdapterRegistry {
    private var entries: [AdapterIdentity: (any Adapter, Set<Capability>)] = [:]
    public init() {}

    public func register(_ adapter: any Adapter) throws {
        guard adapter.version == 1 else { throw RuntimeError.unsupportedVersion }
        let id = adapter.identity
        guard entries[id] == nil else { throw RuntimeError.duplicateIdentity }
        entries[id] = (adapter, adapter.capabilities)
    }

    public func capabilities(for identity: AdapterIdentity) throws -> Set<Capability> {
        guard let entry = entries[identity] else { throw RuntimeError.unknownIdentity }
        return entry.1
    }

    public func dispatch(_ request: DispatchRequest) async throws -> [AdapterEvent] {
        guard let (adapter, capabilities) = entries[request.identity] else { throw RuntimeError.unknownIdentity }
        guard capabilities.contains(request.capability) else { throw RuntimeError.unsupportedCapability }
        guard adapter.identity == request.identity else { throw RuntimeError.identityChanged }
        do {
            var ordered: [AdapterEvent] = []
            var seen: [Data: AdapterEvent] = [:]
            for event in try await adapter.dispatch(request) {
                guard event.identity == request.identity, sameID(event.sessionID, request.sessionID),
                      sameID(event.requestID, request.requestID) else { throw RuntimeError.dispatchUncertain }
                let key = Data(event.eventID.utf8)
                if let earlier = seen[key] {
                    guard event == earlier else { throw RuntimeError.dispatchUncertain }
                } else {
                    seen[key] = event
                    ordered.append(event)
                }
            }
            return ordered
        } catch {
            // Cancellation, invalid responses and transport errors can follow a native effect.
            throw RuntimeError.dispatchUncertain
        }
    }
}

public actor ReferenceAdapter: Adapter {
    public let identity: AdapterIdentity
    public let version = 1
    public let capabilities: Set<Capability> = [.message, .task]
    private let duplicateEvent, loseReply: Bool
    public private(set) var calls: [DispatchRequest] = []

    public init(identity: AdapterIdentity, duplicateEvent: Bool = false, loseReply: Bool = false) {
        self.identity = identity
        self.duplicateEvent = duplicateEvent
        self.loseReply = loseReply
    }

    public func dispatch(_ request: DispatchRequest) throws -> [AdapterEvent] {
        calls.append(request)
        if loseReply { throw RuntimeError.dispatchUncertain }
        let event = try AdapterEvent(identity: identity, sessionID: request.sessionID, requestID: request.requestID,
                                     eventID: "result", kind: .completed,
                                     payload: ["operation": .string(request.capability.rawValue)])
        return duplicateEvent ? [event, event] : [event]
    }
}
