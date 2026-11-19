import Foundation

public typealias JSONObject = [String: JSONValue]

public enum JSONValue: Sendable, Equatable, Codable {
    case null, bool(Bool), integer(Int64), double(Double), string(String)
    case array([JSONValue]), object(JSONObject)

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
