import SwiftUI

struct SoloRoutineView: View {
    let api: SoloRoutineClient
    let account: CoordinatorAccount
    let routine: SoloRoutine

    private let store = SoloReceiptStore.shared
    @State private var draft = ""
    @State private var receipt: SoloTaskReceipt?
    @State private var savedTaskID: String?
    @State private var errorMessage: String?
    @State private var work = Work.loading
    @FocusState private var inputFocused: Bool

    private enum Work {
        case loading, unavailable, ready, sending, checking
    }

    private var key: SoloReceiptStore.Routine {
        .init(origin: api.endpoint.baseURL, humanID: account.humanID, routineID: routine.id)
    }

    private var canSend: Bool { account.scopes.contains("messages:send") }
    private var hasTaskInput: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var pollingTaskID: String? {
        guard work == .ready || work == .checking, let receipt,
              receipt.state == .queued || receipt.state == .uncertain else { return nil }
        return receipt.taskID
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Grok Bot routine").font(.headline)
                Text("Results appear in the Grok Bot app.")
                    .foregroundStyle(.secondary)

                if work == .loading {
                    ProgressView("Checking this device’s task receipt…")
                } else if work == .unavailable {
                    Button("Reload Receipt") { Task { await restore() } }
                } else if let receipt {
                    receiptView(receipt)
                } else if canSend {
                    composer
                } else {
                    Text("Ask your coordinator operator for permission to send tasks from this device.")
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle(routine.id)
        .task { await restore() }
        .task(id: pollingTaskID) {
            guard let pollingTaskID else { return }
            for _ in 0..<4 {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard self.pollingTaskID == pollingTaskID else { return }
                await checkStatus()
                if errorMessage != nil { return }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Task input").font(.headline).accessibilityHidden(true)
            TextField("Task input", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
                .focused($inputFocused)
                .accessibilityIdentifier("solo-task-input")
                .disabled(work != .ready)
            Text("This text goes to the connected routine’s text field.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Send Task") { Task { await submit() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(work != .ready || !hasTaskInput)
        }
    }

    private func receiptView(_ receipt: SoloTaskReceipt) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if work == .sending {
                ProgressView("Sending task…")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(receipt.state.title).font(.headline)
                    Text(receipt.state.detail).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("solo-task-receipt")

                if receipt.state.canCheckAgain {
                    Button(work == .checking ? "Checking Status…" : "Check Status") {
                        Task { await checkStatus() }
                    }
                    .disabled(work != .ready)
                }
                if canSend && receipt.state != .queued {
                    Button("Start Another Task") {
                        self.receipt = nil
                        errorMessage = nil
                        inputFocused = true
                    }
                    .disabled(work != .ready)
                }
            }
        }
    }

    private func restore() async {
        work = .loading
        do {
            let latest = try await store.latest(for: key)
            receipt = latest
            savedTaskID = latest?.taskID
            errorMessage = nil
            work = .ready
        } catch {
            errorMessage = "Couldn’t read the task receipt on this device."
            work = .unavailable
        }
    }

    private func submit() async {
        guard work == .ready, receipt == nil, canSend, hasTaskInput else { return }
        let text = draft
        work = .sending
        defer { if work == .sending { work = .ready } }
        inputFocused = false
        errorMessage = nil

        let taskID = UUID().uuidString.lowercased()
        let checkpoint = SoloTaskReceipt(taskID: taskID, state: .uncertain)
        guard await record(checkpoint) else { return }

        draft = ""
        do {
            let snapshot = try await api.submit(routineID: routine.id, taskID: taskID, text: text)
            _ = await record(snapshot)
        } catch CoordinatorError.unauthorized {
            _ = await record(.init(taskID: taskID, state: .denied))
        } catch CoordinatorError.httpStatus(let code) where [400, 403, 404, 409, 413].contains(code) {
            _ = await record(.init(taskID: taskID, state: .rejected))
            if work == .sending { errorMessage = "The coordinator rejected the submission (HTTP \(code))." }
        } catch {
            // The checkpoint remains unconfirmed. Only a GET can settle it from this client.
        }
    }

    private func checkStatus() async {
        guard let receipt, work == .ready else { return }
        work = .checking
        defer { if work == .checking { work = .ready } }
        do {
            let snapshot = try await api.status(routineID: routine.id, taskID: receipt.taskID)
            try Task.checkCancellation()
            errorMessage = nil
            _ = await record(snapshot)
        } catch is CancellationError {
        } catch CoordinatorError.httpStatus(404) {
            errorMessage = "The coordinator has no matching receipt for this task."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func record(_ snapshot: SoloTaskReceipt) async -> Bool {
        do {
            try await store.record(snapshot, for: key, replacing: savedTaskID)
            savedTaskID = snapshot.taskID
            receipt = snapshot
            return true
        } catch let error as SoloReceiptStore.StoreError {
            errorMessage = error.localizedDescription
            work = .unavailable
            return false
        } catch {
            errorMessage = "Couldn’t save the task receipt on this device."
            work = .unavailable
            return false
        }
    }
}

private extension SoloTaskState {
    var title: String {
        switch self {
        case .queued: "Task queued"
        case .accepted: "Routine accepted"
        case .rejected: "Submission rejected"
        case .uncertain: "Submission unconfirmed"
        case .denied: "Dispatch denied"
        case .blocked: "Dispatch blocked"
        }
    }

    var detail: String {
        switch self {
        case .queued: "The coordinator queued the task for this routine."
        case .accepted: "Check Grok for the result."
        case .rejected: "Check the configured routine before sending again."
        case .uncertain: "Check Grok before starting another task."
        case .denied: "This device did not have permission to start the routine."
        case .blocked: "The coordinator could not start the routine. Check with your coordinator operator."
        }
    }

    var canCheckAgain: Bool { self == .queued || self == .uncertain || self == .blocked }
}
