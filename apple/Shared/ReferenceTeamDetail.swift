import SwiftUI

struct ReferenceTeamDetail: View {
    let api: ReferenceTeamClient
    let account: CoordinatorAccount

    @State private var team: ReferenceTeam
    @State private var messages: [ReferenceMessage] = []
    @State private var pending: [ReferenceOutbox.Pending] = []
    @State private var draftText = ""
    @State private var audience = ReferenceAudience.room
    @State private var mentions: Set<ReferenceAudience> = []
    @State private var reply: ReferenceMessage?
    @State private var turnLimit: Int
    @State private var busy = false
    @State private var accessLost = false
    @State private var errorMessage: String?

    private let outbox = ReferenceOutbox.shared

    init(api: ReferenceTeamClient, account: CoordinatorAccount, initialTeam: ReferenceTeam) {
        self.api = api
        self.account = account
        _team = State(initialValue: initialTeam)
        _turnLimit = State(initialValue: initialTeam.turnLimit)
    }

    private var outboxAccount: ReferenceOutbox.Account {
        ReferenceOutbox.Account(origin: api.endpoint.baseURL, humanID: account.humanID, clientID: account.clientID)
    }

    private var canPost: Bool { !accessLost && account.scopes.contains("messages:send") && team.runState.isActive }
    private var canManage: Bool { !accessLost && account.scopes.contains("teams:manage") && team.runState.isActive }
    private var draftIsValid: Bool {
        !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draftText.unicodeScalars.count <= 4000
    }
    private var destination: ReferenceAudience {
        if let reply, reply.audience != .room { return reply.audience }
        return audience
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                runControls

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .accessibilityIdentifier("reference-team-error")
                }

