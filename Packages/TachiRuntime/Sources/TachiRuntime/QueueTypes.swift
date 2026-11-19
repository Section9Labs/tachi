import Foundation

public struct QueuePrincipal: Sendable {
    public let humanID, clientID: String
    public init(humanID: String, clientID: String) {
        self.humanID = humanID
        self.clientID = clientID
    }
}

/// Implement with the live account store. Throw QueueError.denied for a policy denial.
/// Other errors propagate independently. Return the current membership generation.
public protocol QueueAuthority: Sendable {
    func authorize(_ principal: QueuePrincipal, team: String, scope: String, membershipID: String?) throws -> String
    func membershipID(team: String, humanID: String) throws -> String?
}

public struct HostScope: Sendable, Codable, Equatable {
    public let ownerID, hostID, grantID, folderID, action, relativePath: String
    enum CodingKeys: String, CodingKey {
        case ownerID = "owner_id", hostID = "host_id", grantID = "grant_id", folderID = "folder_id"
        case action, relativePath = "relative_path"
    }
    public init(ownerID: String, hostID: String, grantID: String, folderID: String, action: String, relativePath: String) throws {
        try requireIDs(ownerID, hostID, grantID, folderID, relativePath)
        guard ["read", "write"].contains(action) else { throw QueueError.invalidInput }
        self.ownerID = ownerID
        self.hostID = hostID
        self.grantID = grantID
        self.folderID = folderID
        self.action = action
        self.relativePath = relativePath
    }
}

public struct HostWorker: Sendable {
    public let hostID: String
    /// Capture a current authenticated session. The host executor also checks before each actual effect.
    public let authorize: @Sendable (HostScope) throws -> Void
    public init(hostID: String, authorize: @escaping @Sendable (HostScope) throws -> Void) {
        self.hostID = hostID
        self.authorize = authorize
    }
}

public enum RunState: String, Sendable { case running, paused, cancelled, completed }
public struct RunStatus: Sendable {
    public let team, run, lead: String
    public let state: RunState
    public let turns, turnLimit: Int
}

public struct DeliveryRecord: Sendable {
    public let requestID, target, state: String
    public let reason: String?
    public let identity: AdapterIdentity
    public let sessionID: String
    public let events: [AdapterEvent]
}

public struct MessageRecord: Sendable {
    public let messageID, author: String
    public let directTo, replyTo, parentRequest, parentEvent: String?
    public let mentions: [String]
    public let payload: JSONObject
    public let capability: Capability
    public let deliveries: [DeliveryRecord]
}
