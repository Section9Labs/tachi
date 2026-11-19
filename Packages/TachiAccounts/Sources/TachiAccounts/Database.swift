import CTachiAccounts
import Foundation

public enum AccountsError: Error, Equatable {
    case denied
    case invalidScopes
    case invalidRecord
    case database(Int32)
}

enum Value {
    case text(String), blob([UInt8]), number(Double), null

    func string() throws -> String {
        guard case let .text(value) = self else { throw AccountsError.invalidRecord }
        return value
    }
}

// A connection belongs to one synchronous operation. Independent processes and
// threads serialize mutations through SQLite's write lock.
final class Database {
    private let handle: OpaquePointer

    init(_ path: String) throws {
        guard !path.isEmpty, path != ":memory:", !path.utf8.contains(0) else {
            throw AccountsError.database(SQLITE_CANTOPEN)
        }
        var opened: OpaquePointer?
        let rc = sqlite3_open_v2(path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, let opened else {
            sqlite3_close(opened)
            throw AccountsError.database(rc)
        }
        handle = opened
        try check(sqlite3_busy_timeout(handle, 5000))
        try script("PRAGMA foreign_keys = ON")
    }

    deinit { sqlite3_close(handle) }

    private func check(_ rc: Int32) throws {
        guard rc == SQLITE_OK else { throw AccountsError.database(rc) }
    }

    func script(_ sql: String) throws {
        try check(sqlite3_exec(handle, sql, nil, nil, nil))
    }

    func write<T>(_ body: (Database) throws -> T) throws -> T {
        try script("BEGIN IMMEDIATE")
        do {
            let result = try body(self)
            try script("COMMIT")
            return result
        } catch {
            try? script("ROLLBACK")
            throw error
        }
    }

    private func statement<T>(_ sql: String, _ values: [Value],
                              _ body: (OpaquePointer) throws -> T) throws -> T {
        var pointer: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &pointer, nil))
        guard let pointer else { throw AccountsError.invalidRecord }
        defer { sqlite3_finalize(pointer) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .text(let text):
                try check(sqlite3_bind_text64(pointer, index, text, UInt64(text.utf8.count), transient, UInt8(SQLITE_UTF8)))
            case .blob(let bytes):
                try bytes.withUnsafeBytes {
                    try check(sqlite3_bind_blob64(pointer, index, $0.baseAddress, UInt64($0.count), transient))
                }
            case .number(let value): try check(sqlite3_bind_double(pointer, index, value))
            case .null: try check(sqlite3_bind_null(pointer, index))
            }
        }
        return try body(pointer)
    }

    @discardableResult
    func run(_ sql: String, _ values: [Value] = []) throws -> Int32 {
        try statement(sql, values) { stmt in
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE else { throw AccountsError.database(rc) }
            return sqlite3_changes(handle)
        }
    }

    func rows(_ sql: String, _ values: [Value]) throws -> [[Value]] {
        try statement(sql, values) { stmt in
            var result: [[Value]] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { return result }
                guard rc == SQLITE_ROW else { throw AccountsError.database(rc) }
                var row: [Value] = []
                for index in 0..<sqlite3_column_count(stmt) {
                    switch sqlite3_column_type(stmt, index) {
                    case SQLITE_TEXT:
                        guard let pointer = sqlite3_column_text(stmt, index) else { throw AccountsError.invalidRecord }
                        let bytes = UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(stmt, index)))
                        guard let text = String(bytes: bytes, encoding: .utf8) else { throw AccountsError.invalidRecord }
                        row.append(.text(text))
                    case SQLITE_FLOAT, SQLITE_INTEGER: row.append(.number(sqlite3_column_double(stmt, index)))
                    case SQLITE_NULL: row.append(.null)
                    default: throw AccountsError.invalidRecord
                    }
                }
                result.append(row)
            }
        }
    }
}
