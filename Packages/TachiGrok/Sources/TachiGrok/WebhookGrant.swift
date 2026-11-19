import Foundation
import TachiRuntime

public let grokBotProviderID = "grok-bot"

public enum GrokConnectorError: Error, Equatable, Sendable, CustomStringConvertible {
    case notSent
    case rejected(status: Int)
    case submissionUnobserved
    case providerIdentity

    public var description: String {
        switch self {
        case .notSent:
            return "routine call was not sent"
        case .rejected(let status):
            return "routine endpoint returned HTTP \(status)"
        case .submissionUnobserved:
            return "routine submission result was not observed"
        case .providerIdentity:
            return "identity provider must be grok-bot"
        }
    }
}

public struct HttpResult: Sendable, Equatable, CustomStringConvertible {
    public let status: Int

    public init(status: Int) {
        self.status = status
    }

    public var description: String { "HttpResult(status: \(status))" }
}

public struct RoutineAcceptance: Sendable, Equatable, CustomStringConvertible {
    public let accepted: Bool
    public let completed: Bool
    public let status: Int

    public var description: String {
        "RoutineAcceptance(accepted: \(accepted), completed: \(completed), status: \(status))"
    }
}

public struct WebhookCall: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let url: String
    public let method: String
    public let authorization: String
    public let body: Data

    public init(url: String, method: String, authorization: String, body: Data) {
        self.url = url
        self.method = method
        self.authorization = authorization
        self.body = body
    }

    public var description: String { "WebhookCall(method: \(method))" }
    public var debugDescription: String { description }
}

public typealias WebhookTransport = @Sendable (WebhookCall, TimeInterval) async throws -> HttpResult

/// Secret frozen to one provider-issued origin and path.
///
/// `triggerRoutine` accepts this grant and no URL. Description and debug text omit the secret and the path.
public struct WebhookGrant: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let scheme: String
    public let host: String
    public let port: Int
    public let path: String
    public let secret: String

    public init(scheme: String, host: String, port: Int, path: String, secret: String) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.path = path
        self.secret = secret
    }

    public func destination() -> String {
        webhookDestination(scheme: scheme, host: host, port: port, path: path)
    }

    public var description: String {
        "WebhookGrant(scheme: \(scheme), host: \(host), port: \(port))"
    }

    public var debugDescription: String { description }
}

private let refusedHosts: Set<String> = ["api.x.ai", "mtls.api.x.ai", "api2.cursor.sh"]
private let loopbackNames: Set<String> = ["localhost"]

public func bindWebhook(_ url: String, secret: String, allowLoopback: Bool = false) throws -> WebhookGrant {
    if secret.isEmpty || secret.contains(where: \.isWhitespace) {
        throw GrokConnectorError.notSent
    }
    let parsed = try parseIssuedURL(url)
    if parsed.host.isEmpty || parsed.host.hasSuffix(".") {
        throw GrokConnectorError.notSent
    }
    if refusedHosts.contains(parsed.host) {
        throw GrokConnectorError.notSent
    }
    let address = isIPLiteral(parsed.host)
    if address {
        if !(allowLoopback && parsed.scheme == "http" && parsed.host == "127.0.0.1") {
            throw GrokConnectorError.notSent
        }
    }
    let loopbackName = loopbackNames.contains(parsed.host)
    if parsed.scheme == "https" {
        if loopbackName || address {
            throw GrokConnectorError.notSent
        }
    } else if !(allowLoopback && parsed.scheme == "http" && (parsed.host == "127.0.0.1" || loopbackName)) {
        throw GrokConnectorError.notSent
    }
    guard isExactWebhookPath(parsed.path) else { throw GrokConnectorError.notSent }
    let port: Int
    if let parsedPort = parsed.port {
        guard (1...65535).contains(parsedPort) else { throw GrokConnectorError.notSent }
        port = parsedPort
    } else {
        port = parsed.scheme == "https" ? 443 : 80
    }
    return WebhookGrant(scheme: parsed.scheme, host: parsed.host, port: port, path: parsed.path, secret: secret)
}

public func triggerRoutine(
    _ grant: WebhookGrant,
    body: JSONObject? = nil,
    transport: WebhookTransport? = nil,
    timeout: TimeInterval = 30
) async throws -> RoutineAcceptance {
    let issued = grant.destination()
    let bound = try bindWebhook(issued, secret: grant.secret, allowLoopback: grant.scheme == "http")
    guard bound == grant else { throw GrokConnectorError.notSent }
    let payload: Data
    do {
        payload = try encodeWebhookBody(body ?? [:])
    } catch {
        throw GrokConnectorError.notSent
    }
    let call = WebhookCall(
        url: bound.destination(),
        method: "POST",
        authorization: "Bearer \(bound.secret)",
        body: payload
    )
    let send = transport ?? liveWebhookTransport
    let result = try await send(call, timeout)
    guard result.status == 200 else { throw GrokConnectorError.rejected(status: result.status) }
    return RoutineAcceptance(accepted: true, completed: false, status: 200)
}

