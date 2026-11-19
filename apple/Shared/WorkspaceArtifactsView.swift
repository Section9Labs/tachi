import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceArtifactsView: View {
    let api: WorkspaceArtifactClient
    let workspaceID: String
    let canUpload: Bool

    @State private var artifacts: [WorkspaceArtifact] = []
    @State private var busy = false
    @State private var accessLost = false
    @State private var errorMessage: String?
    @State private var showingImporter = false
    @State private var file: ImportedWorkspaceFile?
    @State private var direct = false
    @State private var recipient = ""
    @State private var fixture = false
    @State private var pending: WorkspaceArtifactUpload?
    @State private var uploadedName: String?

    private var canSubmit: Bool {
        file != nil && (!direct || !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        List {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
            }
            if !accessLost {
                if canUpload { uploadSection }
                artifactSection
            }
        }
        .navigationTitle("Artifacts")
        .toolbar {
            Button("Refresh Artifacts") { Task { await refresh() } }
                .disabled(busy || accessLost)
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.data]) { result in
            Task { await importFile(result) }
        }
        .task { await refresh() }
    }

    private var uploadSection: some View {
        Section("Upload File") {
            Button(file == nil ? "Choose File" : "Choose Another File") { showingImporter = true }
                .disabled(busy || pending != nil)
            if let file {
                Text(file.name)
                Text(ByteCountFormatter.string(fromByteCount: Int64(file.bytes.count), countStyle: .file))
                    .foregroundStyle(.secondary)
                Toggle("Direct artifact", isOn: $direct)
                    .disabled(busy || pending != nil)
                if direct {
                    TextField("Recipient human ID", text: $recipient)
                        .accessibilityIdentifier("artifact-recipient")
                        .disabled(busy || pending != nil)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                }
                Toggle("Synthetic fixture", isOn: $fixture)
                    .disabled(busy || pending != nil)
                Button(pending == nil ? "Upload Artifact" : "Retry Upload") { Task { await upload() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || (pending == nil && !canSubmit))
            }
            if let uploadedName {
                Text("\(uploadedName) uploaded.")
                    .accessibilityIdentifier("artifact-upload-status")
            }
        }
    }

    private var artifactSection: some View {
        Section("Workspace Artifacts") {
            if busy && artifacts.isEmpty {
                ProgressView("Checking artifacts…")
            } else if artifacts.isEmpty {
                Text("No artifacts yet.").foregroundStyle(.secondary)
            }
            ForEach(artifacts) { artifact in
                NavigationLink {
                    WorkspaceArtifactDetail(api: api, workspaceID: workspaceID, artifact: artifact)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(artifact.name)
                        Text("\(artifact.origin.label) · \(artifact.audience.rawValue.capitalized)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func refresh() async {
        await perform { artifacts = try await api.list(workspaceID: workspaceID) }
    }

    private func importFile(_ result: Result<URL, any Error>) async {
        await perform {
            file = try await ImportedWorkspaceFile.read(result.get())
            uploadedName = nil
        }
    }

    private func upload() async {
        guard let file, pending != nil || canSubmit else { return }
        await perform {
            let input = pending ?? WorkspaceArtifactUpload(
                name: file.name, contentType: file.contentType, bytes: file.bytes,
                recipientID: direct ? recipient : nil, fixture: fixture, source: nil
            )
            pending = input
            let receipt: WorkspaceArtifact
            do {
                receipt = try await api.upload(input, workspaceID: workspaceID)
            } catch CoordinatorError.httpStatus(let code) where [400, 403, 413].contains(code) {
                pending = nil
                throw CoordinatorError.httpStatus(code)
            }
            pending = nil
            self.file = nil
            uploadedName = receipt.name
            artifacts = try await api.list(workspaceID: workspaceID)
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
        } catch CoordinatorError.unauthorized {
            clearArtifacts()
            errorMessage = CoordinatorError.unauthorized.errorDescription
        } catch CoordinatorError.httpStatus(404) {
            clearArtifacts()
            errorMessage = "Artifacts are unavailable in this workspace."
        } catch CoordinatorError.httpStatus(413) {
            errorMessage = "The file or workspace exceeds the artifact storage limit."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearArtifacts() {
        artifacts = []
        file = nil
        pending = nil
        uploadedName = nil
        accessLost = true
    }
}

private struct ImportedWorkspaceFile: Sendable {
    let name: String
    let contentType: String
    let bytes: Data

    static func read(_ url: URL) async throws -> Self {
        let scope = url.startAccessingSecurityScopedResource()
        defer { if scope { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        guard WorkspaceArtifactUpload.isValidName(name) else { throw WorkspaceArtifactError.invalidName }
        let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType?.preferredMIMEType
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var bytes = Data()
        while bytes.count <= WorkspaceArtifactUpload.byteLimit {
            let remaining = WorkspaceArtifactUpload.byteLimit + 1 - bytes.count
            guard let chunk = try file.read(upToCount: min(64 * 1024, remaining)), !chunk.isEmpty else { break }
            bytes.append(chunk)
        }
        guard bytes.count <= WorkspaceArtifactUpload.byteLimit else { throw WorkspaceArtifactError.sizeLimit }
        return Self(name: name, contentType: type ?? "application/octet-stream", bytes: bytes)
    }
}

private struct WorkspaceArtifactDetail: View {
    let api: WorkspaceArtifactClient
    let workspaceID: String
    let artifact: WorkspaceArtifact

    @State private var busy = false
    @State private var verified = false
    @State private var errorMessage: String?
    @State private var document: VerifiedArtifactDocument?
    @State private var showingExporter = false

    var body: some View {
        Form {
            Section("Artifact Details") {
                LabeledContent("Provenance", value: artifact.origin.label)
                LabeledContent("Uploaded By", value: artifact.authorID)
                LabeledContent("Audience", value: artifact.recipientID.map { "Direct to \($0)" } ?? "Room")
                LabeledContent("Media Type", value: artifact.contentType)
                LabeledContent("Bytes", value: artifact.size.formatted())
                if let source = artifact.sourceMessageID {
                    LabeledContent("Source Message", value: source)
                }
                if let source = artifact.sourceTaskID {
                    LabeledContent("Source Task", value: source)
                }
            }
            Section {
                if verified {
                    Label("Verified size and SHA-256", systemImage: "checkmark.circle")
                        .accessibilityIdentifier("artifact-verification-status")
                    Text(artifact.digest).font(.caption.monospaced()).textSelection(.enabled)
                }
                Button("Verify and Export") { Task { await export() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                if busy { ProgressView("Verifying artifact…") }
                if let errorMessage { Label(errorMessage, systemImage: "exclamationmark.circle") }
            }
        }
        .navigationTitle(artifact.name)
        .fileExporter(
            isPresented: $showingExporter, document: document,
            contentType: .data,
            defaultFilename: artifact.name
        ) { result in
            document = nil
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
    }

    private func export() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        errorMessage = nil
        verified = false
        do {
            let bytes = try await api.download(artifact, workspaceID: workspaceID)
            document = VerifiedArtifactDocument(bytes: bytes)
            verified = true
            showingExporter = true
        } catch CoordinatorError.httpStatus(404) {
            errorMessage = "This artifact is unavailable to your account."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct VerifiedArtifactDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let bytes: Data

    init(bytes: Data) { self.bytes = bytes }

    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.bytes = bytes
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: bytes)
    }
}
