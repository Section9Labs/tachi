import Foundation

struct CoordinatorStatus: Decodable {
    let service: String
    let protocolVersion: Int
    let status: String
}

struct CoordinatorCredential: Codable, Sendable {
    let clientID: String
    let token: String

    var isValid: Bool {
        !clientID.isEmpty && token.range(of: #"\A[A-Za-z0-9._~+/-]+=*\z"#, options: .regularExpression) != nil
    }
}

struct CoordinatorAccount: Decodable, Sendable {
    let humanID: String
    let clientID: String
    let scopes: [String]
}

enum CoordinatorError: LocalizedError, Equatable {
    case invalidURL
    case requiresHTTPS
    case unreachable
    case timedOut
    case secureConnectionFailed
    case unexpectedResponse
    case httpStatus(Int)
    case unsupportedProtocol(Int)
    case notReady
    case invitationRejected
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a coordinator URL with a host and optional port."
        case .requiresHTTPS: "Use an HTTPS URL for the coordinator."
        case .unreachable: "Couldn’t reach the coordinator. Check the URL and try again."
        case .timedOut: "The coordinator took too long to respond. Try again."
        case .secureConnectionFailed: "Couldn’t establish a secure connection to the coordinator."
        case .unexpectedResponse: "The server didn’t return a valid Tachi status."
        case .httpStatus(let code): "The coordinator returned HTTP \(code)."
        case .unsupportedProtocol(let version): "This app can’t use coordinator protocol version \(version)."
        case .notReady: "The coordinator is temporarily unavailable. Try again shortly."
        case .invitationRejected: "This invitation was declined. Ask for a new invitation and try again."
        case .unauthorized: "This device’s access expired or was revoked. Pair with a new invitation to reconnect."
        }
    }
}

struct CoordinatorEndpoint: Sendable {
    static let localDevelopmentURL = "http://127.0.0.1:8743"

    static var allowsLocalHTTP: Bool {
        #if DEBUG && (os(macOS) || targetEnvironment(simulator))
        true
        #else
        false
        #endif
    }

    static var defaultURL: String { allowsLocalHTTP ? localDevelopmentURL : "" }

    let baseURL: URL
    var statusURL: URL { route("v1/status") }

    init(_ input: String, allowsLocalHTTP: Bool = Self.allowsLocalHTTP) throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw CoordinatorError.invalidURL
        }
        guard scheme == "https" || (allowsLocalHTTP && host == "127.0.0.1") else {
            throw CoordinatorError.requiresHTTPS
        }

        components.scheme = scheme
        components.host = host.lowercased()
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        components.path = ""
        guard let baseURL = components.url else { throw CoordinatorError.invalidURL }
        self.baseURL = baseURL
    }

    func route(_ path: String) -> URL { baseURL.appendingPathComponent(path) }
}

final class CoordinatorClient: Sendable {
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration, delegate: StatusSessionDelegate(), delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    func status(at endpoint: CoordinatorEndpoint) async throws -> CoordinatorStatus {
        let request = makeRequest(url: endpoint.statusURL, method: "GET")
        let status: CoordinatorStatus = try await send(request, expecting: 200)
        guard status.service == "tachi" else { throw CoordinatorError.unexpectedResponse }
        guard status.protocolVersion == 1 else { throw CoordinatorError.unsupportedProtocol(status.protocolVersion) }
        guard status.status == "ready" else { throw CoordinatorError.notReady }
        return status
    }

    func pair(at endpoint: CoordinatorEndpoint, invitation: String) async throws -> CoordinatorCredential {
        struct Invitation: Encodable { let invitation: String }

        var request = makeRequest(url: endpoint.route("v1/client/pair"), method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Invitation(invitation: invitation))

        let credential: CoordinatorCredential
        do {
            credential = try await send(request, expecting: 201)
        } catch CoordinatorError.httpStatus(401) {
            throw CoordinatorError.invitationRejected
        }
        guard credential.isValid else { throw CoordinatorError.unexpectedResponse }
        return credential
    }

    func account(at endpoint: CoordinatorEndpoint, credential: CoordinatorCredential) async throws -> CoordinatorAccount {
        let account: CoordinatorAccount = try await authenticated(url: endpoint.route("v1/client/me"), credential: credential)
        guard !account.humanID.isEmpty, account.clientID == credential.clientID else {
            throw CoordinatorError.unexpectedResponse
        }
        return account
    }

    func authenticated<Response: Decodable>(
        url: URL,
        credential: CoordinatorCredential,
        body: Data? = nil
    ) async throws -> Response {
        guard credential.isValid else { throw CoordinatorError.unexpectedResponse }
        var request = makeRequest(url: url, method: body == nil ? "GET" : "POST")
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        do {
            return try await send(request, expecting: 200)
        } catch CoordinatorError.httpStatus(401) {
            throw CoordinatorError.unauthorized
        }
    }

    private func makeRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest, expecting code: Int) async throws -> Response {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw CoordinatorError.timedOut
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                throw CoordinatorError.secureConnectionFailed
            default: throw CoordinatorError.unreachable
            }
        }

        guard let response = response as? HTTPURLResponse else { throw CoordinatorError.unexpectedResponse }
        guard response.statusCode == code else { throw CoordinatorError.httpStatus(response.statusCode) }
        guard let value = try? JSONDecoder().decode(Response.self, from: data) else {
            throw CoordinatorError.unexpectedResponse
        }
        return value
    }
}

private final class StatusSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