func encodeWebhookBody(_ body: JSONObject) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(JSONValue.object(body))
}

private struct IssuedURL {
    var scheme: String
    var host: String
    var port: Int?
    var path: String
}

private func parseIssuedURL(_ url: String) throws -> IssuedURL {
    if url.contains(where: \.isWhitespace) || url.contains("?") || url.contains("#") {
        throw GrokConnectorError.notSent
    }
    guard let marker = url.range(of: "://") else { throw GrokConnectorError.notSent }
    let scheme = url[..<marker.lowerBound].lowercased()
    guard scheme == "http" || scheme == "https" else { throw GrokConnectorError.notSent }
    let rest = url[marker.upperBound...]
    let netloc: Substring
    let path: String
    if let slash = rest.firstIndex(of: "/") {
        netloc = rest[..<slash]
        path = String(rest[slash...])
    } else {
        netloc = rest
        path = ""
    }
    if netloc.isEmpty || netloc.contains("@") { throw GrokConnectorError.notSent }
    let host: String
    let port: Int?
    if netloc.hasPrefix("[") {
        guard let end = netloc.firstIndex(of: "]") else { throw GrokConnectorError.notSent }
        host = String(netloc[netloc.index(after: netloc.startIndex)..<end]).lowercased()
        let after = netloc[netloc.index(after: end)...]
        if after.isEmpty {
            port = nil
        } else if after.first == ":" {
            let digits = String(after.dropFirst())
            port = digits.isEmpty ? nil : try parsePort(digits)
        } else {
            throw GrokConnectorError.notSent
        }
    } else if let colon = netloc.lastIndex(of: ":") {
        host = String(netloc[..<colon]).lowercased()
        let digits = String(netloc[netloc.index(after: colon)...])
        port = digits.isEmpty ? nil : try parsePort(digits)
    } else {
        host = String(netloc).lowercased()
        port = nil
    }
    if host.isEmpty { throw GrokConnectorError.notSent }
    return IssuedURL(scheme: scheme, host: host, port: port, path: path)
}

private func parsePort(_ text: String) throws -> Int {
    guard let value = Int(text), text == String(value), (0...65535).contains(value) else {
        throw GrokConnectorError.notSent
    }
    return value
}

private func isExactWebhookPath(_ path: String) -> Bool {
    guard path.hasPrefix("/"), path != "/" else { return false }
    var check = path
    if check.hasSuffix("/") { check.removeLast() }
    let parts = check.split(separator: "/", omittingEmptySubsequences: false)
    guard let first = parts.first, first.isEmpty else { return false }
    for part in parts.dropFirst() where rejectedSegment(String(part)) {
        return false
    }
    return true
}

private func rejectedSegment(_ raw: String) -> Bool {
    let bytes = percentDecodedBytes(raw)
    if bytes.isEmpty || bytes.contains(0x2F) || bytes.contains(0x5C) || bytes.contains(0x00) {
        return true
    }
    return bytes == [0x2E] || bytes == [0x2E, 0x2E]
}

private func percentDecodedBytes(_ raw: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = raw.startIndex
    while index < raw.endIndex {
        let next = raw.index(after: index)
        let third = raw.index(next, offsetBy: 1, limitedBy: raw.endIndex) ?? raw.endIndex
        if raw[index] == "%", next < raw.endIndex, third < raw.endIndex,
           let value = UInt8(raw[next...third], radix: 16) {
            bytes.append(value)
            index = raw.index(after: third)
        } else {
            bytes.append(contentsOf: String(raw[index]).utf8)
            index = next
        }
    }
    return bytes
}

private func isIPLiteral(_ host: String) -> Bool {
    isIPv4Literal(host) || isIPv6Literal(host)
}

private func isIPv4Literal(_ host: String) -> Bool {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return false }
    for part in parts {
        guard let value = Int(part), (0...255).contains(value), String(value) == part else {
            return false
        }
    }
    return true
}

private func isIPv6Literal(_ host: String) -> Bool {
    let lower = host.lowercased()
    if lower.contains("%") { return false }
    let halves = lower.components(separatedBy: "::")
    if halves.count > 2 { return false }
    func hextets(_ side: String) -> [String]? {
        if side.isEmpty { return [] }
        let parts = side.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        for part in parts {
            if part.isEmpty || part.count > 4 || !part.allSatisfy(\.isHexDigit) { return nil }
        }
        return parts
    }
    if halves.count == 1 {
        guard let groups = hextets(halves[0]), groups.count == 8 else { return false }
        return true
    }
    guard let left = hextets(halves[0]), let right = hextets(halves[1]) else { return false }
    return left.count + right.count < 8
}

func webhookDestination(scheme: String, host: String, port: Int, path: String) -> String {
    let authority: String
    if (scheme == "https" && port == 443) || (scheme == "http" && port == 80) {
        authority = host
    } else {
        authority = "\(host):\(port)"
    }
    return "\(scheme)://\(authority)\(path)"
}
