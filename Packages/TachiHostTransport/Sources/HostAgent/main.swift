import Foundation
import Dispatch
import TachiAccounts
import TachiRuntime
import TachiHostTransport
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct Paired: Codable { let origin: String; let key: Key }

/// FolderExecutor checks repeatedly and synchronously, always against the
/// request currently being executed by this single worker.
private final class CurrentRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var requestID: String?
    func set(_ next: String?) { lock.withLock { requestID = next } }
    func get() throws -> String {
        try lock.withLock { guard let requestID else { throw TransportError.invalid }; return requestID }
    }
}

private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopping = false
    var requested: Bool { lock.withLock { stopping } }
    func stop() { lock.withLock { stopping = true } }
}

private func runAgent(endpoint: Endpoint, key: Key, folder: String, state: String) throws {
    var info = stat()
    guard lstat(state, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
          info.st_mode & 0o077 == 0 else { throw TransportError.localState }
    let directory = URL(fileURLWithPath: state)
    let lock = open(directory.appendingPathComponent("worker.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard lock >= 0 else { throw TransportError.localState }
    defer { _ = close(lock) }
    guard lockf(lock, F_TLOCK, 0) == 0 else { throw TransportError.localState }

    let receiptURL = directory.appendingPathComponent("receipt-" + key.hostID)
    let current = CurrentRequest()
    let executor = try FolderExecutor(folder: folder, hostID: key.hostID) { actual, session in
        let scope = try HostScope(ownerID: actual.ownerID, hostID: actual.hostID, grantID: actual.grantID,
                                  folderID: actual.folderID, action: actual.action, relativePath: actual.relativePath)
        _ = try endpoint.post("check", host: session.hostID, bearer: session.secret,
                              Check(current.get(), scope), as: Empty.self)
    }
    defer { executor.close() }

    var session: Key?
    var heartbeat = ContinuousClock.now
    var announced = false
    let stop = StopFlag()
    let signals = [SIGINT, SIGTERM].map { number in
        _ = signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { stop.stop() }
        source.resume()
        return source
    }
    defer {
        if let session {
            _ = try? endpoint.post("disconnect", host: key.hostID, bearer: session.secret, Empty(), as: Empty.self)
        }
        for signal in signals { signal.cancel() }
    }
    while !stop.requested {
        do {
            if session == nil {
                session = try endpoint.post("connect", host: key.hostID, bearer: key.secret, Empty(), as: Key.self)
                heartbeat = .now
            }
            guard let live = session, live.hostID == key.hostID else { throw TransportError.invalid }
            if !announced {
                let publicIDs = ["hostID": key.hostID, "folderID": executor.folderID]
                FileHandle.standardOutput.write(try JSONEncoder().encode(publicIDs) + Data([10]))
                announced = true
            }
            if ContinuousClock.now >= heartbeat {
                _ = try endpoint.post("heartbeat", host: key.hostID, bearer: live.secret, Empty(), as: Empty.self)
                heartbeat = .now.advanced(by: .seconds(8))
            }
            if FileManager.default.fileExists(atPath: receiptURL.path) {
                let receipt = try JSONDecoder().decode(HostFolderReceipt.self, from: Data(contentsOf: receiptURL))
                _ = try endpoint.post("finish", host: key.hostID, bearer: live.secret, receipt, as: Empty.self)
                try FileManager.default.removeItem(at: receiptURL)
            }
            let next = try endpoint.post("next", host: key.hostID, bearer: live.secret, Select(executor.folderID), as: Next.self)
            guard let work = next.work else { Thread.sleep(forTimeInterval: 0.35); continue }
            let s = work.scope
            let local = FolderScope(ownerID: s.ownerID, hostID: s.hostID, grantID: s.grantID,
                                    folderID: s.folderID, action: s.action, relativePath: s.relativePath)
            current.set(work.requestID)
            let receipt: HostFolderReceipt
            do {
                let data = try executor.execute(local, session: HostSession(hostID: key.hostID, secret: live.secret), body: work.body)
                receipt = HostFolderReceipt(requestID: work.requestID, outcome: .completed,
                                            byteCount: data?.count ?? work.body?.count ?? 0)
            } catch {
                // Only report a definite pre-effect refusal. Ambiguous transport
                // or filesystem failures leave the durable queue claim uncertain.
                switch error {
                case AccountsError.denied, FolderError.directChildrenOnly, FolderError.invalidBody, FolderError.byteLimit,
                     FolderError.fileChanged, FolderError.posix(EEXIST), FolderError.posix(ENOENT),
                     FolderError.posix(ELOOP), TransportError.status(403), TransportError.status(401):
                    receipt = HostFolderReceipt(requestID: work.requestID, outcome: .refused, byteCount: 0)
                default:
                    current.set(nil)
                    FileHandle.standardError.write(Data("Unconfirmed host operation; reconciliation required.\n".utf8))
                    continue
                }
            }
            current.set(nil)
            // The delivery row is authoritative. This file is only the host's
            // observation, saved before attempting to acknowledge the effect.
            try JSONEncoder().encode(receipt).write(to: receiptURL, options: .atomic)
        } catch TransportError.status(401) {
            guard session != nil else { throw TransportError.unauthorized }
            session = nil
        } catch TransportError.status(let code) where (500...599).contains(code) {
            Thread.sleep(forTimeInterval: 1)
        } catch TransportError.unavailable {
            Thread.sleep(forTimeInterval: 1)
        }
    }
}

private func main(_ args: [String]) throws {
    guard args.count >= 2 else { throw TransportError.usage }
    let endpoint = try Endpoint(args[1])
    switch (args[0], args.count) {
    case ("pair", 4):
        let ticket = try String(contentsOfFile: args[2], encoding: .utf8).trimmingCharacters(in: .newlines)
        try privateOutput(args[3]) {
            let key = try endpoint.post("pair", host: nil, bearer: ticket, Empty(), as: Key.self)
            return try JSONEncoder().encode(Paired(origin: endpoint.origin.absoluteString, key: key))
        }
    case ("run", 5):
        let paired = try JSONDecoder().decode(Paired.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        guard paired.origin.utf8.elementsEqual(endpoint.origin.absoluteString.utf8), paired.key.hostID.utf8.count == 32,
              paired.key.hostID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw TransportError.invalid }
        try runAgent(endpoint: endpoint, key: paired.key, folder: args[3], state: args[4])
    default: throw TransportError.usage
    }
}

do { try main(Array(CommandLine.arguments.dropFirst())) }
catch {
    FileHandle.standardError.write(Data("Host agent stopped. Usage: pair ORIGIN INVITATION NEW_CREDENTIAL | run ORIGIN CREDENTIAL FOLDER PRIVATE_STATE_DIR\n".utf8))
    exit(1)
}
