import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import TachiAccounts
import TachiRuntime
import TachiHostTransport
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private final class Handler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let routes: HostRoutes
    private var head: HTTPRequestHead?
    private var body = Data()
    private var responding = false

    init(_ routes: HostRoutes) { self.routes = routes }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !responding else { return }
        let ch = context.channel
        switch unwrapInboundIn(data) {
        case .head(let h): head = h
        case .body(let buf):
            guard buf.readableBytes <= 4096 - body.count else {
                responding = true
                Self.reply(ch, .payloadTooLarge)
                return
            }
            body.append(contentsOf: buf.readableBytesView)
        case .end:
            responding = true
            guard let h = head, h.method == .POST, h.uri.hasPrefix(baseRoute) else {
                Self.reply(ch, .notFound); return
            }
            let route = String(h.uri.dropFirst(baseRoute.count))
            guard ["pair","connect","heartbeat","disconnect","next","check","finish"].contains(route) else {
                Self.reply(ch, .notFound); return
            }
            let lengths = h.headers["content-length"]
            guard lengths.count == 1, Int(lengths[0]) == body.count, h.headers["transfer-encoding"].isEmpty,
                  h.headers["content-type"].map({ $0.lowercased() }) == ["application/json"] else {
                Self.reply(ch, .badRequest); return
            }
            let auth = h.headers["authorization"], hosts = h.headers["x-tachi-host"]
            guard auth.count == 1, auth[0].hasPrefix("Bearer "), hosts.count <= 1 else {
                Self.reply(ch, .unauthorized); return
            }
            let token = String(auth[0].dropFirst(7)), payload = body, api = routes
            ch.eventLoop.makeFutureWithTask {
                try await api.handle(route: route, host: hosts.first, bearer: token, body: payload)
            }.whenComplete { result in
                switch result {
                case .success(let reply): Self.reply(ch, .ok, reply)
                case .failure(let error):
                    switch error {
                    case AccountsError.denied, TransportError.unauthorized: Self.reply(ch, .unauthorized)
                    case QueueError.denied: Self.reply(ch, .forbidden)
                    case QueueError.conflict: Self.reply(ch, .conflict)
                    case is DecodingError, TransportError.invalid, QueueError.invalidInput: Self.reply(ch, .badRequest)
                    default: Self.reply(ch, .internalServerError)
                    }
                }
            }
        }
    }

    static func reply(_ channel: any Channel, _ status: HTTPResponseStatus, _ data: Data = Data("{}".utf8)) {
        let headers = HTTPHeaders([("Content-Type","application/json"), ("Content-Length",String(data.count)),
                                   ("Cache-Control","no-store"), ("Connection","close")])
        channel.write(HTTPServerResponsePart.head(.init(version: .http1_1, status: status, headers: headers)), promise: nil)
        channel.write(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: data))), promise: nil)
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in channel.close(promise: nil) }
    }
}

private func run(_ args: [String]) throws {
    guard args.count >= 2 else { throw TransportError.usage }
    let db = args[1]
    switch (args[0], args.count) {
    case ("serve", 3):
        guard let port = UInt16(args[2]) else { throw TransportError.usage }
        let routes = try HostRoutes(database: db)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try? group.syncShutdownGracefully() }
        let listener = try ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMapThrowing {
                try channel.pipeline.syncOperations.addHandler(Handler(routes))
            }
        }.bind(host: "127.0.0.1", port: Int(port)).wait()
        guard let bound = listener.localAddress?.port else { throw TransportError.unavailable }
        FileHandle.standardOutput.write(Data("\(bound)\n".utf8))
        try listener.closeFuture.wait()
    case ("invite", 4):
        try privateOutput(args[3]) { try Data(HostStore(path: db).issuePairing(ownerID: args[2]).utf8) }
    case ("grant", 6):
        print(try HostStore(path: db).grant(ownerID: args[2], hostID: args[3], folderID: args[4], action: args[5]))
    case ("revoke", 5):
        try HostStore(path: db).revokeGrant(ownerID: args[2], hostID: args[3], grantID: args[4])
    default: throw TransportError.usage
    }
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    if (args.first == "bind" && args.count == 5) || (args.first == "post" && args.count == 12) {
        try await submitOrBind(args)
    } else {
        try run(args)
    }
}
catch {
    FileHandle.standardError.write(Data("Host sidecar operation failed. Usage: serve DB PORT | invite DB OWNER NEW_FILE | grant DB OWNER HOST FOLDER ACTION | revoke DB OWNER HOST GRANT | bind DB CLIENT_TOKEN_FILE TEAM ALIAS | post DB CLIENT_TOKEN_FILE TEAM RUN ALIAS MESSAGE HOST GRANT FOLDER ACTION CHILD\n".utf8))
    exit(1)
}
