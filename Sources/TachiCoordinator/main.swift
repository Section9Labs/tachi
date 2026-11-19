#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import Dispatch
import TachiRuntime
import NIOCore
import TachiAccounts
import NIOHTTP1
import NIOPosix

private func serve(host: String, port: Int, accounts: AccountStore?, teams: ReferenceTeams?) throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { try? group.syncShutdownGracefully() }
    let pool = NIOThreadPool(numberOfThreads: 4)
    pool.start()
    defer { try? pool.syncShutdownGracefully() }
    let channel = try ServerBootstrap(group: group)
        .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMapThrowing {
                try channel.pipeline.syncOperations.addHandler(CoordinatorHandler(accounts: accounts, pool: pool, teams: teams))
            }
        }
        .bind(host: host, port: port).wait()
    guard let address = channel.localAddress, let port = address.port, let ip = address.ipAddress else {
        throw ServiceError.missingAddress
    }
    // Dispatch signal sources close the listener and wake the owning service thread.
    let signals = [SIGTERM, SIGINT].map { number in
        _ = signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { channel.close(promise: nil) }
        source.resume()
        return source
    }
    defer { for source in signals { source.cancel() } }
    let worker = teams.map { teams in
        let stopped = channel.eventLoop.makePromise(of: Void.self)
        let task = Task {
            do {
                try await teams.runWorker()
                stopped.succeed(())
            } catch is CancellationError {
                stopped.succeed(())
            } catch {
                stopped.fail(error)
                channel.close(promise: nil)
            }
        }
        return (task, stopped.futureResult)
    }
    let displayHost = ip.contains(":") ? "[\(ip)]" : ip
    let announcement = "Tachi listening on http://\(displayHost):\(port)\n"
    _ = announcement.withCString { write(STDOUT_FILENO, $0, announcement.utf8.count) }
    let closed = Result { try channel.closeFuture.wait() }
    if let (task, stopped) = worker {
        task.cancel()
        try stopped.wait()
    }
    try closed.get()
}

private enum ServiceError: Error { case missingAddress }

var host = "127.0.0.1"
var port = 8743
var database: String?
var enableReferenceTeams = false
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let option = arguments.next() {
    if option == "--reference-teams" {
        enableReferenceTeams = true
        continue
    }
    switch (option, arguments.next()) {
    case ("--db", let value?) where !value.isEmpty:
        database = value
    case ("--host", let value?) where !value.isEmpty:
        host = value
    case ("--port", let value?) where UInt16(value) != nil:
        port = Int(UInt16(value)!)
    default:
        let usage = "Usage: tachi-coordinator [--db PATH] [--reference-teams] [--host ADDRESS] [--port 0...65535]\n"
        _ = usage.withCString { write(STDERR_FILENO, $0, usage.utf8.count) }
        exit(EXIT_FAILURE)
    }
}
let accounts = try database.map { try AccountStore(path: $0) }
let teams: ReferenceTeams?
if enableReferenceTeams {
    guard let database, let accounts else {
        let message = "--reference-teams requires --db PATH\n"
        _ = message.withCString { write(STDERR_FILENO, $0, message.utf8.count) }
        exit(EXIT_FAILURE)
    }
    teams = try ReferenceTeams(path: database, authority: CoordinatorAuthority(accounts: accounts))
} else {
    teams = nil
}
try serve(host: host, port: port, accounts: accounts, teams: teams)
