import Foundation

/// One POST. Redirects are refused, proxies are disabled, and the response body is not retained.
func liveWebhookTransport(_ call: WebhookCall, _ timeout: TimeInterval) async throws -> HttpResult {
    let delegate = WebhookRedirectStop()
    let session = makeWebhookSession(timeout: timeout, delegate: delegate, protocolClasses: [])
    defer { session.finishTasksAndInvalidate() }
    return try await performWebhook(call, timeout: timeout, session: session)
}

func makeWebhookSession(
    timeout: TimeInterval,
    delegate: WebhookRedirectStop,
    protocolClasses: [AnyClass]
) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    // Disabled, not inherited. The secret must not follow an environment proxy.
    configuration.connectionProxyDictionary = [
        "HTTPEnable": 0,
        "HTTPSEnable": 0,
        "SOCKSEnable": 0,
    ]
    if !protocolClasses.isEmpty {
        configuration.protocolClasses = protocolClasses
    }
    return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
}

func performWebhook(_ call: WebhookCall, timeout: TimeInterval, session: URLSession) async throws -> HttpResult {
    guard let url = URL(string: call.url) else { throw GrokConnectorError.notSent }
    var request = URLRequest(url: url)
    request.httpMethod = call.method
    request.httpBody = call.body
    request.setValue(call.authorization, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.timeoutInterval = timeout
    request.httpShouldHandleCookies = false
    do {
        let (bytes, response) = try await session.data(for: request)
        var discarded = bytes
        discarded.removeAll(keepingCapacity: false)
        guard let http = response as? HTTPURLResponse else {
            throw GrokConnectorError.submissionUnobserved
        }
        return HttpResult(status: http.statusCode)
    } catch let error as GrokConnectorError {
        throw error
    } catch {
        throw GrokConnectorError.submissionUnobserved
    }
}

final class WebhookRedirectStop: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
