import Foundation
import NIOCore
import NIOHTTP1

struct Reply: Sendable {
    let status: HTTPResponseStatus
    let data: Data
    var challenge: String?

    init(_ status: HTTPResponseStatus, json: [String: Any]? = nil, challenge: String? = nil) {
        do {
            self.data = try json.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
            self.status = status
        } catch {
            self.data = Data()
            self.status = .internalServerError
        }
        self.challenge = challenge
    }
}

final class Handler: ChannelInboundHandler {
    typealias InboundIn = NIOHTTPServerRequestFull
    typealias OutboundOut = HTTPServerResponsePart
    let resource: Plugin
    private var received = false

    init(resource: Plugin) { self.resource = resource }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !received else { return }
        received = true
        let request = unwrapInboundIn(data)
        let channel = context.channel
        Task { [resource] in
            let reply = await resource.reply(request)
            let headers = HTTPHeaders([
                ("Content-Length", String(reply.data.count)), ("Cache-Control", "no-store"),
                ("Content-Type", "application/json"), ("Connection", "close"),
            ] + (reply.challenge.map { [("WWW-Authenticate", $0)] } ?? []))
            channel.eventLoop.execute {
                channel.write(HTTPServerResponsePart.head(.init(version: .http1_1, status: reply.status, headers: headers)), promise: nil)
                if !reply.data.isEmpty {
                    channel.write(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: reply.data))), promise: nil)
                }
                channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in channel.close(promise: nil) }
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
