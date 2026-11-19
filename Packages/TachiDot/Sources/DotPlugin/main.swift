import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

private func run() throws {
    let configuration = try Configuration(environment: ProcessInfo.processInfo.environment,
                                          arguments: Array(CommandLine.arguments.dropFirst()))
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { try? group.syncShutdownGracefully() }
    let resource = Plugin(configuration)
    let server = try ServerBootstrap(group: group)
        .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMapThrowing {
                try channel.pipeline.syncOperations.addHandler(NIOHTTPServerRequestAggregator(maxContentLength: 65536))
                try channel.pipeline.syncOperations.addHandler(Handler(resource: resource))
            }
        }.bind(host: "127.0.0.1", port: configuration.port).wait()
    print("Dot plugin listening on loopback port \(server.localAddress?.port ?? 0)")
    try server.closeFuture.wait()
}

do { try run() } catch {
    FileHandle.standardError.write(Data("Dot plugin failed to configure or listen.\n".utf8))
    exit(1)
}
