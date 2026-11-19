import Foundation
import TachiAccounts
import TachiRuntime
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

package let baseRoute = "/v1/host/"
package let maxResponseBytes = 1_410_000
package struct Empty: Codable, Sendable { package init() {} }
package struct Key: Codable, Sendable {
    package let hostID, secret: String
    package init(_ host: String, _ secret: String) { hostID = host; self.secret = secret }
}
package struct Select: Codable, Sendable {
    package let folderID: String
    package init(_ folderID: String) { self.folderID = folderID }
}
package struct Next: Codable, Sendable {
    package let work: HostFolderWork?
    package init(_ work: HostFolderWork?) { self.work = work }
}
package struct Check: Codable, Sendable {
    package let requestID: String
    package let scope: HostScope
    package init(_ requestID: String, _ scope: HostScope) { self.requestID = requestID; self.scope = scope }
}

package enum TransportError: Error { case usage, invalid, unauthorized, unavailable, status(Int), localState }

/// Secrets are delivered only into new operator-owned files.
package func privateOutput(_ path: String, produce: () throws -> Data) throws {
    let fd = open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw TransportError.localState }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    try file.write(contentsOf: produce())
    try file.synchronize()
    try file.close()
}

package struct OriginAuthority: QueueAuthority {
    package let accounts: AccountStore
    package init(_ accounts: AccountStore) { self.accounts = accounts }
    package func authorize(_ principal: QueuePrincipal, team: String, scope: String, membershipID: String?) throws -> String {
        do {
            return try accounts.authorizeMembership(humanID: principal.humanID, clientID: principal.clientID,
                teamID: team, scope: scope, membershipID: membershipID).membershipID
        } catch AccountsError.denied { throw QueueError.denied }
    }
    package func membershipID(team: String, humanID: String) throws -> String? {
        try accounts.teamMembership(teamID: team, humanID: humanID)?.membershipID
    }
}

package struct HostRoutes: Sendable {
    let hosts: HostStore
    let queue: TeamQueue
    package init(database: String) throws {
        hosts = try HostStore(path: database)
        queue = try TeamQueue(path: database, authority: OriginAuthority(AccountStore(path: database)))
    }

    package func handle(route: String, host: String?, bearer: String, body: Data) async throws -> Data {
        guard bearer.utf8.count == 43 else { throw TransportError.unauthorized }
        let encode = JSONEncoder(), decode = JSONDecoder()
        encode.outputFormatting = [.withoutEscapingSlashes]
        if route == "pair" {
            _ = try decode.decode(Empty.self, from: body)
            let key = try hosts.pair(pairingSecret: bearer)
            return try encode.encode(Key(key.hostID, key.secret))
        }
        guard let host, !host.isEmpty else { throw TransportError.unauthorized }
        if route == "connect" {
            _ = try decode.decode(Empty.self, from: body)
            let key = try hosts.connect(credential: HostCredential(hostID: host, secret: bearer))
            return try encode.encode(Key(key.hostID, key.secret))
        }
        let session = HostSession(hostID: host, secret: bearer)
        let worker = FolderWorker(host: HostWorker(hostID: host) { scope in
            do {
                try hosts.authorize(ownerID: scope.ownerID, session: session, grantID: scope.grantID,
                                    folderID: scope.folderID, action: scope.action, relativePath: scope.relativePath)
            } catch AccountsError.denied { throw QueueError.denied }
        }, leaseID: { try hosts.leaseID(session: session) })
        switch route {
        case "heartbeat", "disconnect":
            _ = try decode.decode(Empty.self, from: body)
            if route == "heartbeat" { try hosts.heartbeat(session: session) }
            else { try hosts.disconnect(session: session) }
        case "next":
            let selection = try decode.decode(Select.self, from: body)
            let work = try await queue.claimFolderWork(worker: worker, folderID: selection.folderID)
            return try encode.encode(Next(work))
        case "check":
            let check = try decode.decode(Check.self, from: body)
            try await queue.checkFolderWork(worker: worker, requestID: check.requestID, scope: check.scope)
        case "finish":
            let receipt = try decode.decode(HostFolderReceipt.self, from: body)
            try await queue.finishFolderWork(worker: worker, receipt: receipt)
        default: throw TransportError.invalid
        }
        return try encode.encode(Empty())
    }
}
