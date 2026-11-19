import Foundation
import RuntimeSQLite

public protocol ReferenceTeamAuthority: QueueAuthority {
    func authorizeClient(_ principal: QueuePrincipal, scope: String) throws
    func createTeam(_ principal: QueuePrincipal, team: String) throws
}

/// Instantiate only when the coordinator is configured to offer synthetic teams.
public actor ReferenceTeams {
    private let db: RuntimeDatabase
    private let queue: TeamQueue
    private let authority: any ReferenceTeamAuthority
    private static let run = "assignment"
    private static let aliases = ["lead", "peer"]

    public init(path: String, authority: any ReferenceTeamAuthority) throws {
        guard !path.isEmpty, path != ":memory:", !path.utf8.contains(0) else { throw QueueError.invalidInput }
        db = try RuntimeDatabase(path: path)
        queue = try TeamQueue(path: path, authority: authority)
        self.authority = authority
        try db.query("""
            CREATE TABLE IF NOT EXISTS rt_reference_team (
                team TEXT PRIMARY KEY, human TEXT NOT NULL, creation TEXT NOT NULL, initial_limit INTEGER NOT NULL,
                ready INTEGER NOT NULL DEFAULT 0, UNIQUE(human, creation)
            )
            """)
    }

    public func create(principal: QueuePrincipal, creationID: String, turnLimit: Int) throws -> ReferenceTeamSummary {
        try authority.authorizeClient(principal, scope: "teams:manage")
        guard Self.validID(creationID), (1...1000).contains(turnLimit) else { throw QueueError.invalidInput }
        // The account store uses its own connection. Reserve the stable ID before calling it.
        let reservation = try db.transaction {
            try db.query("""
                INSERT INTO rt_reference_team(team,human,creation,initial_limit) VALUES(?,?,?,?)
                ON CONFLICT(human,creation) DO NOTHING
                """, [Self.newID(), principal.humanID, creationID, String(turnLimit)])
            guard let row = try db.query("SELECT * FROM rt_reference_team WHERE human=? AND creation=?",
                                         [principal.humanID, creationID]).first else { throw QueueError.corruptStore }
            guard row["initial_limit"] == String(turnLimit) else { throw QueueError.conflict }
            return row
        }
        let team = try reservation.required("team")
        if reservation["ready"] == "0" {
            do { try authority.createTeam(principal, team: team) }
            catch QueueError.denied {
                // A competing or interrupted create may already have installed the owner membership.
                _ = try authority.authorize(principal, team: team, scope: "teams:manage", membershipID: nil)
            }
        }
        return try db.transaction {
            _ = try authority.authorize(principal, team: team, scope: "teams:manage", membershipID: nil)
            if try db.query("SELECT ready FROM rt_reference_team WHERE team=?", [team]).first?["ready"] == "0" {
                for alias in Self.aliases {
                    let identity = try Self.identity(team, alias)
                    try db.insertAssistant(team: team, alias: alias, identity: identity, sessionID: Self.newID())
                }
                try db.insertRun(team: team, run: Self.run, lead: "assistant:lead", turnLimit: turnLimit)
                try db.query("UPDATE rt_reference_team SET ready=1 WHERE team=?", [team])
            }
            return try snapshot(team)
        }
    }

    public func list(principal: QueuePrincipal) throws -> [ReferenceTeamSummary] {
        try authority.authorizeClient(principal, scope: "sessions:read")
        return try db.transaction(write: false) {
            try db.query("SELECT team FROM rt_reference_team WHERE human=? AND ready=1 ORDER BY rowid", [principal.humanID])
                .map { try summary(teamID: $0.required("team"), principal: principal) }
        }
    }

    public func summary(teamID: String, principal: QueuePrincipal) throws -> ReferenceTeamSummary {
        try require(teamID, principal, "sessions:read")
        return try snapshot(teamID)
    }

    @discardableResult
    public func post(teamID: String, principal: QueuePrincipal, messageID: String, text: String, audience: String,
                     mentions: [String] = [], replyTo: String? = nil) async throws -> String {
        try require(teamID, principal, "messages:send")
        guard Self.validID(messageID), replyTo.map(Self.validID) != false, text.unicodeScalars.count <= 4000,
              text.unicodeScalars.contains(where: { !referenceWhitespace($0) }),
              audience == "room" || Self.aliases.contains(audience),
              mentions.allSatisfy(Self.aliases.contains), Set(mentions).count == mentions.count,
              mentions.isEmpty || audience == "room" else { throw QueueError.invalidInput }
        do {
            try await queue.post(team: teamID, principal: principal, run: Self.run, message: messageID,
                                 payload: ["text": .string(text)], directTo: audience == "room" ? nil : "assistant:" + audience,
                                 mentions: mentions.map { "assistant:" + $0 }, replyTo: replyTo)
        } catch QueueError.notFound {
            // At this point the team exists. A missing reply target conflicts with its transcript.
            throw QueueError.conflict
        }
        return messageID
    }

    public func messages(teamID: String, principal: QueuePrincipal) async throws -> [ReferenceMessage] {
        try require(teamID, principal, "sessions:read")
        return try await queue.history(team: teamID, principal: principal, run: Self.run)
            .compactMap { ReferenceMessage($0, teamID: teamID, principal: principal) }
    }

    public func intervene(teamID: String, principal: QueuePrincipal, state: RunState,
                          turnLimit: Int? = nil) async throws -> ReferenceTeamSummary {
        try require(teamID, principal, "teams:manage")
        if let turnLimit, !(1...1000).contains(turnLimit) { throw QueueError.invalidInput }
        try await queue.intervene(team: teamID, principal: principal, run: Self.run, state: state, turnLimit: turnLimit)
        return try snapshot(teamID)
    }

    /// Attempt one eligible cloud delivery per ready reference team.
    public func workOnce() async throws -> Int {
        let pending = try db.query("""
            SELECT DISTINCT d.team FROM rt_delivery d JOIN rt_reference_team t USING(team)
            WHERE t.ready=1 AND d.host IS NULL AND d.state='queued' ORDER BY d.team
            """)
        var claims = 0
        for row in pending {
            try Task.checkCancellation()
            let team = try row.required("team")
            let registry = AdapterRegistry()
            for alias in Self.aliases {
                try await registry.register(WordCounter(identity: Self.identity(team, alias)))
            }
            if try await queue.dispatchOne(registry: registry, teamID: team, host: nil, referenceOnly: true) != nil {
                claims += 1
            }
        }
        return claims
    }

    /// Caller owns the task and cancels it on shutdown. Polling also observes work posted by other processes.
    public func runWorker() async throws {
        while true {
            try Task.checkCancellation()
            do {
                if try await workOnce() > 0 { continue }
            } catch QueueError.storage(let code) where code == SQLITE_BUSY || code == SQLITE_LOCKED {
                // Another SQLite connection currently holds a lock.
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private func require(_ team: String, _ principal: QueuePrincipal, _ scope: String) throws {
        guard try !db.query("SELECT 1 FROM rt_reference_team WHERE team=? AND human=? AND ready=1",
                            [team, principal.humanID]).isEmpty else { throw QueueError.notFound }
        _ = try authority.authorize(principal, team: team, scope: scope, membershipID: nil)
    }

    private func snapshot(_ team: String) throws -> ReferenceTeamSummary {
        guard let row = try db.query("SELECT state,turn_limit,turns FROM rt_run WHERE team=? AND run=?", [team, Self.run]).first,
              let state = try RunState(rawValue: row.required("state")),
              let limit = try Int(row.required("turn_limit")), let used = try Int(row.required("turns"))
        else { throw QueueError.corruptStore }
        return ReferenceTeamSummary(teamID: team, runState: state.rawValue, turnLimit: limit, turnsUsed: used)
    }

    private static func identity(_ team: String, _ alias: String) throws -> AdapterIdentity {
        try AdapterIdentity(provider: "tachi-reference", accountID: team, assistantID: alias)
    }

    private static func validID(_ value: String) -> Bool {
        (1...80).contains(value.utf8.count) && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func newID() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
}

private func referenceWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.isWhitespace || (0x1C...0x1F).contains(scalar.value)
}

private struct WordCounter: Adapter {
    let identity: AdapterIdentity
    let version = 1
    let capabilities: Set<Capability> = [.message]

    func dispatch(_ request: DispatchRequest) throws -> [AdapterEvent] {
        guard case let .string(text) = request.payload["text"] else { throw QueueError.invalidInput }
        let words = text.unicodeScalars.split(whereSeparator: referenceWhitespace).count
        return [try AdapterEvent(identity: identity, sessionID: request.sessionID, requestID: request.requestID,
                                 eventID: "result", kind: .completed, payload: ["words": .integer(Int64(words))])]
    }
}
