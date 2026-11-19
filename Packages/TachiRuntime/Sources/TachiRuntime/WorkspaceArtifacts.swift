import Foundation

public enum WorkspaceArtifactError: Error { case limitExceeded }

public struct WorkspaceArtifactUpload: Sendable {
    public static let byteLimit = 1_048_576
    public let id, name, contentType: String
    public let bytes: Data
    public let recipient, sourceMessage, sourceTask: String?
    public let fixture: Bool

    public init(id: String, name: String, contentType: String, bytes: Data, recipient: String?,
                sourceMessage: String?, sourceTask: String?, fixture: Bool) throws {
        guard bytes.count <= Self.byteLimit else { throw WorkspaceArtifactError.limitExceeded }
        let components = contentType.split(separator: "/", omittingEmptySubsequences: false)
        let punctuation = "!#$%&'*+-.^_`|~".utf8
        guard UUID(uuidString: id)?.uuidString.lowercased() == id,
              (1...255).contains(name.utf8.count), name != ".", name != "..",
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.contains("/"), !name.contains("\\"), !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              contentType.utf8.count <= 127, components.count == 2,
              components.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { b in
                  (65...90).contains(b) || (97...122).contains(b) || (48...57).contains(b) || punctuation.contains(b)
              } }), sourceMessage == nil || sourceTask == nil
        else { throw QueueError.invalidInput }
        if let sourceMessage, UUID(uuidString: sourceMessage)?.uuidString.lowercased() != sourceMessage {
            throw QueueError.invalidInput
        }
        if let sourceTask, !(1...256).contains(sourceTask.utf8.count) { throw QueueError.invalidInput }
        self.id = id
        self.name = name
        self.contentType = contentType
        self.bytes = bytes
        self.recipient = recipient
        self.sourceMessage = sourceMessage
        self.sourceTask = sourceTask
        self.fixture = fixture
    }
}

extension WorkspaceHistory {
    static let artifactSchema = """
        CREATE TABLE IF NOT EXISTS rt_workspace_artifact (
            seq INTEGER PRIMARY KEY, team TEXT NOT NULL, artifact TEXT NOT NULL,
            name TEXT NOT NULL, content_type TEXT NOT NULL, size_bytes INTEGER NOT NULL CHECK(size_bytes BETWEEN 0 AND 1048576),
            sha256 TEXT NOT NULL, content_base64 TEXT NOT NULL, origin TEXT NOT NULL,
            author TEXT NOT NULL, author_client TEXT NOT NULL, author_membership TEXT NOT NULL,
            recipient TEXT, recipient_membership TEXT, source_message TEXT, source_task TEXT,
            UNIQUE(team,artifact), CHECK ((recipient IS NULL) = (recipient_membership IS NULL)),
            CHECK (source_message IS NULL OR source_task IS NULL)
        )
        """

    static let deletedArtifactSchema = """
        CREATE TABLE IF NOT EXISTS rt_deleted_workspace_artifact (
            team TEXT NOT NULL, artifact TEXT NOT NULL, PRIMARY KEY(team,artifact)
        ) WITHOUT ROWID
        """

    // Writers predating the delete route also have to respect reserved IDs.
    static let preventArtifactResurrection = """
        CREATE TRIGGER IF NOT EXISTS rt_reject_deleted_artifact BEFORE INSERT ON rt_workspace_artifact
        WHEN EXISTS (SELECT 1 FROM rt_deleted_workspace_artifact WHERE team=NEW.team AND artifact=NEW.artifact)
        BEGIN SELECT RAISE(ABORT, 'deleted artifact'); END
        """

    public func deleteArtifact(team: String, principal: QueuePrincipal, id: String) throws {
        try db.transaction {
            let generation = try authority.authorize(principal, team: team, scope: "messages:send", membershipID: nil)
            try db.query("""
                DELETE FROM rt_workspace_artifact WHERE team=? AND artifact=? AND author=? AND author_membership=?
                """, [team, id, principal.humanID, generation])
            guard try db.query("SELECT changes() AS removed").first?["removed"] == "1" else { throw QueueError.notFound }
            try db.query("INSERT INTO rt_deleted_workspace_artifact(team,artifact) VALUES (?,?)", [team, id])
        }
    }

    private static let artifactColumns = """
        artifact,name,content_type,size_bytes,sha256,origin,author,recipient,source_message,source_task
        """

