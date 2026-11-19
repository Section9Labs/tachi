import CWebhook
import Dispatch
import Foundation

/// One POST. A final status line settles the call. The body is not read.
/// Redirects and environment proxies are refused. The continuation resumes once.
func liveWebhookTransport(_ call: WebhookCall, _ timeout: TimeInterval) async throws -> HttpResult {
    let job = try WebhookTransferJob()
    return try await withTaskCancellationHandler {
        guard !Task.isCancelled else { throw GrokConnectorError.notSent }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: job.execute(call, timeout))
            }
        }
    } onCancel: {
        job.cancel()
    }
}

/// After the next final status line, also raise the transfer cancel flag.
func armLiveWebhookCancelAfterStatus(_ enabled: Bool) {
    webhook_transfer_arm_cancel_after_status(enabled ? 1 : 0)
}

/// Both closures retain this owner. Only the worker drives libcurl; cancellation
/// sets an atomic flag on the same allocation.
private final class WebhookTransferJob: @unchecked Sendable {
    private let transfer: OpaquePointer

    init() throws {
        guard let transfer = webhook_transfer_create() else { throw GrokConnectorError.notSent }
        self.transfer = transfer
    }

    deinit { webhook_transfer_destroy(transfer) }

    func cancel() { webhook_transfer_cancel(transfer) }

    func execute(_ call: WebhookCall, _ timeout: TimeInterval) -> Result<HttpResult, Error> {
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
        if code == 2 { return .failure(GrokConnectorError.notSent) }
        // A status already parsed wins over a cancel or a body abort.
        guard code == 0, (200...599).contains(Int(status)) else {
            return .failure(GrokConnectorError.submissionUnobserved)
        }
        return .success(HttpResult(status: Int(status)))
    }
}

private func timeoutMilliseconds(_ timeout: TimeInterval) -> Int {
    guard timeout.isFinite, timeout > 0 else { return 1 }
    let milliseconds = timeout * 1000
    if milliseconds >= Double(Int32.max) { return Int(Int32.max) }
    return max(Int(milliseconds.rounded(.up)), 1)
}
