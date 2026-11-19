import Foundation
import CTachiAccounts

public struct HostCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let hostID: String
    public let secret: String
    public init(hostID: String, secret: String) { self.hostID = hostID; self.secret = secret }
    public var description: String { "HostCredential(redacted)" }
    public var debugDescription: String { description }
}

public struct HostSession: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let hostID: String
    public let secret: String
    public init(hostID: String, secret: String) { self.hostID = hostID; self.secret = secret }
    public var description: String { "HostSession(redacted)" }
    public var debugDescription: String { description }
}

func validateFolder(_ id: String, _ action: String) throws {
    try identifier(id)
    guard !id.utf8.contains(47), !id.utf8.contains(92), id != ".", id != "..",
          ["read", "write"].contains(action) else { throw AccountsError.denied }
}

func validateRelativePath(_ path: String) throws {
    guard printable(path), !path.utf8.contains(92), !path.utf8.contains(58) else { throw AccountsError.denied }
    // Split on the actual POSIX byte separator, even next to a combining mark.
    let parts = path.utf8.split(separator: 47, omittingEmptySubsequences: false)
    guard !path.isEmpty, parts.allSatisfy({ !$0.isEmpty && !$0.elementsEqual(".".utf8) && !$0.elementsEqual("..".utf8) })
    else { throw AccountsError.denied }
}

public struct HostStore: Sendable {
    public static let leaseSeconds: Double = 30
    private let path: String
    private let clock: @Sendable () -> Double

    public init(path: String, clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) throws {
        self.path = path
        self.clock = clock
        try Database(path).write { db in
            try db.script("""
                CREATE TABLE IF NOT EXISTS host_pairings (
                    digest BLOB PRIMARY KEY NOT NULL, owner_id TEXT NOT NULL, expires_at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS host_devices (
                    host_id TEXT PRIMARY KEY NOT NULL, owner_id TEXT NOT NULL, credential_digest BLOB NOT NULL,
                    session_digest BLOB, lease_until REAL);
                CREATE TABLE IF NOT EXISTS host_grants (
                    grant_id TEXT PRIMARY KEY NOT NULL, host_id TEXT NOT NULL REFERENCES host_devices(host_id) ON DELETE CASCADE,
                    folder_id TEXT NOT NULL, action TEXT NOT NULL CHECK(action IN ('read','write')));
                CREATE INDEX IF NOT EXISTS host_grants_by_host ON host_grants(host_id);
                """)
        }
    }

    public func issuePairing(ownerID: String) throws -> String {
        try identifier(ownerID)
        let invitation = newSecret()
        try Database(path).write { db in
            let now = clock()
            try db.run("DELETE FROM host_pairings WHERE expires_at<=?", [.number(now)])
            try db.run("INSERT INTO host_pairings (digest,owner_id,expires_at) VALUES (?,?,?)",
                       [try digest(invitation), .text(ownerID), .number(now + 300)])
        }
        return invitation
    }

    public func pair(pairingSecret: String) throws -> HostCredential {
        let key = try digest(pairingSecret)
        return try Database(path).write { db in
            let credential = HostCredential(hostID: newID(), secret: newSecret())
            try requireChange(db.run("""
                INSERT INTO host_devices (host_id,owner_id,credential_digest)
                SELECT ?, owner_id, ? FROM host_pairings WHERE digest=? AND expires_at>?
                """, [.text(credential.hostID), try digest(credential.secret), key, .number(clock())]))
            try db.run("DELETE FROM host_pairings WHERE digest=?", [key])
            return credential
        }
    }

    public func connect(credential: HostCredential) throws -> HostSession {
        let session = HostSession(hostID: credential.hostID, secret: newSecret())
        try Database(path).write { db in
            try requireChange(db.run("""
                UPDATE host_devices SET session_digest=?, lease_until=? WHERE host_id=? AND credential_digest=?
                """, [try digest(session.secret), .number(clock() + Self.leaseSeconds),
                      .text(credential.hostID), try digest(credential.secret)]))
        }
        return session
    }

    /// Validate presence without renewing it. The returned non-bearer generation
    /// binds a handout to this connection; it cannot be used as a SQLite verifier.
    public func leaseID(session: HostSession) throws -> String {
        let key = try digest(session.secret)
        guard let row = try Database(path).rows("""
            SELECT lease_until FROM host_devices WHERE host_id=? AND session_digest=?
            """, [.text(session.hostID), key]).first, case .number(let until) = row[0],
              until > clock(), case .blob(let bytes) = key else { throw AccountsError.denied }
        var tag = [UInt8](repeating: 0, count: 32)
        guard tachi_sha256(bytes, bytes.count, &tag) != 0 else { throw AccountsError.invalidRecord }
        return Data(tag).base64EncodedString()
    }

    public func heartbeat(session: HostSession) throws {
        try Database(path).write { db in
            let now = clock()
            try requireChange(db.run("""
                UPDATE host_devices SET lease_until=? WHERE host_id=? AND session_digest=? AND lease_until>?
                """, [.number(now + Self.leaseSeconds), .text(session.hostID), try digest(session.secret), .number(now)]))
        }
    }

    public func disconnect(session: HostSession) throws {
        try requireChange(Database(path).run("""
            UPDATE host_devices SET session_digest=NULL, lease_until=NULL WHERE host_id=? AND session_digest=?
            """, [.text(session.hostID), try digest(session.secret)]))
    }

    public func grant(ownerID: String, hostID: String, folderID: String, action: String) throws -> String {
        try identifier(ownerID)
        try validateFolder(folderID, action)
        let id = newID()
        try requireChange(Database(path).run("""
            INSERT INTO host_grants (grant_id,host_id,folder_id,action)
            SELECT ?,host_id,?,? FROM host_devices WHERE host_id=? AND owner_id=?
            """, [.text(id), .text(folderID), .text(action), .text(hostID), .text(ownerID)]))
        return id
    }

    public func authorize(ownerID: String, session: HostSession, grantID: String, folderID: String,
                          action: String, relativePath: String) throws {
        try identifier(ownerID)
        try validateFolder(folderID, action)
        try validateRelativePath(relativePath)
        guard let row = try Database(path).rows("""
            SELECT h.lease_until FROM host_devices h JOIN host_grants g USING(host_id)
            WHERE h.owner_id=? AND h.host_id=? AND h.session_digest=? AND g.grant_id=? AND g.folder_id=? AND g.action=?
            """, [.text(ownerID), .text(session.hostID), try digest(session.secret), .text(grantID),
                  .text(folderID), .text(action)]).first, case .number(let until) = row[0], until > clock()
        else { throw AccountsError.denied }
    }

    public func revokeGrant(ownerID: String, hostID: String, grantID: String) throws {
        try identifier(ownerID)
        try requireChange(Database(path).run("""
            DELETE FROM host_grants WHERE grant_id=? AND host_id=? AND EXISTS
            (SELECT 1 FROM host_devices WHERE host_id=? AND owner_id=?)
            """, [.text(grantID), .text(hostID), .text(hostID), .text(ownerID)]))
    }

    public func revokeHost(ownerID: String, hostID: String) throws {
        try identifier(ownerID)
        try requireChange(Database(path).run("DELETE FROM host_devices WHERE host_id=? AND owner_id=?",
                                            [.text(hostID), .text(ownerID)]))
    }
}