                if canPost { composer }
                if !pending.isEmpty { pendingMessages }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Messages").font(.headline).accessibilityAddTraits(.isHeader)
                    if messages.isEmpty { Text("No messages yet.").foregroundStyle(.secondary) }
                    ForEach(messages) { message in
                        messageRow(message)
                        Divider()
                    }
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding()
        }
        .navigationTitle(team.title)
        .toolbar {
            Button("Refresh Team") { Task { await refresh() } }
                .disabled(busy || accessLost)
        }
        .task { await refresh() }
    }

    private var runControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Team run").font(.headline).accessibilityAddTraits(.isHeader)
            Text("\(team.runState.rawValue.capitalized) · \(team.turnsUsed) of \(team.turnLimit) turns")
                .accessibilityIdentifier("reference-run-state")
            if canManage {
                interventionButtons
                Stepper("Turn limit \(turnLimit)", value: $turnLimit, in: 1...1000)
                if turnLimit != team.turnLimit {
                    Button("Apply Turn Limit") { changeRun(team.runState, turnLimit: turnLimit) }
                        .disabled(busy)
                }
            }
        }
    }

    @ViewBuilder
    private var interventionButtons: some View {
        if team.runState == .running {
            Button("Pause Run") { changeRun(.paused) }.disabled(busy)
        } else {
            Button("Resume Run") { changeRun(.running) }.disabled(busy)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New message").font(.headline).accessibilityAddTraits(.isHeader)
            if let reply, reply.audience != .room {
                Text("Direct reply · \(destination.title)")
            } else {
                Picker("Audience", selection: $audience) {
                    ForEach(ReferenceAudience.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            if destination == .room {
                Toggle("Mention Lead", isOn: mention(.lead))
                Toggle("Mention Peer", isOn: mention(.peer))
                Text("Room messages schedule work for the assistants you mention.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let reply {
                HStack {
                    Text("Replying to \(reply.text)").lineLimit(1)
                    Button("Clear Reply") { self.reply = nil }
                }
            }

            TextField("Team message", text: $draftText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .accessibilityIdentifier("reference-message-draft")
                .disabled(busy)
            Button("Send Message", action: send)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!draftIsValid || busy)
        }
    }

    private var pendingMessages: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pending on This Device").font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(pending) { item in
                VStack(alignment: .leading) {
                    Text(item.draft.text)
                    Text(item.draft.audience.title).font(.caption).foregroundStyle(.secondary)
                    if item.rejected {
                        Text("The coordinator declined this message.").font(.caption)
                        Button("Remove Rejected Message") {
                            Task {
                                await run {
                                    try await outbox.acknowledge(item.id, account: outboxAccount, teamID: team.id)
                                    pending.removeAll { $0.id == item.id }
                                }
                            }
                        }
                        .disabled(busy)
                    }
                }
            }
            if pending.contains(where: { !$0.rejected }) {
                Button("Retry Pending Messages") {
                    Task {
                        await run {
                            try await flush()
                            try await load()
                        }
                    }
                }
                .disabled(busy || !account.scopes.contains("messages:send"))
            }
        }
    }

    private func messageRow(_ message: ReferenceMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.text)
                .textSelection(.enabled)
            if let replyTo = message.replyTo, let parent = messages.first(where: { $0.id == replyTo }) {
                Text("Reply to \(parent.text)").font(.caption).lineLimit(1)
            }
            Text(audienceDescription(message)).font(.caption).foregroundStyle(.secondary)
            ForEach(message.deliveries, id: \.assistant) { delivery in
                if let result = delivery.result {
                    DisclosureGroup("\(delivery.assistant.capitalized) result") {
                        Text(result).textSelection(.enabled)
                    }
                } else {
                    Text("\(delivery.assistant.capitalized) · \(delivery.state.capitalized)")
                        .foregroundStyle(.secondary)
                }
            }
            if canPost { Button("Reply") { reply = message }.accessibilityLabel("Reply to \(message.text)") }
        }
    }

    private func audienceDescription(_ message: ReferenceMessage) -> String {
        let audience = "\(message.author.capitalized) · \(message.audience.title)"
        guard !message.mentions.isEmpty else { return audience }
        return "\(audience) · \(message.mentions.map(\.title).joined(separator: ", "))"
    }

    private func mention(_ value: ReferenceAudience) -> Binding<Bool> {
        Binding(get: { mentions.contains(value) }, set: { enabled in
            if enabled { mentions.insert(value) } else { mentions.remove(value) }
        })
    }

    private func changeRun(_ state: ReferenceRunState, turnLimit: Int? = nil) {
        Task {
            await run {
                team = try await api.intervene(teamID: team.id, state: state, turnLimit: turnLimit)
                self.turnLimit = team.turnLimit
                try await load()
            }
        }
    }

    private func send() {
        guard draftIsValid else { return }
        let draft = ReferenceDraft(
            messageID: UUID().uuidString, text: draftText, audience: destination,
            mentions: destination == .room ? [.lead, .peer].filter(mentions.contains) : nil, replyTo: reply?.id
        )
        Task {
            await run {
                try await outbox.enqueue(draft, account: outboxAccount, teamID: team.id)
                draftText = ""
                reply = nil
                try await flush()
                try await load()
            }
        }
    }

    private func flush() async throws {
        pending = try await outbox.pending(account: outboxAccount, teamID: team.id)
        for item in pending where !item.rejected {
            do {
                try await api.send(item.draft, teamID: team.id)
                try await outbox.acknowledge(item.id, account: outboxAccount, teamID: team.id)
                pending.removeAll { $0.id == item.id }
            } catch CoordinatorError.httpStatus(let code) where [400, 403, 404, 409, 413, 422].contains(code) {
                try await outbox.reject(item.id, account: outboxAccount, teamID: team.id)
                pending = try await outbox.pending(account: outboxAccount, teamID: team.id)
            }
        }
    }

    private func refresh() async {
        await run { try await load() }
    }

    private func load() async throws {
        pending = try await outbox.pending(account: outboxAccount, teamID: team.id)
        team = try await api.team(team.id)
        turnLimit = team.turnLimit
        messages = try await api.messages(teamID: team.id)
    }

    private func run(_ operation: () async throws -> Void) async {
        guard !busy, !accessLost else { return }
        busy = true
        defer { busy = false }
        do {
            try await operation()
            errorMessage = nil
        } catch is CancellationError {
        } catch CoordinatorError.unauthorized {
            messages = []
            pending = []
            accessLost = true
            errorMessage = CoordinatorError.unauthorized.errorDescription
        } catch CoordinatorError.httpStatus(403) {
            errorMessage = "This device’s coordinator account lacks permission for that action."
        } catch is CocoaError {
            errorMessage = "Couldn’t update pending messages on this device."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
