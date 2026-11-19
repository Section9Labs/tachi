import CTachiAccounts
import Foundation

public struct ClientCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let clientID: String
    public let token: String
    public var description: String { "ClientCredential(redacted)" }
    public var debugDescription: String { description }
}

public struct ClientPrincipal: Sendable, Equatable {
    public let humanID: String
    public let clientID: String
    public let scopes: Set<String>

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.humanID.utf8.elementsEqual(rhs.humanID.utf8) && lhs.clientID.utf8.elementsEqual(rhs.clientID.utf8)
            && lhs.scopes == rhs.scopes
    }
}

func printable(_ value: String) -> Bool {
    value.unicodeScalars.allSatisfy { scalar in
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator:
            return false
        case .spaceSeparator: return scalar.value == 32
        default: return true
        }
    }
}

func identifier(_ value: String) throws {
    guard printable(value), value.utf8.contains(where: { $0 != 32 }) else { throw AccountsError.denied }
}

func newSecret() -> String {
    var rng = SystemRandomNumberGenerator()
    let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
    return Data(bytes).base64EncodedString().replacingOccurrences(of: "=", with: "")
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
}

func digest(_ secret: String) throws -> Value {
    let bytes = Array(secret.utf8)
    guard bytes.count == 43, bytes.allSatisfy({ $0 < 128 }) else { throw AccountsError.denied }
    var hash = [UInt8](repeating: 0, count: 32)
    guard tachi_sha256(bytes, bytes.count, &hash) != 0 else { throw AccountsError.invalidRecord }
    return .blob(hash)
}

func newID() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

func requireChange(_ count: Int32) throws {
    guard count == 1 else { throw AccountsError.denied }
}

public struct AccountStore: Sendable {
    public static let supportedScopes: Set<String> = ["sessions:read", "messages:send", "teams:manage"]
    let path: String
    let clock: @Sendable () -> Double

    public init(path: String, clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) throws {
        self.path = path
        self.clock = clock
        let db = try Database(path)
        try db.write { db in
            try db.script("""
                CREATE TABLE IF NOT EXISTS account_client_invitations (
                    digest BLOB PRIMARY KEY NOT NULL, human_id TEXT NOT NULL,
                    scopes TEXT NOT NULL, expires_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS account_clients (
                    client_id TEXT PRIMARY KEY NOT NULL, digest BLOB UNIQUE NOT NULL,
                    human_id TEXT NOT NULL, scopes TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS account_clients_by_human ON account_clients(human_id);
                """)
            try db.script(Self.teamSchema)
        }
    }

    static func scopes(_ value: Value) throws -> Set<String> {
        let text = try value.string()
        guard let items = try? JSONDecoder().decode([String].self, from: Data(text.utf8)) else {
            throw AccountsError.invalidRecord
        }
        let result = Set(items)
        guard !result.isEmpty, result.isSubset(of: supportedScopes) else { throw AccountsError.invalidRecord }
        return result
    }

    public func issueClientInvitation(humanID: String, scopes: Set<String>) throws -> String {
        try identifier(humanID)
        guard !scopes.isEmpty, scopes.isSubset(of: Self.supportedScopes) else { throw AccountsError.invalidScopes }
        let encoded = String(decoding: try JSONEncoder().encode(scopes.sorted()), as: UTF8.self)
        let invitation = newSecret()
        try Database(path).write { db in
            let now = clock()
            try db.run("DELETE FROM account_client_invitations WHERE expires_at <= ?", [.number(now)])
            try db.run("INSERT INTO account_client_invitations (digest,human_id,scopes,expires_at) VALUES (?,?,?,?)",
                       [try digest(invitation), .text(humanID), .text(encoded), .number(now + 300)])
        }
        return invitation
    }

    public func redeemClient(invitation: String) throws -> ClientCredential {
        let key = try digest(invitation)
        return try Database(path).write { db in
            guard let row = try db.rows("""
                SELECT human_id, scopes FROM account_client_invitations WHERE digest = ? AND expires_at > ?
                """, [key, .number(clock())]).first else { throw AccountsError.denied }
            try identifier(row[0].string())
            _ = try Self.scopes(row[1])
            let credential = ClientCredential(clientID: newID(), token: newSecret())
            try db.run("INSERT INTO account_clients (client_id,digest,human_id,scopes) VALUES (?,?,?,?)",
                       [.text(credential.clientID), try digest(credential.token), row[0], row[1]])
            try db.run("DELETE FROM account_client_invitations WHERE digest = ?", [key])
            return credential
        }
    }

    public func authenticate(token: String) throws -> ClientPrincipal {
        guard let row = try Database(path).rows("SELECT human_id, client_id, scopes FROM account_clients WHERE digest = ?",
                                                [try digest(token)]).first else { throw AccountsError.denied }
        return try ClientPrincipal(humanID: row[0].string(), clientID: row[1].string(), scopes: Self.scopes(row[2]))
    }

    func clientScopes(_ db: Database, _ humanID: String, _ clientID: String) throws -> Set<String> {
        try identifier(humanID)
        try identifier(clientID)
        guard let row = try db.rows("SELECT scopes FROM account_clients WHERE human_id = ? AND client_id = ?",
                                    [.text(humanID), .text(clientID)]).first else { throw AccountsError.denied }
        return try Self.scopes(row[0])
    }

    public func authorizeClient(humanID: String, clientID: String, scope: String) throws {
        guard try clientScopes(Database(path), humanID, clientID).contains(scope) else { throw AccountsError.denied }
    }

    public func listClients(humanID: String) throws -> [String] {
        try identifier(humanID)
        return try Database(path).rows("SELECT client_id FROM account_clients WHERE human_id = ? ORDER BY client_id",
                                       [.text(humanID)]).map { try $0[0].string() }
    }

    public func revokeClient(humanID: String, clientID: String) throws {
        try identifier(humanID)
        try identifier(clientID)
        try requireChange(Database(path).run("DELETE FROM account_clients WHERE human_id = ? AND client_id = ?",
                                             [.text(humanID), .text(clientID)]))
    }
}
