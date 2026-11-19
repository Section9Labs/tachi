import Foundation

/// Trusted operator configuration, looked up by granting human and routine. Contains no bearer.
public struct WorkspaceRoutineGrant: Sendable {
    public let identity: AdapterIdentity
    public let generation: String
    public init(identity: AdapterIdentity, generation: String) {
        self.identity = identity
        self.generation = generation
    }
}

public typealias WorkspaceRoutineLookup = @Sendable (_ human: String, _ routine: String) -> WorkspaceRoutineGrant?

extension TeamQueue {
    /// The owner explicitly lets current sending members invoke this routine with room-visible text.
    public func bindWorkspaceRoutine(team: String, principal: QueuePrincipal, routine: String,
                                     lookup: WorkspaceRoutineLookup) throws -> JSONObject {
        try db.transaction {
            let generation = try authorize(principal, team, "teams:manage")
            try authorize(principal, team, "messages:send", generation: generation)
            guard let grant = lookup(principal.humanID, routine), grant.identity.provider == "grok-bot" else {
                throw QueueError.notFound
            }
            if let old = try db.query("SELECT * FROM rt_workspace_binding WHERE team=? AND enabled=1", [team]).first {
                do {
                    _ = try checkGrant(old, lookup: lookup)
                    guard old["routine"]?.utf8Bytes == routine.utf8Bytes, old["grantor"]?.utf8Bytes == principal.humanID.utf8Bytes
                    else { throw QueueError.conflict }
                    return try bindingSummary(old.required("binding"))
                } catch QueueError.denied {
                    // This explicit consent creates a fresh binding. Pending work retains its previous grant.
                    try disableBinding(old)
                }
            }
            let id = UUID().uuidString.lowercased(), member = "assistant:" + id
            // Grok supplies no conversation handle. This is a fresh workspace-local correlation only.
            try db.insertAssistant(team: team, alias: id, identity: grant.identity, sessionID: UUID().uuidString.lowercased())
            try db.insertRun(team: team, run: id, lead: member, turnLimit: Int(Int32.max))
            try db.query("""
                INSERT INTO rt_workspace_binding(team,member,binding,routine,credential_generation,grantor,client,membership,enabled)
                VALUES(?,?,?,?,?,?,?,?,1)
                """, [team, member, id, routine, grant.generation, principal.humanID, principal.clientID, generation])
            return bindingSummary(id)
        }
    }

    private func bindingSummary(_ id: String) -> JSONObject {
        ["assistant_id": .string(id), "provider": .string("grok-bot"), "capabilities": .array([.string("task")]),
         "native_session_observed": .bool(false)]
    }

    func checkGrant(_ row: Row, lookup: WorkspaceRoutineLookup) throws -> WorkspaceRoutineGrant {
        let owner = try QueuePrincipal(humanID: row.required("grantor"), clientID: row.required("client"))
        let team = try row.required("team"), member = try row.required("membership")
        guard row["enabled"] == "1", let grant = try lookup(owner.humanID, row.required("routine")),
              grant.generation.utf8Bytes == row["credential_generation"]?.utf8Bytes else { throw QueueError.denied }
        try authorize(owner, team, "teams:manage", generation: member)
        try authorize(owner, team, "messages:send", generation: member)
        return grant
    }

    public func workspaceAssistants(team: String, principal: QueuePrincipal, lookup: WorkspaceRoutineLookup) throws -> [JSONObject] {
        try db.transaction {
            try authorize(principal, team, "sessions:read")
            guard let row = try db.query("SELECT * FROM rt_workspace_binding WHERE team=? AND enabled=1", [team]).first else { return [] }
            do { _ = try checkGrant(row, lookup: lookup) } catch QueueError.denied { return [] }
            return try [bindingSummary(row.required("binding"))]
        }
    }

