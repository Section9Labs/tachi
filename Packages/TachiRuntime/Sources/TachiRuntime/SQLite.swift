import Foundation
import RuntimeSQLite

public enum QueueError: Error, Equatable, Sendable {
    case denied, invalidInput, notFound, conflict, corruptStore, storage(Int32)
}

typealias Row = [String: String]
extension Dictionary where Key == String, Value == String {
    func required(_ key: String) throws -> String {
        guard let value = self[key] else { throw QueueError.corruptStore }
        return value
    }
}

/// Confined to one TeamQueue actor. Transactions never span suspension points.
final class RuntimeDatabase {
    private let db: OpaquePointer

    init(path: String) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw QueueError.storage(rc)
        }
        db = handle
        sqlite3_busy_timeout(db, 5000)
        let setup = sqlite3_exec(db, "PRAGMA foreign_keys=ON;\n" + runtimeSchema, nil, nil, nil)
        guard setup == SQLITE_OK else { throw QueueError.storage(setup) }
    }

    deinit { sqlite3_close(db) }

    func transaction<T>(write: Bool = true, _ body: () throws -> T) throws -> T {
        try query(write ? "BEGIN IMMEDIATE" : "BEGIN")
        do {
            let result = try body()
            try query("COMMIT")
            return result
        } catch {
            _ = try? query("ROLLBACK")
            throw error
        }
    }

    @discardableResult func query(_ sql: String, _ args: [String?] = []) throws -> [Row] {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else { throw QueueError.storage(rc) }
        defer { sqlite3_finalize(statement) }
        guard Int(sqlite3_bind_parameter_count(statement)) == args.count else { throw QueueError.invalidInput }
        for (offset, arg) in args.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            if let arg, let length = Int32(exactly: arg.utf8.count) {
                status = sqlite3_bind_text(statement, index, arg, length, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else if arg == nil {
                status = sqlite3_bind_null(statement, index)
            } else { throw QueueError.invalidInput }
            guard status == SQLITE_OK else { throw QueueError.storage(status) }
        }
        var rows: [Row] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return rows
            case SQLITE_ROW:
                var row = Row()
                for index in 0..<sqlite3_column_count(statement) {
                    if let value = sqlite3_column_text(statement, index) {
                        let bytes = UnsafeBufferPointer(start: value, count: Int(sqlite3_column_bytes(statement, index)))
                        guard let text = String(bytes: bytes, encoding: .utf8) else { throw QueueError.corruptStore }
                        row[String(cString: sqlite3_column_name(statement, index))] = text
                    }
                }
                rows.append(row)
            case SQLITE_CONSTRAINT: throw QueueError.conflict
            default: throw QueueError.storage(sqlite3_errcode(db))
            }
        }
    }
}

func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

func decodeJSON<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(text.utf8))
}
