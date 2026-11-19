import Foundation

public actor TeamQueue {
    let db: RuntimeDatabase
    let authority: any QueueAuthority

    public init(path: String, authority: any QueueAuthority) throws {
        self.db = try RuntimeDatabase(path: path)
        self.authority = authority
    }

    @discardableResult func authorize(_ principal: QueuePrincipal, _ team: String, _ scope: String,
                                      generation: String? = nil) throws -> String {
        try authority.authorize(principal, team: team, scope: scope, membershipID: generation)
    }

    /// Only the account store assigns human membership. An adapter supplies an authorized native session.
    public func addAssistant(team: String, principal: QueuePrincipal, alias: String,
                             identity: AdapterIdentity, sessionID: String) throws {
        try requireIDs(team, alias, sessionID)
        try db.transaction {
            try authorize(principal, team, "teams:manage")
            try db.query("INSERT INTO rt_assistant(team,member,provider,account,assistant,session) VALUES(?,?,?,?,?,?)",
                         [team, "assistant:" + alias, identity.provider, identity.accountID, identity.assistantID, sessionID])
        }
    }

    private func recipient(_ address: String, team: String) throws -> String? {
        if address.hasPrefix("human:") {
            let id = String(address.dropFirst(6))
            try requireIDs(id)
            guard let generation = try authority.membershipID(team: team, humanID: id) else { throw QueueError.denied }
            return generation
        }
        guard address.hasPrefix("assistant:"), try !db.query(
            "SELECT 1 FROM rt_assistant WHERE team=? AND member=?", [team, address]).isEmpty else {
            throw QueueError.denied
        }
        return nil
    }

    public func createRun(team: String, principal: QueuePrincipal, run: String, lead: String, turnLimit: Int) throws {
        try requireIDs(run)
        guard (1...Int(Int32.max)).contains(turnLimit), lead.hasPrefix("assistant:") else { throw QueueError.invalidInput }
        try db.transaction {
            try authorize(principal, team, "teams:manage")
            _ = try recipient(lead, team: team)
            try db.query("INSERT INTO rt_run(team,run,lead,turn_limit) VALUES(?,?,?,?)", [team, run, lead, String(turnLimit)])
        }
    }

    func runInfo(_ team: String, _ run: String) throws -> RunStatus {
        guard let row = try db.query("SELECT * FROM rt_run WHERE team=? AND run=?", [team, run]).first else {
            throw QueueError.notFound
        }
        guard let state = try RunState(rawValue: row.required("state")), let turns = try Int(row.required("turns")),
              let limit = try Int(row.required("turn_limit")) else { throw QueueError.corruptStore }
        return try RunStatus(team: team, run: run, lead: row.required("lead"), state: state, turns: turns, turnLimit: limit)
    }

    public func runStatus(team: String, principal: QueuePrincipal, run: String) throws -> RunStatus {
        try authorize(principal, team, "sessions:read")
        return try runInfo(team, run)
    }

    public func intervene(team: String, principal: QueuePrincipal, run: String,
                          state: RunState, turnLimit: Int? = nil) throws {
        if let turnLimit, !(1...Int(Int32.max)).contains(turnLimit) { throw QueueError.invalidInput }
        try db.transaction {
            try authorize(principal, team, "teams:manage")
            guard try !runInfo(team, run).state.terminal else { throw QueueError.conflict }
            try db.query("UPDATE rt_run SET state=?,turn_limit=COALESCE(?,turn_limit) WHERE team=? AND run=?",
                         [state.rawValue, turnLimit.map(String.init), team, run])
            if state.terminal {
                try db.query("""
                    UPDATE rt_delivery SET state='cancelled' WHERE team=? AND state IN ('queued','blocked')
                    AND message IN (SELECT message FROM rt_message WHERE team=? AND run=?)
                    """, [team, team, run])
            }
        }
    }

    public func post(team: String, principal: QueuePrincipal, run: String, message: String, payload: JSONObject,
                     directTo: String? = nil, mentions: [String] = [], replyTo: String? = nil,
                     capability: Capability = .message, scope: HostScope? = nil) throws {
        try db.transaction {
            let generation = try authorize(principal, team, "messages:send")
            if let scope, !sameID(scope.ownerID, principal.humanID) { throw QueueError.denied }
            try insertPost(team: team, principal: principal, generation: generation, author: "human:" + principal.humanID,
                           run: run, message: message, payload: payload, directTo: directTo, mentions: mentions,
                           replyTo: replyTo, capability: capability, scope: scope, parent: nil)
        }
    }

    public func postReply(parent: AdapterEvent, message: String, payload: JSONObject, directTo: String? = nil,
                          mentions: [String] = [], capability: Capability = .message) throws {
        try db.transaction {
            guard parent.kind == .progress || parent.kind == .completed,
                  let row = try db.query("""
                    SELECT d.target,m.*,e.payload AS native_payload,a.provider,a.account,a.assistant,a.session
                    FROM rt_delivery d JOIN rt_message m USING(team,message)
                    JOIN rt_assistant a ON a.team=d.team AND a.member=d.target
                    JOIN rt_event e ON e.request=d.request WHERE d.request=? AND e.event=? AND e.kind=?
                    """, [parent.requestID, parent.eventID, parent.kind.rawValue]).first,
                  try row.nativeIdentity() == parent.identity, try sameID(row.required("session"), parent.sessionID),
                  try decodeJSON(JSONObject.self, row.required("native_payload")) == parent.payload else {
                throw QueueError.denied
            }
            let team = try row.required("team"), generation = try row.required("membership")
            let origin = try QueuePrincipal(humanID: row.required("human"), clientID: row.required("client"))
            try authorize(origin, team, "messages:send", generation: generation)
            try insertPost(team: team, principal: origin, generation: generation, author: row.required("target"),
                           run: row.required("run"), message: message, payload: payload, directTo: directTo,
                           mentions: mentions, replyTo: row.required("message"), capability: capability, scope: nil, parent: parent)
        }
    }

    private func insertPost(team: String, principal: QueuePrincipal, generation: String, author: String,
                            run: String, message: String, payload: JSONObject, directTo: String?, mentions: [String],
                            replyTo: String?, capability: Capability, scope: HostScope?, parent: AdapterEvent?) throws {
        try requireIDs(team, run, message)
        if let replyTo { try requireIDs(replyTo) }
        guard payload["_tachi_host_scope"] == nil, directTo == nil || mentions.isEmpty,
              Set(mentions.map { Data($0.utf8) }).count == mentions.count else { throw QueueError.invalidInput }
        if scope != nil && directTo?.hasPrefix("assistant:") != true { throw QueueError.denied }
        let addresses = directTo.map { [$0] } ?? mentions
        var recipientGeneration: String?
        for address in addresses {
            let membership = try recipient(address, team: team)
            if directTo != nil { recipientGeneration = membership }
        }
        let sorted = mentions.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let meta: [(String, String?)] = [
            ("team", team), ("message", message), ("run", run), ("author", author), ("direct_to", directTo),
            ("reply_to", replyTo), ("capability", capability.rawValue), ("human", principal.humanID),
            ("client", principal.clientID), ("membership", generation), ("recipient_membership", recipientGeneration),
            ("parent_request", parent?.requestID), ("parent_event", parent?.eventID)
        ]
        if let old = try db.query("SELECT * FROM rt_message WHERE team=? AND message=?", [team, message]).first {
            let previousMentions = try decodeJSON([String].self, old.required("mentions"))
            guard meta.allSatisfy({ old[$0.0]?.utf8Bytes == $0.1?.utf8Bytes }),
                  previousMentions.map(\.utf8Bytes) == sorted.map(\.utf8Bytes),
                  try decodeJSON(JSONObject.self, old.required("payload")) == payload,
                  try old["scope"].map({ try decodeJSON(JSONObject.self, $0) }) == scope?.object else {
                throw QueueError.conflict
            }
            return
        }
        guard try !runInfo(team, run).state.terminal else { throw QueueError.conflict }
        if let replyTo {
            guard let target = try db.query("SELECT * FROM rt_message WHERE team=? AND message=? AND run=?",
                                            [team, replyTo, run]).first else { throw QueueError.notFound }
            if let oldTo = target["direct_to"] {
                let oldAuthor = try target.required("author")
                guard let directTo, Set([directTo.utf8Bytes, author.utf8Bytes]) == Set([oldTo.utf8Bytes, oldAuthor.utf8Bytes])
                else { throw QueueError.denied }
                for (address, membership) in [(oldTo, target["recipient_membership"]), (oldAuthor, target["membership"])]
                where address.hasPrefix("human:") {
                    guard try recipient(address, team: team)?.utf8Bytes == membership?.utf8Bytes else { throw QueueError.denied }
                }
            }
        }
        let columns = meta.map(\.0) + ["mentions", "payload", "scope"]
        let values = try meta.map(\.1) + [encodeJSON(sorted), encodeJSON(payload), scope.map(encodeJSON)]
        let slots = Array(repeating: "?", count: columns.count).joined(separator: ",")
        try db.query("INSERT INTO rt_message(\(columns.joined(separator: ","))) VALUES(\(slots))", values)
        for address in addresses where address.hasPrefix("assistant:") {
            let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            try db.query("INSERT INTO rt_delivery(team,message,target,request,host) VALUES(?,?,?,?,?)",
                         [team, message, address, id, scope?.hostID])
        }
    }

    public func history(team: String, principal: QueuePrincipal, run: String) throws -> [MessageRecord] {
        let generation = try authorize(principal, team, "sessions:read"), author = "human:" + principal.humanID
        return try db.transaction(write: false) { try readHistory(team: team, run: run, author: author, generation: generation) }
    }

    private func readHistory(team: String, run: String, author: String, generation: String) throws -> [MessageRecord] {
        let rows = try db.query("""
            SELECT * FROM rt_message WHERE team=? AND run=? AND (direct_to IS NULL OR
            (direct_to=? AND recipient_membership=?) OR (author=? AND membership=?)) ORDER BY seq
            """, [team, run, author, generation, author, generation])
        return try rows.map { msg in
            let id = try msg.required("message")
            let deliveries = try db.query("""
                SELECT d.*,a.provider,a.account,a.assistant,a.session FROM rt_delivery d JOIN rt_assistant a
                ON a.team=d.team AND a.member=d.target WHERE d.team=? AND d.message=? ORDER BY d.seq
                """, [team, id]).map { delivery in
                    let identity = try delivery.nativeIdentity(), session = try delivery.required("session")
                    let request = try delivery.required("request")
                    let events = try db.query("SELECT * FROM rt_event WHERE request=? ORDER BY seq", [request]).map { row in
                        guard let kind = try EventKind(rawValue: row.required("kind")) else { throw QueueError.corruptStore }
                        return try AdapterEvent(identity: identity, sessionID: session, requestID: request,
                                                eventID: row.required("event"), kind: kind,
                                                payload: decodeJSON(JSONObject.self, row.required("payload")))
                    }
                    return try DeliveryRecord(requestID: request, target: delivery.required("target"),
                                              state: delivery.required("state"), reason: delivery["reason"],
                                              identity: identity, sessionID: session, events: events)
                }
            guard let cap = try Capability(rawValue: msg.required("capability")) else { throw QueueError.corruptStore }
            return try MessageRecord(messageID: id, author: msg.required("author"), directTo: msg["direct_to"],
                                     replyTo: msg["reply_to"], parentRequest: msg["parent_request"], parentEvent: msg["parent_event"],
                                     mentions: decodeJSON([String].self, msg.required("mentions")),
                                     payload: decodeJSON(JSONObject.self, msg.required("payload")), capability: cap, deliveries: deliveries)
        }
    }
}

extension RunState { var terminal: Bool { self == .cancelled || self == .completed } }
extension String { var utf8Bytes: Data { Data(utf8) } }
extension Dictionary where Key == String, Value == String {
    func nativeIdentity() throws -> AdapterIdentity {
        try AdapterIdentity(provider: required("provider"), accountID: required("account"), assistantID: required("assistant"))
    }
}
extension HostScope {
    var object: JSONObject {
        ["owner_id": .string(ownerID), "host_id": .string(hostID), "grant_id": .string(grantID),
         "folder_id": .string(folderID), "action": .string(action), "relative_path": .string(relativePath)]
    }
}
