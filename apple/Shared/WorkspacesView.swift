import SwiftUI

struct WorkspacesView: View {
    let api: WorkspaceClient
    let account: CoordinatorAccount

    @Environment(\.dismiss) private var dismiss
    @State private var workspaces: [Workspace] = []
    @State private var navigation: [Workspace] = []
    @State private var pendingCreationID: String?
    @State private var busy = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack(path: $navigation) {
            List {
                Section("Your Workspaces") {
                    ForEach(workspaces) { workspace in
                        NavigationLink(value: workspace) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(workspace.title)
                                Text(workspace.role.rawValue.capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let errorMessage {
                        Text(errorMessage)
                    } else if busy && workspaces.isEmpty {
                        ProgressView("Loading workspaces…")
                    } else if workspaces.isEmpty {
                        Text("No workspaces yet.").foregroundStyle(.secondary)
                    }
                }
                Section {
                    if account.scopes.contains("teams:manage") {
                        Button("Create Workspace") { Task { await create() } }
                            #if os(macOS)
                            .buttonStyle(.borderless)
                            #endif
                            .disabled(busy)
                    }
                    NavigationLink("Join Workspace") {
                        JoinWorkspaceView(api: api, onJoined: remember)
                    }
                    Button("Refresh Workspaces") { Task { await refresh() } }
                        #if os(macOS)
                        .buttonStyle(.borderless)
                        #endif
                        .disabled(busy)
                }
            }
            .navigationTitle("Workspaces")
            .navigationDestination(for: Workspace.self) { workspace in
                WorkspaceDetailView(api: api, account: account, workspace: workspace, onRevoked: forget)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: { dismiss() }).keyboardShortcut(.cancelAction)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 480)
        #endif
        .task { await refresh() }
    }

    private func refresh() async {
        busy = true
        defer { busy = false }
        do {
            workspaces = try await api.list()
            errorMessage = nil
        } catch is CancellationError {
        } catch CoordinatorError.unauthorized {
            workspaces = []
            errorMessage = CoordinatorError.unauthorized.errorDescription
        } catch CoordinatorError.httpStatus(404) {
            workspaces = []
            errorMessage = "Workspaces are unavailable on this coordinator."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func create() async {
        guard !busy else { return }
        let id = pendingCreationID ?? UUID().uuidString.lowercased()
        pendingCreationID = id
        busy = true
        defer { busy = false }
        do {
            let workspace = try await api.create(id: id)
            remember(workspace)
            pendingCreationID = nil
            errorMessage = nil
            navigation.append(workspace)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remember(_ workspace: Workspace) {
        workspaces.removeAll { $0.id == workspace.id }
        workspaces.append(workspace)
    }

    private func forget(_ workspaceID: String) {
        workspaces.removeAll { $0.id == workspaceID }
    }
}

private struct JoinWorkspaceView: View {
    let api: WorkspaceClient
    let onJoined: (Workspace) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var workspaceID = ""
    @State private var invitation = ""
    @State private var busy = false
    @State private var errorMessage: String?

    private var canonicalID: String? {
        Workspace.canonicalID(workspaceID.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        Form {
            TextField("Workspace ID", text: $workspaceID)
                .accessibilityIdentifier("join-workspace-id")
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            SecureField("Workspace invitation code", text: $invitation)
                .accessibilityIdentifier("workspace-invitation-code")
                .onSubmit { Task { await join() } }
                #if os(iOS)
                .textContentType(.oneTimeCode)
                .submitLabel(.go)
                #endif
            Button("Redeem Invitation") { Task { await join() } }
                .buttonStyle(.borderedProminent)
                .disabled(canonicalID == nil || invitation.isEmpty || busy)
            if let errorMessage { Text(errorMessage) }
        }
        .navigationTitle("Join Workspace")
        .disabled(busy)
    }

    private func join() async {
        guard !busy, let canonicalID, !invitation.isEmpty else { return }
        let code = invitation.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        defer { busy = false }
        do {
            let workspace = try await api.join(workspaceID: canonicalID, invitation: code)
            invitation = ""
            onJoined(workspace)
            dismiss()
        } catch CoordinatorError.httpStatus(403) {
            errorMessage = "This invitation is unavailable. Ask the workspace owner for a new invitation."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
