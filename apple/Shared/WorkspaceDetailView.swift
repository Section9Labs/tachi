import SwiftUI
#if os(iOS)
import UIKit
import UniformTypeIdentifiers
#else
import AppKit
#endif

struct WorkspaceDetailView: View {
    let api: WorkspaceClient
    let account: CoordinatorAccount
    let workspace: Workspace
    let onRevoked: (String) -> Void

    @State private var messages: [WorkspaceMessage] = []
    @State private var busy = false
    @State private var accessLost = false
    @State private var errorMessage: String?
    @State private var draftText = ""
    @State private var direct = false
    @State private var recipient = ""
    @State private var pending: WorkspaceClient.Draft?
    @State private var membershipRecipient = ""
    @State private var invitation: String?
    @State private var membershipNotice: String?
    @State private var workspaceIDCopied = false
    @State private var confirmingRevocation = false
    @FocusState private var messageFocused: Bool

    private var canManage: Bool {
        workspace.role == .owner && account.scopes.contains("teams:manage")
    }

    private var canPost: Bool { account.scopes.contains("messages:send") }
    private var canSendDraft: Bool {
        !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!direct || hasHumanID(recipient))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .accessibilityIdentifier("workspace-error")
                }
                if !accessLost {
                    workspaceInfo
                    NavigationLink("Assistants") {
                        WorkspaceAssistantsView(
                            api: WorkspaceAssistantClient(workspace: api), workspaceID: workspace.id,
                            canManage: canManage, canSend: canPost
                        )
                    }
                    if canManage { membership }
                    if canPost { composer }
                    history
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle(workspace.title)
        .toolbar {
            Button("Refresh Workspace") { Task { await refresh() } }
                .disabled(busy || accessLost)
        }
        .confirmationDialog("Revoke Workspace Access?", isPresented: $confirmingRevocation, titleVisibility: .visible) {
            Button("Revoke Access", role: .destructive) { Task { await revoke() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove \(membershipRecipient) and withdraw their pending invitations.")
        }
        .task { await refresh() }
    }

    private var workspaceInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(workspace.role.rawValue.capitalized)
                .font(.headline)
            Text(workspace.id)
                .foregroundStyle(.secondary)
                // On Mac, selectable text can recurse while AppKit resolves the custom label.
                #if os(iOS)
                .textSelection(.enabled)
                #endif
                .accessibilityLabel("Workspace ID \(workspace.id)")
            Button(workspaceIDCopied ? "Workspace ID Copied" : "Copy Workspace ID") {
                copy(workspace.id)
                workspaceIDCopied = true
            }
        }
    }

    private var membership: some View {
        DisclosureGroup("Membership") {
            VStack(alignment: .leading, spacing: 10) {
                humanIDField("Member human ID", text: $membershipRecipient)
                    .accessibilityIdentifier("workspace-member-id")
                    .onChange(of: membershipRecipient) {
                        invitation = nil
                        membershipNotice = nil
                    }
                    .disabled(busy)
                Button("Create Invitation") { Task { await invite() } }
                    .disabled(busy || !hasHumanID(membershipRecipient))
                if let invitation {
                    Button("Copy Invitation") {
                        copy(invitation, isInvitation: true)
                        membershipNotice = "Invitation copied."
                    }
                    Text("An invitation can be used once and expires in five minutes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let membershipNotice {
                    Text(membershipNotice)
                        .accessibilityIdentifier("workspace-membership-status")
                }
                Button("Revoke Access", role: .destructive) { confirmingRevocation = true }
                    .disabled(busy || !hasHumanID(membershipRecipient))
            }
            .padding(.top, 8)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Message").font(.headline).accessibilityAddTraits(.isHeader)
            Toggle("Direct message", isOn: $direct)
                .disabled(busy || pending != nil)
            if direct {
                humanIDField("Recipient human ID", text: $recipient)
                    .accessibilityIdentifier("workspace-message-recipient")
                    .disabled(busy || pending != nil)
            }
            TextField("Workspace message", text: $draftText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .focused($messageFocused)
                .accessibilityIdentifier("workspace-message-input")
                .disabled(busy || pending != nil)
            Button(pending == nil ? "Send Message" : "Retry Send") { Task { await send() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(busy || (pending == nil && !canSendDraft))
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Messages").font(.headline).accessibilityAddTraits(.isHeader)
            if messages.isEmpty {
                Text("No messages yet.").foregroundStyle(.secondary)
            }
            ForEach(messages) { message in
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.text).textSelection(.enabled)
                    Text(messageCaption(message)).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "\(message.text), \(messageCaption(message))"))
                Divider()
            }
        }
    }

    private func messageCaption(_ message: WorkspaceMessage) -> String {
        let author = message.authorID.utf8.elementsEqual(account.humanID.utf8) ? "You" : message.authorID
        if let recipientID = message.recipientID {
            let recipient = recipientID.utf8.elementsEqual(account.humanID.utf8) ? "you" : recipientID
            return "Direct · \(author) to \(recipient)"
        }
        return "Room · \(author)"
    }

    private func humanIDField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.roundedBorder)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif
    }

    private func refresh() async {
        await perform { messages = try await api.messages(workspaceID: workspace.id) }
    }

    private func send() async {
        guard pending != nil || canSendDraft else { return }
        await perform {
            let message = pending ?? WorkspaceClient.Draft(text: draftText, recipientID: direct ? recipient : nil)
            pending = message
            messageFocused = false
            do {
                try await api.send(message, workspaceID: workspace.id)
            } catch CoordinatorError.httpStatus(let code) where [400, 403, 413].contains(code) {
                pending = nil
                throw CoordinatorError.httpStatus(code)
            }
            pending = nil
            draftText = ""
            messages = try await api.messages(workspaceID: workspace.id)
        }
    }

    private func invite() async {
        guard hasHumanID(membershipRecipient) else { return }
        await perform {
            invitation = nil
            membershipNotice = nil
            invitation = try await api.invite(workspaceID: workspace.id, recipientID: membershipRecipient)
            membershipNotice = "Invitation ready."
        }
    }

    private func revoke() async {
        guard hasHumanID(membershipRecipient) else { return }
        await perform {
            try await api.revoke(workspaceID: workspace.id, recipientID: membershipRecipient)
            invitation = nil
            membershipNotice = "Access revoked."
        }
    }

    private func perform(_ action: () async throws -> Void) async {
        guard !busy, !accessLost else { return }
        busy = true
        defer { busy = false }
        do {
            try await action()
            errorMessage = nil
        } catch is CancellationError {
        } catch CoordinatorError.httpStatus(404) {
            clearWorkspace()
            errorMessage = "This workspace is unavailable to your account."
        } catch CoordinatorError.unauthorized {
            clearWorkspace()
            errorMessage = CoordinatorError.unauthorized.errorDescription
        } catch CoordinatorError.httpStatus(403) {
            errorMessage = "Your account lacks permission for this action."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearWorkspace() {
        messages = []
        pending = nil
        draftText = ""
        invitation = nil
        membershipNotice = nil
        accessLost = true
        onRevoked(workspace.id)
    }

    private func hasHumanID(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func copy(_ value: String, isInvitation: Bool = false) {
        #if os(iOS)
        if isInvitation {
            UIPasteboard.general.setItems([[UTType.plainText.identifier: value]], options: [.localOnly: true])
        } else {
            UIPasteboard.general.string = value
        }
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
    }
}
