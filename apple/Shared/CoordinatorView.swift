import SwiftUI

struct CoordinatorView: View {
    private enum ConnectionState {
        case disconnected
        case connecting
        case connected(CoordinatorStatus)
        case failed(String)

        var isConnecting: Bool {
            if case .connecting = self { return true }
            return false
        }
    }

    private static let client = CoordinatorClient()

    @AppStorage("coordinatorURL") private var savedURL = CoordinatorEndpoint.defaultURL
    @State private var input = CoordinatorEndpoint.defaultURL
    @State private var connection = ConnectionState.disconnected
    @FocusState private var urlIsFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connect to Tachi")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("Enter the address of your coordinator to check if it’s ready.")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Coordinator URL")
                        .font(.headline)
                        .accessibilityHidden(true)
                    TextField("Coordinator URL", text: coordinatorURL, prompt: Text("https://tachi.example.com"))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Coordinator URL")
                        .accessibilityIdentifier("coordinator-url")
                        .focused($urlIsFocused)
                        .disabled(connection.isConnecting)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                        .onSubmit(connect)
                }

                Button("Connect", action: connect)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(connection.isConnecting)

                Divider()
                connectionStatus
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("connection-status")

                if let endpoint = try? CoordinatorEndpoint(input), endpoint.baseURL.absoluteString == savedURL {
                    Divider()
                    CoordinatorAccountView(endpoint: endpoint, client: Self.client)
                        .id(endpoint.baseURL)
                }
            }
            .frame(maxWidth: 440, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .onAppear { input = savedURL }
    }

    private var coordinatorURL: Binding<String> {
        Binding(get: { input }, set: { value in
            input = value
            connection = .disconnected
        })
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch connection {
        case .disconnected:
            Label("Not connected", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .connecting:
            ProgressView("Connecting…")
        case .connected(let status):
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text("Connected")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .font(.headline)
                Text("Coordinator ready · Protocol \(status.protocolVersion)")
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text("Connection failed")
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                }
                .font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func connect() {
        guard !connection.isConnecting else { return }
        let endpoint: CoordinatorEndpoint
        do {
            endpoint = try CoordinatorEndpoint(input)
        } catch {
            connection = .failed(error.localizedDescription)
            return
        }

        urlIsFocused = false
        input = endpoint.baseURL.absoluteString
        savedURL = input
        connection = .connecting
        Task {
            do {
                connection = .connected(try await Self.client.status(at: endpoint))
            } catch is CancellationError {
                connection = .disconnected
            } catch {
                connection = .failed(error.localizedDescription)
            }
        }
    }
}
