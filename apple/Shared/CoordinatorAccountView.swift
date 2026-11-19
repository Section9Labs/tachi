import SwiftUI

struct CoordinatorAccountView: View {
    let endpoint: CoordinatorEndpoint
    let client: CoordinatorClient
    private let store = CoordinatorCredentialStore()

    @AppStorage("coordinatorAccountLabel") private var savedLabel = "Default"
    @State private var accountLabel = "Default"
    @State private var invitation = ""
    @State private var phase = Phase.unchecked

    private enum Phase {
        case unchecked
        case working
        case unpaired
        case paired(CoordinatorAccount)
        case failed(String)

        var isWorking: Bool {
            if case .working = self { return true }
            return false
        }

        var isPaired: Bool {
            if case .paired = self { return true }
            return false
        }
    }

    private var label: String { accountLabel.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Coordinator account")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text("Use a different label to save another account or client on this device.")
                .foregroundStyle(.secondary)

            Text("Local account label")
                .font(.headline)
                .accessibilityHidden(true)
            TextField("Local account label", text: accountLabelBinding)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("coordinator-account-label")
                .disabled(phase.isWorking)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
                .onSubmit { Task { await checkAccount() } }

            Button("Check Account") { Task { await checkAccount() } }
                .disabled(label.isEmpty || phase.isWorking)

            if !phase.isPaired {
                SecureField("Invitation code", text: $invitation)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("coordinator-invitation")
                    .disabled(phase.isWorking)
                    .onSubmit(pair)

                Button("Pair Device", action: pair)
                    .buttonStyle(.borderedProminent)
                    .disabled(label.isEmpty || invitation.isEmpty || phase.isWorking)
            }

            accountStatus
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("coordinator-account-status")
        }
        .task {
            accountLabel = savedLabel
            await checkAccount()
        }
    }

    private var accountLabelBinding: Binding<String> {
        Binding(get: { accountLabel }, set: { value in
            accountLabel = value
            invitation = ""
            phase = .unchecked
        })
    }

    @ViewBuilder
    private var accountStatus: some View {
        switch phase {
        case .unchecked:
            Text("Check this label for a saved account or pair with an invitation.")
                .foregroundStyle(.secondary)
        case .working:
            ProgressView("Checking account…")
        case .unpaired:
            Text("This label is ready for an invitation.")
                .foregroundStyle(.secondary)
        case .paired(let account):
            VStack(alignment: .leading, spacing: 4) {
                Label("Account connected", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.headline)
                Text(account.humanID)
                    .font(.subheadline)
                    .textSelection(.enabled)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func checkAccount() async {
        guard !phase.isWorking, !label.isEmpty else { return }
        let accountLabel = label
        savedLabel = accountLabel
        phase = .working
        do {
            guard let credential = try await store.load(origin: endpoint.baseURL, account: accountLabel) else {
                try Task.checkCancellation()
                phase = .unpaired
                return
            }
            try await resolve(credential, label: accountLabel)
        } catch is CancellationError {
            phase = .unchecked
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func pair() {
        let code = invitation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phase.isWorking, !code.isEmpty, !label.isEmpty else { return }
        let accountLabel = label
        invitation = ""
        savedLabel = accountLabel
        phase = .working
        Task {
            do {
                guard try await store.load(origin: endpoint.baseURL, account: accountLabel) == nil else {
                    throw CredentialStoreError.occupied
                }
                let credential = try await client.pair(at: endpoint, invitation: code)
                try await store.save(credential, origin: endpoint.baseURL, account: accountLabel)
                try await resolve(credential, label: accountLabel)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func resolve(_ credential: CoordinatorCredential, label: String) async throws {
        do {
            let account = try await client.account(at: endpoint, credential: credential)
            try Task.checkCancellation()
            phase = .paired(account)
        } catch CoordinatorError.unauthorized {
            try Task.checkCancellation()
            try await store.remove(origin: endpoint.baseURL, account: label)
            throw CoordinatorError.unauthorized
        }
    }
}
