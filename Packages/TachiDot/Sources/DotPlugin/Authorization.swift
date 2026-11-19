import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum PluginError: Error {
    case invalidConfiguration, unauthorized, insufficientScope, unavailable, wrongTrial
}

struct Configuration: Sendable {
    let resource: URL
    let issuer: URL
    let introspection: URL
    let authorization: String
    let subject: String
    let receiptFile: URL
    let port: Int
    var metadata: URL {
        resource.deletingLastPathComponent().appendingPathComponent(".well-known/oauth-protected-resource/mcp")
    }

    init(environment env: [String: String], arguments: [String]) throws {
        let lab = arguments == ["--local-fixture"]
        guard lab || arguments.isEmpty else { throw PluginError.invalidConfiguration }
        func required(_ key: String) throws -> String {
            guard let value = env["TACHI_DOT_" + key], !value.isEmpty else { throw PluginError.invalidConfiguration }
            return value
        }
        func endpoint(_ key: String) throws -> URL {
            let value = try required(key)
            guard let parts = URLComponents(string: value), let host = parts.host, !host.isEmpty,
                  parts.user == nil, parts.password == nil, parts.fragment == nil, parts.query == nil,
                  lab ? (parts.scheme == "http" && host == "127.0.0.1") : parts.scheme == "https",
                  let url = parts.url else { throw PluginError.invalidConfiguration }
            return url
        }
        resource = try endpoint("RESOURCE")
        issuer = try endpoint("ISSUER")
        introspection = try endpoint("INTROSPECTION")
        guard resource.path == "/mcp", let number = UInt16(env["TACHI_DOT_PORT"] ?? "8745"), number > 0
        else { throw PluginError.invalidConfiguration }
        port = Int(number)
        subject = try required("SUBJECT")
        receiptFile = try URL(fileURLWithPath: required("RECEIPT_FILE"))
        let basic = try required("INTROSPECTION_BASIC")
        guard Data(base64Encoded: basic) != nil else { throw PluginError.invalidConfiguration }
        authorization = "Basic " + basic
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct OAuthResource: Sendable {
    let config: Configuration
    private let session: URLSession

    init(_ config: Configuration) {
        self.config = config
        let settings = URLSessionConfiguration.ephemeral
        settings.httpShouldSetCookies = false
        settings.urlCredentialStorage = nil
        settings.urlCache = nil
        settings.timeoutIntervalForResource = 5
        session = URLSession(configuration: settings, delegate: NoRedirect(), delegateQueue: nil)
    }

    func authorize(_ authorization: String?) async throws {
        let parts = (authorization ?? "").split(separator: " ")
        guard parts.count == 2, parts[0].lowercased() == "bearer", parts[1].utf8.count <= 8192
        else { throw PluginError.unauthorized }
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let token = String(parts[1]).addingPercentEncoding(withAllowedCharacters: unreserved)
        else { throw PluginError.unauthorized }
        var request = URLRequest(url: config.introspection)
        request.httpMethod = "POST"
        request.setValue(config.authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("token=\(token)&token_type_hint=access_token".utf8)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let claims = try? JSONDecoder().decode(Claims.self, from: data) else { throw PluginError.unavailable }
        let now = Date().timeIntervalSince1970
        guard claims.active, claims.token_type?.lowercased() == "bearer",
              claims.nbf.map({ $0 <= now }) ?? true,
              claims.iss?.utf8.elementsEqual(config.issuer.absoluteString.utf8) == true,
              claims.sub?.utf8.elementsEqual(config.subject.utf8) == true,
              claims.aud?.contains(where: { $0.utf8.elementsEqual(config.resource.absoluteString.utf8) }) == true,
              let expiry = claims.exp, expiry > now
        else { throw PluginError.unauthorized }
        guard claims.scope?.split(separator: " ").contains("sample.read") == true
        else { throw PluginError.insufficientScope }
    }
}

private struct Claims: Decodable {
    let active: Bool
    let iss, sub, scope, token_type: String?
    let aud: [String]?
    let exp, nbf: Double?
    enum CodingKeys: CodingKey { case active, iss, sub, scope, aud, exp, nbf, token_type }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        active = try c.decode(Bool.self, forKey: .active)
        token_type = try c.decodeIfPresent(String.self, forKey: .token_type)
        nbf = try c.decodeIfPresent(Double.self, forKey: .nbf)
        iss = try c.decodeIfPresent(String.self, forKey: .iss)
        sub = try c.decodeIfPresent(String.self, forKey: .sub)
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
        exp = try c.decodeIfPresent(Double.self, forKey: .exp)
        if let one = try? c.decode(String.self, forKey: .aud) { aud = [one] }
        else { aud = try c.decodeIfPresent([String].self, forKey: .aud) }
    }
}
