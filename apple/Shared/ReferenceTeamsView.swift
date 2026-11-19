import SwiftUI

struct ReferenceTeamsView: View {
    let api: ReferenceTeamClient
    let account: CoordinatorAccount

    @Environment(\.dismiss) private var dismiss
    @State private var teams: [ReferenceTeam] = []
    @State private var selection: String?
    @State private var pendingCreationID: String?
    @State private var busy = false
    @State private var accessLost = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Close Reference Teams") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            Divider()
            teamNavigation
        }
        #if os(macOS)
        .frame(minWidth: 780, minHeight: 580)
        #endif
        .task { await refresh() }
    }

    private var teamNavigation: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(teams) { team in
                        NavigationLink(value: team.id) {
                            Text(team.title)
                        }
                    }
                } header: {
                    Text("Teams")
                }

                if let errorMessage {
                    Text(errorMessage)
                } else if busy && teams.isEmpty {
                    ProgressView("Loading teams…")
                } else if teams.isEmpty {
                    Text("No reference teams yet.")
                        .foregroundStyle(.secondary)
                }

                if account.scopes.contains("teams:manage") {
                    Button("Create Team") { Task { await create() } }
                        .disabled(busy || accessLost)
                }
                Button("Refresh Teams") { Task { await refresh() } }
                    .disabled(busy || accessLost)
            }
            .navigationTitle("Reference Teams")
        } detail: {
            if let team = teams.first(where: { $0.id == selection }) {
                ReferenceTeamDetail(api: api, account: account, initialTeam: team)
                    .id(team.id)
            } else {
                ContentUnavailableView("Select a Team", systemImage: "person.2", description: Text("Reference assistants return synthetic results for testing."))
            }
        }
    }

    private func refresh() async {
        await run {
            teams = try await api.teams()
            if !teams.contains(where: { $0.id == selection }) { selection = nil }
        }
    }

    private func create() async {
        await run {
            let id = pendingCreationID ?? UUID().uuidString
            pendingCreationID = id
            let newTeam = try await api.create(id: id, turnLimit: 12)
            pendingCreationID = nil
            if !teams.contains(where: { $0.id == newTeam.id }) { teams.append(newTeam) }
            selection = newTeam.id
        }
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
            teams = []
            selection = nil
            accessLost = true
            errorMessage = CoordinatorError.unauthorized.errorDescription
        } catch CoordinatorError.httpStatus(404) {
            errorMessage = "This coordinator hasn’t enabled reference teams."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
