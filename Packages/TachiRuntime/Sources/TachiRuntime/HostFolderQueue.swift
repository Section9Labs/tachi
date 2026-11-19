import Foundation

/// These closures capture a server-authenticated host session. Reads use the same
/// coordinator database as TeamQueue; neither closure may start a write.
public struct FolderWorker: Sendable {
    public let host: HostWorker
    public let leaseID: @Sendable () throws -> String
    public init(host: HostWorker, leaseID: @escaping @Sendable () throws -> String) {
        self.host = host
        self.leaseID = leaseID
    }
}

public struct HostFolderWork: Sendable, Codable {
    public let requestID: String
    public let scope: HostScope
    public let body: Data?
}

public struct HostFolderReceipt: Sendable, Codable {
    public enum Outcome: String, Sendable, Codable { case completed, refused }
    public let requestID: String
    public let outcome: Outcome
    public let byteCount: Int

    public init(requestID: String, outcome: Outcome, byteCount: Int) {
        self.requestID = requestID
        self.outcome = outcome
        self.byteCount = byteCount
    }
}

extension TeamQueue {
    private static let handed = "host-folder:"
    private static let folderRows = """
        SELECT d.request,d.state AS delivery_state,d.reason,m.*,a.provider,a.account,a.assistant,a.session,r.state AS run_state
        FROM rt_delivery d JOIN rt_message m USING(team,message)
        JOIN rt_assistant a ON a.team=d.team AND a.member=d.target
        JOIN rt_run r ON r.team=m.team AND r.run=m.run
        WHERE d.host=? AND a.provider='tachi-folder'
        """

    private func folderOrigin(_ row: Row, scope: HostScope) throws {
        let human = try row.required("human")
        guard sameID(human, scope.ownerID) else { throw QueueError.denied }
        try authorize(QueuePrincipal(humanID: human, clientID: row.required("client")), row.required("team"),
                      "messages:send", generation: row.required("membership"))
    }

    private func folderBody(_ row: Row, scope: HostScope) throws -> Data? {
        let payload = try decodeJSON(JSONObject.self, row.required("payload"))
        if scope.action == "read", payload.isEmpty { return nil }
        guard scope.action == "write", payload.count == 1, case .string(let text) = payload["bodyBase64"],
              text.utf8.count <= 1_398_104, let bytes = Data(base64Encoded: text), bytes.count <= 1_048_576,
              bytes.base64EncodedString() == text else { throw QueueError.invalidInput }
        return bytes
    }

    public func claimFolderWork(worker: FolderWorker, folderID: String) throws -> HostFolderWork? {
        try db.transaction {
            let generation = try worker.leaseID()
            guard let row = try db.query(Self.folderRows + """

                 AND d.state='queued' AND json_extract(m.scope,'$.folder_id')=? AND r.state='running' AND r.turns<r.turn_limit
                 AND NOT EXISTS (SELECT 1 FROM rt_delivery p WHERE p.team=d.team AND p.target=d.target
                    AND p.seq<d.seq AND p.state IN ('queued','uncertain','active','blocked'))
                 ORDER BY d.seq LIMIT 1
                """, [worker.host.hostID, folderID]).first else { return nil }
            let id = try row.required("request"), scope = try decodeJSON(HostScope.self, row.required("scope"))
            guard sameID(scope.hostID, worker.host.hostID) else { throw QueueError.corruptStore }
            do { try folderOrigin(row, scope: scope) }
            catch QueueError.denied {
                try db.query("UPDATE rt_delivery SET state='denied', reason='origin_denied' WHERE request=?", [id])
                return nil
            }
            do { try worker.host.authorize(scope) }
            catch QueueError.denied {
                try db.query("UPDATE rt_delivery SET state='blocked', reason='host_denied' WHERE request=?", [id])
                return nil
            }
            guard row["capability"] == "task" else {
                try db.query("UPDATE rt_delivery SET state='blocked', reason='unsupported_capability' WHERE request=?", [id])
                return nil
            }
            let body: Data?
            do { body = try folderBody(row, scope: scope) }
            catch QueueError.invalidInput {
                try db.query("UPDATE rt_delivery SET state='denied', reason='invalid_folder_body' WHERE request=?", [id])
                return nil
            }
            try db.query("UPDATE rt_delivery SET state='uncertain',reason=? WHERE request=?", [Self.handed + generation, id])
            try db.query("UPDATE rt_run SET turns=turns+1 WHERE team=? AND run=?", [row.required("team"), row.required("run")])
            return HostFolderWork(requestID: id, scope: scope, body: body)
        }
    }

    public func checkFolderWork(worker: FolderWorker, requestID: String, scope: HostScope) throws {
        // Serialize this check with changes to the run, client, membership and host grants.
        try db.transaction {
            let generation = try worker.leaseID()
            guard let row = try db.query(Self.folderRows + " AND d.request=?", [worker.host.hostID, requestID]).first,
                  row["reason"] == Self.handed + generation, row["delivery_state"] == "uncertain",
                  row["run_state"] == "running",
                  try decodeJSON(HostScope.self, row.required("scope")).object == scope.object else { throw QueueError.denied }
            try folderOrigin(row, scope: scope)
            try worker.host.authorize(scope)
        }
    }

    /// Reconnect may report the already observed outcome; it never grants execution.
    public func finishFolderWork(worker: FolderWorker, receipt: HostFolderReceipt) throws {
        try db.transaction {
            _ = try worker.leaseID()
            guard let row = try db.query(Self.folderRows + " AND d.request=?", [worker.host.hostID, receipt.requestID]).first,
                  row["reason"]?.hasPrefix(Self.handed) == true else { throw QueueError.denied }
            guard (0...1_048_576).contains(receipt.byteCount),
                  receipt.outcome == .completed || receipt.byteCount == 0 else { throw QueueError.invalidInput }
            let scope = try decodeJSON(HostScope.self, row.required("scope"))
            if scope.action == "write", receipt.outcome == .completed,
               try folderBody(row, scope: scope)?.count != receipt.byteCount { throw QueueError.invalidInput }
            try recordEvent(AdapterEvent(identity: row.nativeIdentity(), sessionID: row.required("session"),
                requestID: receipt.requestID, eventID: "folder-result", kind: receipt.outcome == .completed ? .completed : .failed,
                payload: ["byteCount": .integer(Int64(receipt.byteCount))]))
        }
    }
}
