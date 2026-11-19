import Foundation

/// Coordinator-wide counts for a local operator with access to the existing database.
public struct QueueDiagnostics: Encodable, Sendable {
    public let runs: [String: Int64]
    public let deliveries: [String: Int64]

    public static func snapshot(path: String) throws -> Self {
        guard !path.isEmpty, !path.utf8.contains(0) else { throw QueueError.invalidInput }
        // Pass a filesystem path, so SQLite URI parameters cannot alter live WAL handling.
        let db = try RuntimeDatabase(path: URL(fileURLWithPath: path).path, readOnly: true)
        return try db.transaction(write: false) {
            try Self(runs: counts(db, table: "rt_run", states: ["running", "paused", "completed", "cancelled"]),
                     deliveries: counts(db, table: "rt_delivery",
                                        states: ["queued", "active", "blocked", "uncertain", "denied", "completed", "failed", "cancelled"]))
        }
    }

    private static func counts(_ db: RuntimeDatabase, table: String, states: [String]) throws -> [String: Int64] {
        // Only count columns cross the SQLite boundary. Unknown stored strings cannot become output keys.
        let columns = states.map { "COUNT(CASE WHEN state COLLATE BINARY = ? THEN 1 END) AS " + $0 }
        let sql = "SELECT COUNT(*) AS total, " + columns.joined(separator: ", ") + " FROM " + table
        guard let row = try db.query(sql, states).first, var other = try Int64(row.required("total")) else {
            throw QueueError.corruptStore
        }
        var result = [String: Int64]()
        for state in states {
            guard let count = try Int64(row.required(state)) else { throw QueueError.corruptStore }
            result[state] = count
            other -= count
        }
        result["other"] = other
        return result
    }
}
