import Foundation

public typealias JSONObject = [String: JSONValue]

public enum JSONValue: Sendable, Equatable, Codable {
    case null, bool(Bool), integer(Int64), double(Double), string(String)
    case array([JSONValue]), object(JSONObject)

    // SQLite stores JSON text. A whole-valued Double can decode as an Int64 on reopen.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.integer(a), .integer(b)): return a == b
        case let (.double(a), .double(b)): return a == b
        case let (.integer(i), .double(d)), let (.double(d), .integer(i)): return Int64(exactly: d) == i
        case let (.string(a), .string(b)): return a.utf8.elementsEqual(b.utf8)
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            return a.count == b.count && a.allSatisfy { key, value in
                guard let index = b.index(forKey: key) else { return false }
                return b[index].key.utf8.elementsEqual(key.utf8) && b[index].value == value
            }
        default: return false
        }
    }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let integer = try? value.decode(Int64.self) { self = .integer(integer) }
        else if let number = try? value.decode(Double.self), number.isFinite { self = .double(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([Self].self) { self = .array(array) }
        else { self = .object(try value.decode(JSONObject.self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .integer(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }

    func validate() throws {
        switch self {
        case .double(let value) where !value.isFinite: throw RuntimeError.invalidPayload
        case .array(let values): try values.forEach { try $0.validate() }
        case .object(let values): try values.values.forEach { try $0.validate() }
        default: break
        }
    }
}
