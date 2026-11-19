import SwiftUI

struct SoloRoutinesView: View {
    let api: SoloRoutineClient
    let account: CoordinatorAccount

    @Environment(\.dismiss) private var dismiss
    @State private var routines: [SoloRoutine] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Checking connected routines…")
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Couldn’t Load Routines", systemImage: "exclamationmark.circle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Refresh Routines") { Task { await load() } }
                    }
                } else if routines.isEmpty {
                    ContentUnavailableView {
                        Label("No Connected Routines", systemImage: "person.crop.circle")
                    } description: {
                        Text("Ask your coordinator operator to connect a Grok Bot routine for your account.")
                    } actions: {
                        Button("Refresh Routines") { Task { await load() } }
                    }
                } else {
                    List(routines) { routine in
                        NavigationLink {
                            SoloRoutineView(api: api, account: account, routine: routine)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(routine.id)
                                Text("Grok Bot routine")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Solo Assistants")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: { dismiss() })
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 460)
        #endif
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            routines = try await api.routines()
            errorMessage = nil
        } catch is CancellationError {
        } catch CoordinatorError.httpStatus(404) {
            errorMessage = "Solo routines are unavailable on this coordinator."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
