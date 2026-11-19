import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import TachiAccounts

private struct Reply: Sendable {
    var status: HTTPResponseStatus
    var body: Data

    init(_ status: HTTPResponseStatus, _ body: Data) {
        self.status = status
        self.body = body
    }

    init(_ status: HTTPResponseStatus, error: String) {
        self.init(status, Data(#"{"error":"\#(error)"}"#.utf8))
    }
}

final class CoordinatorHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private static let maximum = 2048
    private let accounts: AccountStore?
    private let pool: NIOThreadPool
    private var head: HTTPRequestHead?
    private var body = Data()
    private var responding = false

    init(accounts: AccountStore?, pool: NIOThreadPool) {
        self.accounts = accounts
        self.pool = pool
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !responding else { return }
        let channel = context.channel
        switch unwrapInboundIn(data) {
        case .head(let request):
            head = request
            if request.method == .POST, request.uri == "/v1/client/pair", accounts != nil,
               let error = Self.checkHeaders(request.headers) {
                responding = true
                Self.send(error, on: channel)
            }
        case .body(let chunk):
            if head?.method == .POST, head?.uri == "/v1/client/pair", accounts != nil {
                guard chunk.readableBytes <= Self.maximum - body.count else {
                    responding = true
                    Self.send(Reply(.badRequest, error: "invalid_length"), on: channel)
                    return
                }
                body.append(contentsOf: chunk.readableBytesView)
            }
        case .end:
            guard let head else { return }
            responding = true
            if head.method == .GET, head.uri == "/v1/status" {
                Self.send(Reply(.ok, Data(#"{"service":"tachi","protocolVersion":1,"status":"ready"}"#.utf8)), on: channel)
                return
            }
            guard (head.method == .POST && head.uri == "/v1/client/pair")
                    || (head.method == .GET && head.uri == "/v1/client/me") else {
                Self.send(Reply(.notFound, error: "not_found"), on: channel)
                return
            }
            guard let accounts else {
                Self.send(Reply(.serviceUnavailable, error: "accounts_disabled"), on: channel)
                return
            }
            let payload = body
            pool.runIfActive(eventLoop: channel.eventLoop) {
                try Self.accountReply(head, body: payload, store: accounts)
            }.whenComplete { result in
                Self.send((try? result.get()) ?? Reply(.internalServerError, error: "storage_error"), on: channel)
            }
        }
    }

    private static func checkHeaders(_ headers: HTTPHeaders) -> Reply? {
        let media = headers["Content-Type"].first?.components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard media == "application/json" else { return Reply(.unsupportedMediaType, error: "expected_json") }
        let lengths = headers["Content-Length"]
        guard lengths.count == 1, headers["Transfer-Encoding"].isEmpty,
              lengths[0].utf8.count <= 4, lengths[0].utf8.allSatisfy({ (48...57).contains($0) }),
              let length = Int(lengths[0]), length <= maximum else { return Reply(.badRequest, error: "invalid_length") }
        return nil
    }

    private static func accountReply(_ head: HTTPRequestHead, body: Data, store: AccountStore) throws -> Reply {
        do {
            if head.method == .POST {
                guard let input = try? JSONDecoder().decode([String: String].self, from: body),
                      input.count == 1, let invitation = input["invitation"] else {
                    return Reply(.badRequest, error: "invalid_request")
                }
                let client = try store.redeemClient(invitation: invitation)
                return try Reply(.created, JSONEncoder().encode(["clientID": client.clientID, "token": client.token]))
            }
            let headers = head.headers["Authorization"]
            guard headers.count == 1 else { throw AccountsError.denied }
            let parts = headers[0].split(whereSeparator: { $0.isWhitespace })
            guard parts.count == 2, parts[0].lowercased() == "bearer" else { throw AccountsError.denied }
            let principal = try store.authenticate(token: String(parts[1]))
            struct Identity: Encodable {
                let humanID, clientID: String
                let scopes: [String]
            }
            return try Reply(.ok, JSONEncoder().encode(Identity(humanID: principal.humanID, clientID: principal.clientID,
                                                                 scopes: principal.scopes.sorted())))
        } catch AccountsError.denied {
            return Reply(.unauthorized, error: "unauthorized")
        }
    }

    private static func send(_ reply: Reply, on channel: Channel) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: String(reply.body.count))
        headers.add(name: "Cache-Control", value: "no-store")
        headers.add(name: "Connection", value: "close")
        let head = HTTPResponseHead(version: .http1_1, status: reply.status, headers: headers)
        channel.write(HTTPServerResponsePart.head(head), promise: nil)
        let body = channel.allocator.buffer(bytes: reply.body)
        channel.write(HTTPServerResponsePart.body(.byteBuffer(body)), promise: nil)
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in channel.close(promise: nil) }
    }
}
