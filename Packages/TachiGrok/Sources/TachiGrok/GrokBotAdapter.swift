import Foundation
import TachiRuntime

/// v1 adapter. Task is advertised only when an operator webhook URL and secret are both set.
///
/// A known pre-send refusal is a returned failed event. A throw means the POST may already
/// have left this process. The registry turns that throw into dispatchUncertain and must not replay.
public struct GrokBotAdapter: Adapter, CustomStringConvertible, CustomDebugStringConvertible {
    public let version = 1
    public let identity: AdapterIdentity
    public let capabilities: Set<Capability>
    private let webhookURL: String?
    private let webhookSecret: String?
    private let transport: WebhookTransport?
    private let allowLoopback: Bool

    public init(
        identity: AdapterIdentity,
        webhookURL: String? = nil,
        webhookSecret: String? = nil,
        transport: WebhookTransport? = nil,
        allowLoopback: Bool = false
    ) throws {
        guard identity.provider.utf8.elementsEqual(grokBotProviderID.utf8) else {
            throw GrokConnectorError.providerIdentity
        }
        self.identity = identity
        self.webhookURL = webhookURL
        self.webhookSecret = webhookSecret
        self.transport = transport
        self.allowLoopback = allowLoopback
        let configured = !(webhookURL ?? "").isEmpty && !(webhookSecret ?? "").isEmpty
        self.capabilities = configured ? [.task] : []
    }

    /// Build from a grant `loadRoutineGrant` already bound to this human and destination.
    public init(
        identity: AdapterIdentity,
        grant: WebhookGrant,
        transport: WebhookTransport? = nil,
        allowLoopback: Bool = false
    ) throws {
        let bound = try bindWebhook(grant.destination(), secret: grant.secret, allowLoopback: allowLoopback)
        guard bound == grant else { throw GrokConnectorError.notSent }
        try self.init(
            identity: identity,
            webhookURL: bound.destination(),
            webhookSecret: bound.secret,
            transport: transport,
            allowLoopback: allowLoopback
        )
    }

    public func dispatch(_ request: DispatchRequest) async throws -> [AdapterEvent] {
        if request.capability != .task {
            return [try failed(request, ["reason": .string("unsupported")])]
        }
        guard let webhookURL, !webhookURL.isEmpty, let webhookSecret, !webhookSecret.isEmpty else {
            return [try failed(request, ["reason": .string("webhook_unconfigured")])]
        }
        do {
            let grant = try bindWebhook(webhookURL, secret: webhookSecret, allowLoopback: allowLoopback)
            let acceptance = try await triggerRoutine(
                grant, body: request.payload, transport: transport
            )
            if !acceptance.accepted || acceptance.completed {
                throw RuntimeError.dispatchUncertain
            }
            return [try event(request, .accepted, [
                "routine_accepted": .bool(true),
                "native_reply": .bool(false),
                "native_session_observed": .bool(false),
            ])]
        } catch let error as GrokConnectorError {
            switch error {
            case .notSent:
                return [try failed(request, ["reason": .string("not_sent")])]
            case .rejected(let status):
                return [try failed(request, [
                    "reason": .string("rejected"),
                    "status": .integer(Int64(status)),
                ])]
            case .submissionUnobserved:
                throw RuntimeError.dispatchUncertain
            case .providerIdentity:
                throw RuntimeError.dispatchUncertain
            }
        }
    }

    public var description: String {
        "GrokBotAdapter(provider: \(identity.provider), configured: \(capabilities.contains(.task)))"
    }

    public var debugDescription: String { description }

    private func failed(_ request: DispatchRequest, _ payload: JSONObject) throws -> AdapterEvent {
        try event(request, .failed, payload)
    }

    private func event(_ request: DispatchRequest, _ kind: EventKind, _ payload: JSONObject) throws -> AdapterEvent {
        try AdapterEvent(
            identity: identity,
            sessionID: request.sessionID,
            requestID: request.requestID,
            eventID: "\(kind.rawValue)-1",
            kind: kind,
            payload: payload
        )
    }
}