    private func disableBinding(_ binding: Row) throws {
        let team = try binding.required("team"), member = try binding.required("member")
        try db.query("UPDATE rt_workspace_binding SET enabled=0 WHERE team=? AND member=?", [team, member])
        // An outstanding or accepted POST keeps its recorded outcome.
        try db.query("""
            UPDATE rt_delivery SET state='denied',reason='binding_revoked' WHERE team=? AND target=?
            AND state IN ('queued','blocked')
            """, [team, member])
    }

    public func revokeWorkspaceAssistant(team: String, principal: QueuePrincipal, id: String) throws {
        try db.transaction {
            try authorize(principal, team, "teams:manage")
            guard let binding = try db.query("SELECT * FROM rt_workspace_binding WHERE team=? AND binding=?", [team,id]).first
            else { throw QueueError.notFound }
            try disableBinding(binding)
        }
    }

    public func assign(team: String, principal: QueuePrincipal, id: String, assistantID: String, text: String,
                       lookup: WorkspaceRoutineLookup) throws -> JSONObject {
        guard UUID(uuidString: id)?.uuidString.lowercased() == id, text.unicodeScalars.count <= 4000,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw QueueError.invalidInput }
        return try db.transaction {
            let generation = try authorize(principal, team, "messages:send")
            if let existing = try assignmentRows(team: team, id: id).first {
                guard existing["binding"] == assistantID, existing["human"]?.utf8Bytes == principal.humanID.utf8Bytes,
                      existing["membership"]?.utf8Bytes == generation.utf8Bytes,
                      try decodeJSON(JSONObject.self, existing.required("payload")) == ["text": .string(text)]
                else { throw QueueError.conflict }
                return try assignmentSummary(existing)
            }
            // Another queue operation may already own this ID. Its audience is outside the assignment route.
            guard try db.query("SELECT 1 FROM rt_message WHERE team=? AND message=?", [team,id]).isEmpty else {
                throw QueueError.notFound
            }
            guard let row = try db.query("SELECT * FROM rt_workspace_binding WHERE team=? AND binding=? AND enabled=1",
                                         [team, assistantID]).first else { throw QueueError.notFound }
            _ = try checkGrant(row, lookup: lookup)
            try insertPost(team: team, principal: principal, generation: generation, author: "human:" + principal.humanID,
                           run: assistantID, message: id, payload: ["text": .string(text)], directTo: nil,
                           mentions: [row.required("member")], replyTo: nil, capability: .task, scope: nil, parent: nil,
                           workspaceAssignment: true)
            guard let created = try assignmentRows(team: team, id: id).first else { throw QueueError.corruptStore }
            return try assignmentSummary(created)
        }
    }

    private func assignmentRows(team: String, id: String?) throws -> [Row] {
        try db.query("""
            SELECT b.binding,m.message,m.human,m.membership,m.payload,d.state FROM rt_message m
            JOIN rt_delivery d USING(team,message) JOIN rt_workspace_binding b ON b.team=m.team AND b.member=d.target
            WHERE m.team=? AND m.run=b.binding AND (? IS NULL OR m.message=?) ORDER BY m.seq
            """, [team,id,id])
    }

    private func assignmentSummary(_ row: Row) throws -> JSONObject {
        guard let text = try decodeJSON(JSONObject.self, row.required("payload"))["text"] else { throw QueueError.corruptStore }
        return try ["assignment_id": .string(row.required("message")), "assistant_id": .string(row.required("binding")),
                    "author_id": .string(row.required("human")), "text": text, "state": .string(row.required("state")),
                    "native_result_available": .bool(false), "result": .null]
    }

    public func workspaceAssignments(team: String, principal: QueuePrincipal, id: String?) throws -> [JSONObject] {
        try db.transaction {
            try authorize(principal, team, "sessions:read")
            let rows = try assignmentRows(team: team, id: id)
            if id != nil && rows.isEmpty { throw QueueError.notFound }
            return try rows.map(assignmentSummary)
        }
    }

}
