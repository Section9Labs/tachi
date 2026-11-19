import CWebhook
import Dispatch
import Foundation

/// One POST. A final status line settles the call. The body is not read.
/// Redirects and environment proxies are refused. The continuation resumes once.
func liveWebhookTransport(_ call: WebhookCall, _ timeout: TimeInterval) async throws -> HttpResult {
    let job = WebhookTransferJob()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            job.start(call, timeout: timeout, continuation: continuation)
        }
    } onCancel: {
        job.cancel()
    }
}

/// After the next final status line, also raise the transfer cancel flag.
func armLiveWebhookCancelAfterStatus(_ enabled: Bool) {
    webhook_transfer_arm_cancel_after_status(enabled ? 1 : 0)
}

private final class WebhookTransferJob: @unchecked Sendable {
    private let lock = NSLock()
    private var transfer: OpaquePointer?
    private var continuation: CheckedContinuation<HttpResult, Error>?
    private var cancelRequested = false
    private var settled = false

    func start(
        _ call: WebhookCall,
        timeout: TimeInterval,
        continuation: CheckedContinuation<HttpResult, Error>
    ) {
        guard let transfer = webhook_transfer_create() else {
            continuation.resume(throwing: GrokConnectorError.submissionUnobserved)
            return
        }
        lock.lock()
        self.transfer = transfer
        self.continuation = continuation
        let alreadyCancelled = cancelRequested
        lock.unlock()
        if alreadyCancelled {
            webhook_transfer_cancel(transfer)
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = execute(call, timeout)
            finish(result)
        }
    }

    func cancel() {
        lock.lock()
        cancelRequested = true
        let transfer = self.transfer
        lock.unlock()
        if let transfer {
            webhook_transfer_cancel(transfer)
        }
    }

    private func execute(_ call: WebhookCall, _ timeout: TimeInterval) -> Result<HttpResult, Error> {
        lock.lock()
        let transfer = self.transfer
        lock.unlock()
        guard let transfer else {
            return .failure(GrokConnectorError.submissionUnobserved)
        }
        var status = Int32(0)
        let code: Int32 = call.url.withCString { url in
            call.authorization.withCString { authorization in
                call.body.withUnsafeBytes { raw in
                    webhook_transfer_perform(
                        transfer,
                        url,
                        authorization,
                        raw.baseAddress,
                        raw.count,
                        timeoutMilliseconds(timeout),
                        &status
                    )
                }
            }
        }
        // A status already parsed wins over a cancel or a body abort.
        guard code == 0, (200...599).contains(Int(status)) else {
            return .failure(GrokConnectorError.submissionUnobserved)
        }
        return .success(HttpResult(status: Int(status)))
    }

    private func finish(_ result: Result<HttpResult, Error>) {
        lock.lock()
        let continuation = self.continuation
        let transfer = self.transfer
        self.continuation = nil
        self.transfer = nil
        let first = !settled
        settled = true
        lock.unlock()
        guard first else { return }
        continuation?.resume(with: result)
        if let transfer {
            webhook_transfer_destroy(transfer)
        }
    }
}

private func timeoutMilliseconds(_ timeout: TimeInterval) -> Int {
    guard timeout.isFinite, timeout > 0 else { return 1 }
    let milliseconds = timeout * 1000
    if milliseconds >= Double(Int32.max) { return Int(Int32.max) }
    return max(Int(milliseconds.rounded(.up)), 1)
}
