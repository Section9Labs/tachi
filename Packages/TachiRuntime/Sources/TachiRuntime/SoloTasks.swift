import Foundation

/// Operator-bound, Tachi-local correlation. The webhook supplies no native conversation ID.
public struct SoloLane: Sendable {
    public let teamID: String
    public let identity: AdapterIdentity

    public init(key: String) throws {
        try requireIDs(key)
        teamID = "solo/" + key
        identity = try AdapterIdentity(provider: "grok-bot", accountID: teamID, assistantID: "routine")
    }
}

extension TeamQueue {
    /// Provision and enqueue atomically, retaining the first client's authority on duplicate submissions.
    public func submitSolo(lane: SoloLane, principal: QueuePrincipal, taskID: String, payload: JSONObject) throws -> String {
        try db.transaction {
            let team = lane.teamID
            let generation = try authorize(principal, team, "messages:send")
            if let old = try db.query("SELECT human,payload FROM rt_message WHERE team=? AND message=?", [team, taskID]).first {
                guard try sameID(old.required("human"), principal.humanID),
                      try JSONValue.object(decodeJSON(JSONObject.self, old.required("payload"))) == .object(payload)
                else { throw QueueError.conflict }
            } else {
                if try db.query("SELECT 1 FROM rt_assistant WHERE team=? AND member='assistant:routine'", [team]).isEmpty {
                    try db.insertAssistant(team: team, alias: "routine", identity: lane.identity, sessionID: team)
                    try db.insertRun(team: team, run: "routine", lead: "assistant:routine", turnLimit: Int(Int32.max))
                }
                try insertPost(team: team, principal: principal, generation: generation, author: "human:" + principal.humanID,
                               run: "routine", message: taskID, payload: payload, directTo: "assistant:routine",
                               mentions: [], replyTo: nil, capability: .task, scope: nil, parent: nil)
            }
            return try soloState(team: team, human: principal.humanID, taskID: taskID)
        }
    }

    public func soloTask(lane: SoloLane, principal: QueuePrincipal, taskID: String) throws -> String {
        try authorize(principal, lane.teamID, "sessions:read")
        return try soloState(team: lane.teamID, human: principal.humanID, taskID: taskID)
    }

    private func soloState(team: String, human: String, taskID: String) throws -> String {
        guard let row = try db.query("""
            SELECT d.state FROM rt_message m JOIN rt_delivery d USING(team,message)
            WHERE m.team=? AND m.human=? AND m.message=? AND d.target='assistant:routine'
            """, [team, human, taskID]).first else { throw QueueError.notFound }
        switch try row.required("state") {
        case "active": return "accepted"
        case "failed": return "rejected"
        case let state where ["queued", "denied", "blocked", "uncertain"].contains(state): return state
        default: throw QueueError.corruptStore
        }
    }
}
