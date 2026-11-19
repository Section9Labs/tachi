import Foundation
import Testing
@testable import Tachi

struct CoordinatorClientTests {
    @Test func endpointUsesVersionedStatusPath() throws {
        let endpoint = try CoordinatorEndpoint("  https://coordinator.example:9443/\n")
        #expect(endpoint.baseURL.absoluteString == "https://coordinator.example:9443")
        #expect(endpoint.statusURL.absoluteString == "https://coordinator.example:9443/v1/status")
    }

    @Test func equivalentHTTPSOriginsUseOneKeychainService() throws {
        let first = try CoordinatorEndpoint("HTTPS://COORDINATOR.example:443/")
        let second = try CoordinatorEndpoint("https://coordinator.example")
        #expect(first.baseURL == second.baseURL)
    }

    @Test(arguments: [
        "coordinator.example", "https://", "ftp://coordinator.example", "https://coordinator.example:65536",
        "https://user:secret@coordinator.example", "https://coordinator.example/api",
        "https://coordinator.example?token=fixture", "https://coordinator.example/#fragment"
    ]) func rejectsInvalidBaseURLs(input: String) {
        #expect(throws: CoordinatorError.invalidURL) { try CoordinatorEndpoint(input) }
    }

    @Test func cleartextRequiresDevelopmentLoopback() throws {
        let local = try CoordinatorEndpoint(CoordinatorEndpoint.localDevelopmentURL, allowsLocalHTTP: true)
        #expect(local.statusURL.absoluteString == "http://127.0.0.1:8743/v1/status")
        #expect(throws: CoordinatorError.requiresHTTPS) {
            try CoordinatorEndpoint(CoordinatorEndpoint.localDevelopmentURL, allowsLocalHTTP: false)
        }
        #expect(throws: CoordinatorError.requiresHTTPS) {
            try CoordinatorEndpoint("http://coordinator.example", allowsLocalHTTP: true)
        }
    }

    @Test func readsReadyStatusWithAnUnauthenticatedGET() async throws {
        let status = try await client().status(at: CoordinatorEndpoint("https://ready.example"))
        #expect(status.service == "tachi")
        #expect(status.protocolVersion == 1)
        #expect(status.status == "ready")
    }

    @Test func redeemsInvitationAndChecksBoundAccount() async throws {
        let endpoint = try CoordinatorEndpoint("https://pair.example")
        let client = client()
        let credential = try await client.pair(at: endpoint, invitation: "fixture-invitation")
        let account = try await client.account(at: endpoint, credential: credential)
        #expect(account.humanID == "fixture-human")
        #expect(account.clientID == "fixture-client")
        #expect(account.scopes == ["sessions:read"])
    }

    @Test func distinguishesRejectedInvitationAndRevokedCredential() async throws {
        let endpoint = try CoordinatorEndpoint("https://denied.example")
        let client = client()
        await #expect(throws: CoordinatorError.invitationRejected) {
            try await client.pair(at: endpoint, invitation: "fixture-invitation")
        }
        let credential = CoordinatorCredential(clientID: "fixture-client", token: "fixture-bearer")
        await #expect(throws: CoordinatorError.unauthorized) {
            try await client.account(at: endpoint, credential: credential)
        }
    }

    @Test func rejectsAnUnexpectedClientIdentityAndMalformedBearer() async throws {
        let endpoint = try CoordinatorEndpoint("https://pair.example")
        let client = client()
        let wrongClient = CoordinatorCredential(clientID: "other-client", token: "fixture-bearer")
        let malformed = CoordinatorCredential(clientID: "fixture-client", token: "fixture-bearer\r\n")
        await #expect(throws: CoordinatorError.unexpectedResponse) {
            try await client.account(at: endpoint, credential: wrongClient)
        }
        await #expect(throws: CoordinatorError.unexpectedResponse) {
            try await client.account(at: endpoint, credential: malformed)
        }
    }

    @Test(arguments: [
        ("http-error", CoordinatorError.httpStatus(503)),
        ("invalid", CoordinatorError.unexpectedResponse),
        ("wrong-service", CoordinatorError.unexpectedResponse),
        ("future-version", CoordinatorError.unsupportedProtocol(2)),
        ("starting", CoordinatorError.notReady),
        ("offline", CoordinatorError.unreachable),
        ("timeout", CoordinatorError.timedOut)
    ]) func reportsFailure(host: String, error: CoordinatorError) async throws {
        let endpoint = try CoordinatorEndpoint("https://\(host).example")
        await #expect(throws: error) { try await client().status(at: endpoint) }
    }

    private func client() -> CoordinatorClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StatusURLProtocol.self]
        return CoordinatorClient(configuration: configuration)
    }
}

private final class StatusURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, url.query == nil,
              request.value(forHTTPHeaderField: "Accept") == "application/json",
              request.value(forHTTPHeaderField: "Cookie") == nil else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        switch url.path {
        case "/v1/client/pair" where request.httpMethod == "POST" && authorization == nil
            && request.value(forHTTPHeaderField: "Content-Type") == "application/json":
            guard let body = requestBody(), let object = try? JSONDecoder().decode([String: String].self, from: body),
                  object == ["invitation": "fixture-invitation"] else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            if url.host == "denied.example" { respond(401, "{}", url: url) }
            else { respond(201, #"{"clientID":"fixture-client","token":"fixture-bearer"}"#, url: url) }
            return
        case "/v1/client/me" where request.httpMethod == "GET" && authorization == "Bearer fixture-bearer":
            if url.host == "denied.example" { respond(401, "{}", url: url) }
            else { respond(200, #"{"humanID":"fixture-human","clientID":"fixture-client","scopes":["sessions:read"]}"#, url: url) }
            return
        case "/v1/status" where request.httpMethod == "GET" && authorization == nil:
            break
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        if url.host == "offline.example" || url.host == "timeout.example" {
            let code: URLError.Code = url.host == "offline.example" ? .cannotConnectToHost : .timedOut
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }

        let (code, body): (Int, String) = switch url.host {
        case "ready.example": (200, #"{"service":"tachi","protocolVersion":1,"status":"ready"}"#)
        case "wrong-service.example": (200, #"{"service":"other","protocolVersion":1,"status":"ready"}"#)
        case "future-version.example": (200, #"{"service":"tachi","protocolVersion":2,"status":"ready"}"#)
        case "starting.example": (200, #"{"service":"tachi","protocolVersion":1,"status":"starting"}"#)
        case "http-error.example": (503, "")
        default: (200, "{}")
        }
        respond(code, body, url: url)
    }

    private func requestBody() -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { return body }
            body.append(contentsOf: buffer.prefix(count))
        }
    }

    private func respond(_ code: Int, _ body: String, url: URL) {
        let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
