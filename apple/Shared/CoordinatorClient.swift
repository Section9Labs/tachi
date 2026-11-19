import Foundation

struct CoordinatorStatus: Decodable {
    let service: String
    let protocolVersion: Int
    let status: String
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
        }
    }
}

struct CoordinatorEndpoint {
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
    let statusURL: URL

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
        components.path = ""
        guard let baseURL = components.url else { throw CoordinatorError.invalidURL }
        components.path = "/v1/status"
        guard let statusURL = components.url else { throw CoordinatorError.invalidURL }
        self.baseURL = baseURL
        self.statusURL = statusURL
    }
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
        var request = URLRequest(url: endpoint.statusURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

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
        guard response.statusCode == 200 else { throw CoordinatorError.httpStatus(response.statusCode) }
        guard let status = try? JSONDecoder().decode(CoordinatorStatus.self, from: data), status.service == "tachi" else {
            throw CoordinatorError.unexpectedResponse
        }
        guard status.protocolVersion == 1 else { throw CoordinatorError.unsupportedProtocol(status.protocolVersion) }
        guard status.status == "ready" else { throw CoordinatorError.notReady }
        return status
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
