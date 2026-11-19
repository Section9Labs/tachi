#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import NIOCore
import NIOHTTP1
import NIOPosix

private final class StatusHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private var request: HTTPRequestHead?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            request = head
        case .body:
            break
        case .end:
            guard let head = request else { return }
            request = nil
            let ready = head.method == .GET && head.uri == "/v1/status"
            let json = ready
                ? #"{"service":"tachi","protocolVersion":1,"status":"ready"}"#
                : #"{"error":"not_found"}"#
            let body = context.channel.allocator.buffer(string: json)
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json")
            headers.add(name: "Content-Length", value: String(body.readableBytes))
            headers.add(name: "Cache-Control", value: "no-store")
            headers.add(name: "Connection", value: "close")
            let response = HTTPResponseHead(version: head.version, status: ready ? .ok : .notFound, headers: headers)
            context.write(wrapOutboundOut(.head(response)), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
                channel.close(promise: nil)
            }
        }
    }
}

private func serve(host: String, port: Int) throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { try? group.syncShutdownGracefully() }
    let channel = try ServerBootstrap(group: group)
        .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMapThrowing {
                try channel.pipeline.syncOperations.addHandler(StatusHandler())
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
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let option = arguments.next() {
    switch (option, arguments.next()) {
    case ("--host", let value?) where !value.isEmpty:
        host = value
    case ("--port", let value?) where UInt16(value) != nil:
        port = Int(UInt16(value)!)
    default:
        let usage = "Usage: tachi-coordinator [--host ADDRESS] [--port 0...65535]\n"
        _ = usage.withCString { write(STDERR_FILENO, $0, usage.utf8.count) }
        exit(EXIT_FAILURE)
    }
}
try serve(host: host, port: port)
