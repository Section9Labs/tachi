import SwiftUI

struct WorkspaceAssistantsView: View {
    let api: WorkspaceAssistantClient
    let workspaceID: String
    let canManage: Bool
    let canSend: Bool

    @State private var assistant: WorkspaceAssistant?
    @State private var routines: [SoloRoutine] = []
    @State private var assignments: [WorkspaceAssignment] = []
    @State private var busy = false
    @State private var loaded = false
    @State private var errorMessage: String?
    @State private var draft = ""
    @State private var pending: WorkspaceAssistantClient.Draft?
    @State private var checkedPending = false
    @State private var pollingID: String?
    @State private var selectedRoutine: SoloRoutine?
    @State private var confirmingAttach = false
    @State private var confirmingRevoke = false

    var body: some View {
        Form {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
            }
            if !loaded && busy {
                ProgressView("Checking workspace assistants…")
            }
            if loaded {
                bindingSection
                if let pending {
                    Section("Unconfirmed Submission") {
                        Text("Tachi couldn’t confirm whether the coordinator received this assignment.")
                        Button("Check Submission") { Task { await checkPending(pending) } }
                            .disabled(busy)
                        if checkedPending && assistant?.id == pending.assistantID {
                            Button("Retry Same Assignment") { Task { await submit(pending) } }
                                .disabled(busy)
                        }
                    }
                } else if let assistant, canSend {
                    composer(assistant)
                }
                historySection
            }
        }
        .navigationTitle("Assistants")
        .toolbar {
            Button("Refresh Assistants") { Task { await refresh() } }
                .disabled(busy)
        }
        .confirmationDialog("Allow Room Assignments?", isPresented: $confirmingAttach, titleVisibility: .visible,
                            presenting: selectedRoutine) { routine in
            Button("Attach and Allow Assignments") { Task { await attach(routine) } }
            Button("Cancel", role: .cancel) {}
        } message: { routine in
            Text("Any current workspace member with permission to send messages can send assignment text to the Grok routine ‘\(routine.id)’. Assignment text is visible to the workspace.")
        }
        .confirmationDialog("Revoke Grok Bot?", isPresented: $confirmingRevoke, titleVisibility: .visible,
                            presenting: assistant) { binding in
            Button("Revoke Assistant", role: .destructive) { Task { await revoke(binding) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Revoking blocks future dispatch. Outstanding submissions keep their recorded receipt or uncertainty.")
        }
        .task { await refresh() }
        .task(id: pollingID) {
            guard let pollingID else { return }
            for _ in 0..<5 {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                await perform {
                    let receipt = try await api.status(assignmentID: pollingID, workspaceID: workspaceID)
                    record(receipt)
                    if receipt.state != .queued && receipt.state != .uncertain { self.pollingID = nil }
                }
                if self.pollingID == nil || errorMessage != nil { return }
            }
        }
    }

    private var bindingSection: some View {
        Section("Workspace Assistant") {
            if assistant != nil {
                Text("Grok Bot")
                if canManage {
                    Button("Revoke Grok Bot…", role: .destructive) { confirmingRevoke = true }
                        .disabled(busy)
                }
            } else {
                Text("No assistant attached.").foregroundStyle(.secondary)
                if canManage && canSend {
                    ForEach(routines) { routine in
                        Button("Attach \(routine.id)…") {
                            selectedRoutine = routine
                            confirmingAttach = true
                        }
                        .disabled(busy)
                    }
                    if routines.isEmpty {
                        Text("Ask your coordinator operator to connect a Grok Bot routine first.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func composer(_ binding: WorkspaceAssistant) -> some View {
        Section("Assign to Grok Bot") {
            if assignments.contains(where: { $0.assistantID == binding.id && $0.state.holdsRoutine }) {
                Text("This routine has an outstanding assignment. Check Grok for its progress.")
                    .foregroundStyle(.secondary)
            } else {
                TextField("Assignment text", text: $draft, axis: .vertical)
                    .lineLimit(3...6)
                    .accessibilityIdentifier("workspace-assignment-input")
                    .disabled(busy)
                Text("This text is visible in the workspace and goes to Grok Bot. Check Grok for results.")
                    .foregroundStyle(.secondary)
                Button("Send Assignment") { Task { await send(binding) } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(busy || !WorkspaceAssistantClient.Draft.validText(draft))
            }
        }
    }

    private var historySection: some View {
        Section("Assignment History") {
            if assignments.isEmpty {
                Text("No assignments yet.").foregroundStyle(.secondary)
            }
            ForEach(assignments) { assignment in
                VStack(alignment: .leading, spacing: 5) {
                    Text(assignment.text).textSelection(.enabled)
                    Text(assignment.authorID).font(.caption).foregroundStyle(.secondary)
                    Text(assignment.state.label).font(.subheadline)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(assignment.text), \(assignment.authorID), \(assignment.state.label)"))
            }
        }
    }

    private func refresh() async {
        await perform { try await load() }
    }

    private func load() async throws {
        async let binding = api.assistant(workspaceID: workspaceID)
        async let history = api.assignments(workspaceID: workspaceID)
        (assistant, assignments) = try await (binding, history)
        if let pending, let receipt = assignments.first(where: { $0.id == pending.id }) {
            record(receipt)
        }
        loaded = true
        if canManage && canSend && assistant == nil { routines = try await api.routines() }
    }

    private func attach(_ routine: SoloRoutine) async {
        guard loaded, canManage, canSend, assistant == nil else { return }
        await perform {
            assistant = try await api.attachWithRoomConsent(routineID: routine.id, workspaceID: workspaceID)
            routines = []
        }
    }

    private func revoke(_ binding: WorkspaceAssistant) async {
        guard canManage, assistant?.id == binding.id else { return }
        await perform {
            try await api.revoke(assistantID: binding.id, workspaceID: workspaceID)
            assistant = nil
            try await load()
        }
    }

    private func send(_ binding: WorkspaceAssistant) async {
        guard loaded, canSend, pending == nil, assistant?.id == binding.id,
              !assignments.contains(where: { $0.assistantID == binding.id && $0.state.holdsRoutine }),
              WorkspaceAssistantClient.Draft.validText(draft) else { return }
        await submit(.init(assistantID: binding.id, text: draft))
    }

    private func submit(_ submission: WorkspaceAssistantClient.Draft) async {
        guard loaded, canSend, assistant?.id == submission.assistantID else { return }
        await perform {
            pending = submission
            checkedPending = false
            do {
                let receipt = try await api.send(submission, workspaceID: workspaceID)
                record(receipt)
                pollingID = receipt.id
            } catch CoordinatorError.httpStatus(let code) where [400, 403, 409, 413].contains(code) {
                pending = nil
                throw CoordinatorError.httpStatus(code)
            }
        }
    }

    private func checkPending(_ pending: WorkspaceAssistantClient.Draft) async {
        await perform {
            do {
                record(try await api.status(assignmentID: pending.id, workspaceID: workspaceID))
                pollingID = pending.id
            } catch CoordinatorError.httpStatus(404) {
                try await load()
                if self.pending != nil {
                    checkedPending = true
                    errorMessage = "The coordinator has no receipt for this assignment."
                }
            }
        }
    }

    private func record(_ assignment: WorkspaceAssignment) {
        if let index = assignments.firstIndex(where: { $0.id == assignment.id }) {
            assignments[index] = assignment
        } else {
            assignments.append(assignment)
        }
        if pending?.id == assignment.id {
            pending = nil
            checkedPending = false
            draft = ""
        }
    }

    private func perform(_ action: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            try await action()
        } catch is CancellationError {
        } catch CoordinatorError.unauthorized {
            hideWorkspaceContent()
            errorMessage = CoordinatorError.unauthorized.errorDescription
        } catch CoordinatorError.httpStatus(404) {
            hideWorkspaceContent()
            errorMessage = "Workspace assistants are unavailable. Refresh to check access."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func hideWorkspaceContent() {
        assistant = nil
        assignments = []
        routines = []
        loaded = false
        pollingID = nil
    }
}

private extension WorkspaceAssignment.State {
    var label: String {
        switch self {
        case .queued: "Queued for Grok Bot."
        case .active: "Routine accepted. Check Grok for the result."
        case .uncertain: "Submission unconfirmed. Check Grok before starting another assignment."
        case .failed: "The routine rejected the assignment."
        case .denied: "Authorization changed before the assignment could be sent."
        case .blocked: "The assignment was blocked before it could be sent."
        }
    }
}
