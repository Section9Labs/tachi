import Foundation
import Testing
@testable import Tachi

struct CoordinatorClientTests {
    @Test func endpointUsesVersionedStatusPath() throws {
        let endpoint = try CoordinatorEndpoint("  https://coordinator.example:9443/\n")
        #expect(endpoint.baseURL.absoluteString == "https://coordinator.example:9443")
        #expect(endpoint.statusURL.absoluteString == "https://coordinator.example:9443/v1/status")
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
        guard let url = request.url, url.path == "/v1/status",
              request.httpMethod == "GET",
              request.value(forHTTPHeaderField: "Accept") == "application/json",
              request.value(forHTTPHeaderField: "Authorization") == nil,
              request.value(forHTTPHeaderField: "Cookie") == nil else {
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
        let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