    public func shareArtifact(_ upload: WorkspaceArtifactUpload, team: String, principal: QueuePrincipal,
                              sha256: @Sendable (Data) -> String) throws -> JSONObject {
        let hash = sha256(upload.bytes), content = upload.bytes.base64EncodedString()
        return try db.transaction {
            let sender = try authority.authorize(principal, team: team, scope: "messages:send", membershipID: nil)
            guard try db.query("SELECT 1 FROM rt_deleted_workspace_artifact WHERE team=? AND artifact=?",
                               [team, upload.id]).isEmpty else { throw QueueError.notFound }
            let recipient = try upload.recipient.map { human in
                guard let member = try authority.membershipID(team: team, humanID: human) else { throw QueueError.denied }
                return member
            }
            let fields: [(String, String?)] = [
                ("team",team), ("artifact",upload.id), ("name",upload.name), ("content_type",upload.contentType),
                ("size_bytes",String(upload.bytes.count)), ("sha256",hash), ("content_base64",content),
                ("origin",upload.fixture ? "synthetic_fixture" : "human_upload"), ("author",principal.humanID),
                ("author_membership",sender), ("recipient",upload.recipient), ("recipient_membership",recipient),
                ("source_message",upload.sourceMessage), ("source_task",upload.sourceTask)
            ]
            if upload.sourceMessage != nil || upload.sourceTask != nil {
                _ = try authority.authorize(principal, team: team, scope: "sessions:read", membershipID: sender)
            }
            if let existing = try db.query("SELECT * FROM rt_workspace_artifact WHERE team=? AND artifact=?",
                                           [team, upload.id]).first {
                guard existing["recipient"] == nil || isParticipant(existing, principal.humanID, sender) else {
                    throw QueueError.notFound
                }
                guard fields.allSatisfy({ existing[$0.0]?.utf8Bytes == $0.1?.utf8Bytes }) else { throw QueueError.conflict }
                return try metadata(existing)
            }
            try checkSource(upload, team: team, principal: principal, generation: sender, recipientGeneration: recipient)
            guard try db.query("""
                SELECT COUNT(*) FROM rt_workspace_artifact WHERE team=?
                HAVING COUNT(*) < 256 AND COALESCE(SUM(size_bytes),0) + CAST(? AS INTEGER) <= 67108864
                """, [team, String(upload.bytes.count)]).first != nil else { throw WorkspaceArtifactError.limitExceeded }
            let columns = fields.map(\.0) + ["author_client"]
            let slots = Array(repeating: "?", count: columns.count).joined(separator: ",")
            try db.query("INSERT INTO rt_workspace_artifact(\(columns.joined(separator: ","))) VALUES(\(slots))",
                         fields.map(\.1) + [principal.clientID])
            return try metadata(Dictionary(uniqueKeysWithValues: fields.compactMap { key, value in value.map { (key, $0) } }))
        }
    }

    private func isParticipant(_ row: Row, _ human: String, _ generation: String) -> Bool {
        (row["author"]?.utf8Bytes == human.utf8Bytes && row["author_membership"]?.utf8Bytes == generation.utf8Bytes) ||
        (row["recipient"]?.utf8Bytes == human.utf8Bytes && row["recipient_membership"]?.utf8Bytes == generation.utf8Bytes)
    }

    private func checkSource(_ upload: WorkspaceArtifactUpload, team: String, principal: QueuePrincipal,
                             generation: String, recipientGeneration: String?) throws {
        guard let id = upload.sourceMessage ?? upload.sourceTask else { return }
        let sql = upload.sourceMessage != nil ? """
            SELECT author,author_membership,recipient,recipient_membership,recipient IS NOT NULL AS private
            FROM rt_workspace_message WHERE team=? AND message=?
            """ : """
            SELECT CASE WHEN substr(author,1,6)='human:' THEN substr(author,7) END AS author,
                   membership AS author_membership,
                   CASE WHEN substr(direct_to,1,6)='human:' THEN substr(direct_to,7) END AS recipient,
                   recipient_membership,direct_to IS NOT NULL AS private
            FROM rt_message WHERE team=? AND message=? AND capability='task'
            """
        guard let source = try db.query(sql, [team, id]).first else { throw QueueError.notFound }
        if source["private"] == "1" {
            guard isParticipant(source, principal.humanID, generation) else { throw QueueError.notFound }
            guard let to = upload.recipient, let recipientGeneration, isParticipant(source, to, recipientGeneration)
            else { throw QueueError.denied }
        }
    }

    func visibleArtifactRows(_ audience: WorkspaceAudience, limit: Int = -1) throws -> [Row] {
        try db.query("""
            SELECT \(Self.artifactColumns) FROM rt_workspace_artifact
            WHERE \(WorkspaceAudience.predicate) ORDER BY seq LIMIT ?
            """, audience.bindings + [String(limit)])
    }

    public func artifacts(team: String, principal: QueuePrincipal) throws -> [JSONObject] {
        try db.transaction {
            try visibleArtifactRows(readAudience(team: team, principal: principal)).map(metadata)
        }
    }

    func verifiedArtifact(_ id: String, audience: WorkspaceAudience, sha256: @Sendable (Data) -> String) throws -> JSONObject {
        guard let row = try db.query("""
            SELECT \(Self.artifactColumns),
                CASE WHEN length(CAST(content_base64 AS BLOB)) = 4 * ((size_bytes + 2) / 3) THEN content_base64 END AS content_base64
            FROM rt_workspace_artifact WHERE \(WorkspaceAudience.predicate) AND artifact=?
            """, audience.bindings + [id]).first else { throw QueueError.notFound }
        let content = try row.required("content_base64")
        guard let bytes = Data(base64Encoded: content), String(bytes.count) == row["size_bytes"],
              sha256(bytes) == row["sha256"] else { throw QueueError.corruptStore }
        var result = try metadata(row)
        result["content_base64"] = .string(content)
        return result
    }

    public func artifact(team: String, principal: QueuePrincipal, id: String,
                         sha256: @Sendable (Data) -> String) throws -> JSONObject {
        try db.transaction {
            try verifiedArtifact(id, audience: readAudience(team: team, principal: principal), sha256: sha256)
        }
    }

    private func metadata(_ row: Row) throws -> JSONObject {
        guard let size = try Int64(row.required("size_bytes")) else { throw QueueError.corruptStore }
        return try ["artifact_id": .string(row.required("artifact")), "name": .string(row.required("name")),
                    "content_type": .string(row.required("content_type")), "size_bytes": .integer(size),
                    "sha256": .string(row.required("sha256")), "origin": .string(row.required("origin")),
                    "author_id": .string(row.required("author")), "audience": .string(row["recipient"] == nil ? "room" : "direct"),
                    "recipient_id": row["recipient"].map(JSONValue.string) ?? .null,
                    "source_message_id": row["source_message"].map(JSONValue.string) ?? .null,
                    "source_task_id": row["source_task"].map(JSONValue.string) ?? .null]
    }
}
