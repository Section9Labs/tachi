import Foundation

/// The SQLite WHERE clause and bindings shared by every human workspace read.
struct WorkspaceAudience {
    static let predicate = """
        team=? AND (recipient IS NULL OR (author=? AND author_membership=?) OR (recipient=? AND recipient_membership=?))
        """
    let bindings: [String?]

    init(team: String, human: String, generation: String) {
        bindings = [team, human, generation, human, generation]
    }
}

/// A human transcript has no assistant binding, run, or adapter delivery.
public actor WorkspaceHistory {
    let db: RuntimeDatabase
    let authority: any QueueAuthority

    public init(path: String, authority: any QueueAuthority) throws {
        self.authority = authority
        db = try RuntimeDatabase(path: path)
        try db.query("""
            CREATE TABLE IF NOT EXISTS rt_workspace_message (
                seq INTEGER PRIMARY KEY, team TEXT NOT NULL, message TEXT NOT NULL,
                author TEXT NOT NULL, author_membership TEXT NOT NULL, body TEXT NOT NULL,
                recipient TEXT, recipient_membership TEXT, UNIQUE(team,message),
                CHECK ((recipient IS NULL) = (recipient_membership IS NULL))
            )
            """)
        try db.query(Self.artifactSchema)
    }

    public func post(team: String, principal: QueuePrincipal, id: String, text: String, recipient: String?) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.unicodeScalars.count <= 4000 else {
            throw QueueError.invalidInput
        }
        // Accounts writes share this database. Neither participant can change generations during insertion.
        try db.transaction {
            let sender = try authority.authorize(principal, team: team, scope: "messages:send", membershipID: nil)
            let target = try recipient.map { human in
                guard let membership = try authority.membershipID(team: team, humanID: human) else { throw QueueError.denied }
                return membership
            }
            if let old = try db.query("SELECT * FROM rt_workspace_message WHERE team=? AND message=?", [team, id]).first {
                guard old["author"]?.utf8Bytes == principal.humanID.utf8Bytes,
                      old["author_membership"]?.utf8Bytes == sender.utf8Bytes,
                      old["body"]?.utf8Bytes == text.utf8Bytes,
                      old["recipient"]?.utf8Bytes == recipient?.utf8Bytes,
                      old["recipient_membership"]?.utf8Bytes == target?.utf8Bytes else { throw QueueError.conflict }
                return
            }
            try db.query("""
                INSERT INTO rt_workspace_message(team,message,author,author_membership,body,recipient,recipient_membership)
                VALUES(?,?,?,?,?,?,?)
                """, [team, id, principal.humanID, sender, text, recipient, target])
        }
    }

    // Resolve inside the same immediate transaction that materializes the rows.
    func readAudience(team: String, principal: QueuePrincipal) throws -> WorkspaceAudience {
        let generation = try authority.authorize(principal, team: team, scope: "sessions:read", membershipID: nil)
        return WorkspaceAudience(team: team, human: principal.humanID, generation: generation)
    }

    func visibleMessages(_ audience: WorkspaceAudience, limit: Int = -1) throws -> [JSONObject] {
        try db.query("""
            SELECT message,body,author,recipient FROM rt_workspace_message
            WHERE \(WorkspaceAudience.predicate) ORDER BY seq LIMIT ?
            """, audience.bindings + [String(limit)]).map { row in
                try ["message_id": .string(row.required("message")), "text": .string(row.required("body")),
                     "author_id": .string(row.required("author")), "recipient_id": row["recipient"].map(JSONValue.string) ?? .null]
            }
    }

    public func messages(team: String, principal: QueuePrincipal) throws -> [JSONObject] {
        try db.transaction {
            try visibleMessages(readAudience(team: team, principal: principal))
        }
    }
}
