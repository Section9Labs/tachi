#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import NIOCore
import TachiAccounts
import NIOHTTP1
import NIOPosix

private func serve(host: String, port: Int, accounts: AccountStore?) throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { try? group.syncShutdownGracefully() }
    let pool = NIOThreadPool(numberOfThreads: 4)
    pool.start()
    defer { try? pool.syncShutdownGracefully() }
    let channel = try ServerBootstrap(group: group)
        .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMapThrowing {
                try channel.pipeline.syncOperations.addHandler(CoordinatorHandler(accounts: accounts, pool: pool))
            }
        }
        .bind(host: host, port: port).wait()
    guard let address = channel.localAddress, let port = address.port, let ip = address.ipAddress else {
        throw ServiceError.missingAddress
    }
    let displayHost = ip.contains(":") ? "[\(ip)]" : ip
    let announcement = "Tachi listening on http://\(displayHost):\(port)\n"
    _ = announcement.withCString { write(STDOUT_FILENO, $0, announcement.utf8.count) }
    try channel.closeFuture.wait()
}

private enum ServiceError: Error { case missingAddress }

var host = "127.0.0.1"
var port = 8743
var database: String?
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let option = arguments.next() {
    switch (option, arguments.next()) {
    case ("--db", let value?) where !value.isEmpty:
        database = value
    case ("--host", let value?) where !value.isEmpty:
        host = value
    case ("--port", let value?) where UInt16(value) != nil:
        port = Int(UInt16(value)!)
    default:
        let usage = "Usage: tachi-coordinator [--db PATH] [--host ADDRESS] [--port 0...65535]\n"
        _ = usage.withCString { write(STDERR_FILENO, $0, usage.utf8.count) }
        exit(EXIT_FAILURE)
    }
}
try serve(host: host, port: port, accounts: database.map { try AccountStore(path: $0) })
