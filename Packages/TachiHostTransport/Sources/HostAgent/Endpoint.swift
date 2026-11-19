import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import TachiHostTransport

/// One bounded response on a serial URLSession delegate queue. wait() observes
/// the completion signal before reading the result. Redirects never carry keys.
private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var bytes = Data()
    private var status = 0
    private var failed = false
    private let caDER: Data?

    init(caDER: Data?) { self.caDER = caDER }

    #if canImport(Security)
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let caDER, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // Preserve URLSession's SSL policy (including the requested hostname).
        guard let trust = challenge.protectionSpace.serverTrust,
              let anchor = SecCertificateCreateWithData(nil, caDER as CFData),
              SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    #endif

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= maxResponseBytes - bytes.count else { failed = true; dataTask.cancel(); return }
        bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        failed = failed || error != nil
        done.signal()
    }
    func wait() throws -> Data {
        guard done.wait(timeout: .now() + 12) == .success, !failed else { throw TransportError.unavailable }
        guard status == 200 else { throw TransportError.status(status) }
        return bytes
    }
}

struct Endpoint: Sendable {
    let origin: URL
    private let caDER: Data?

    init(_ address: String, caFile: String?) throws {
        if let caFile {
            #if canImport(Security)
            let data = try Data(contentsOf: URL(fileURLWithPath: caFile))
            guard SecCertificateCreateWithData(nil, data as CFData) != nil else { throw TransportError.invalid }
            caDER = data
            #else
            throw TransportError.invalid
            #endif
        } else {
            caDER = nil
        }
        if let port = UInt16(address), port > 0 {
            guard caDER == nil else { throw TransportError.invalid }
            origin = URL(string: "http://127.0.0.1:\(port)")!
            return
        }
        guard var parts = URLComponents(string: address), parts.scheme == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, ["", "/"].contains(parts.path),
              parts.port.map({ (1...65535).contains($0) }) ?? true else { throw TransportError.invalid }
        parts.path = ""
        guard let url = parts.url else { throw TransportError.invalid }
        origin = url
    }

    func post<Input: Encodable, Output: Decodable>(_ route: String, host: String?, bearer: String,
                                                   _ input: Input, as: Output.Type) throws -> Output {
        let url = origin.appendingPathComponent("v1").appendingPathComponent("host").appendingPathComponent(route)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        if let host { request.setValue(host, forHTTPHeaderField: "X-Tachi-Host") }
        request.httpBody = try JSONEncoder().encode(input)
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.connectionProxyDictionary = [:]
        config.urlCache = nil
        config.timeoutIntervalForResource = 8
        let transfer = Transfer(caDER: caDER), connection = URLSession(configuration: config, delegate: transfer, delegateQueue: nil)
        defer { connection.invalidateAndCancel() }
        connection.dataTask(with: request).resume()
        return try JSONDecoder().decode(Output.self, from: transfer.wait())
    }
}
