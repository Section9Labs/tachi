import CryptoKit
import Foundation

struct WorkspaceArtifact: Decodable, Identifiable, Sendable {
    enum Audience: String, Decodable, Sendable {
        case room, direct
    }

    enum Origin: String, Decodable, Sendable {
        case humanUpload = "human_upload"
        case syntheticFixture = "synthetic_fixture"

        var label: String {
            switch self {
            case .humanUpload: "Human upload"
            case .syntheticFixture: "Synthetic fixture"
            }
        }
    }

    let id: String
    let name: String
    let contentType: String
    let size: Int
    let digest: String
    let audience: Audience
    let recipientID: String?
    let origin: Origin
    let authorID: String
    let sourceMessageID: String?
    let sourceTaskID: String?

    enum CodingKeys: String, CodingKey {
        case id = "artifact_id"
        case name
        case contentType = "content_type"
        case size = "size_bytes"
        case digest = "sha256"
        case audience
        case recipientID = "recipient_id"
        case origin
        case authorID = "author_id"
        case sourceMessageID = "source_message_id"
        case sourceTaskID = "source_task_id"
    }

    var isValid: Bool {
        Workspace.canonicalID(id) == id
            && WorkspaceArtifactUpload.isValidName(name)
            && WorkspaceArtifactUpload.isValidContentType(contentType)
            && (0...WorkspaceArtifactUpload.byteLimit).contains(size)
            && digest.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil
            && (audience == .room) == (recipientID == nil)
    }
}

struct WorkspaceArtifactUpload: Sendable {
    enum Source: Sendable {
        case message(String), task(String)
    }

    static let byteLimit = 1_048_576
    let id = UUID().uuidString.lowercased()
    let name: String
    let contentType: String
    let bytes: Data
    let recipientID: String?
    let fixture: Bool
    let source: Source?

    static func isValidName(_ name: String) -> Bool {
        (1...255).contains(name.utf8.count)
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func isValidContentType(_ value: String) -> Bool {
        guard value.utf8.count <= 127 else { return false }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        let punctuation = "!#$%&'*+-.^_\u{60}|~".utf8
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy { byte in
                (65...90).contains(byte) || (97...122).contains(byte)
                    || (48...57).contains(byte) || punctuation.contains(byte)
            }
        }
    }

    func encoded() throws -> Data {
        guard bytes.count <= Self.byteLimit else { throw WorkspaceArtifactError.sizeLimit }
        guard Self.isValidName(name) else { throw WorkspaceArtifactError.invalidName }
        guard Self.isValidContentType(contentType) else { throw WorkspaceArtifactError.invalidContentType }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return try encoder.encode(Envelope(upload: self))
    }

    private struct Envelope: Encodable {
        let artifact_id: String
        let name: String
        let content_type: String
        let content_base64: String
        let audience: String
        let recipient_id: String?
        let fixture: Bool
        let source_message_id: String?
        let source_task_id: String?

        init(upload: WorkspaceArtifactUpload) {
            artifact_id = upload.id
            name = upload.name
            content_type = upload.contentType
            content_base64 = upload.bytes.base64EncodedString()
            audience = upload.recipientID == nil ? "room" : "direct"
            recipient_id = upload.recipientID
            fixture = upload.fixture
            if case .message(let id) = upload.source { source_message_id = id } else { source_message_id = nil }
            if case .task(let id) = upload.source { source_task_id = id } else { source_task_id = nil }
        }
    }
}

enum WorkspaceArtifactError: LocalizedError, Equatable {
    case sizeLimit, invalidName, invalidContentType, integrity

    var errorDescription: String? {
        switch self {
        case .sizeLimit: "Choose a file up to 1 MiB."
        case .invalidName: "Choose a file with a valid name of up to 255 UTF-8 bytes."
        case .invalidContentType: "The file’s media type is invalid."
        case .integrity: "Couldn’t verify the artifact’s size or SHA-256 digest."
        }
    }
}

struct WorkspaceArtifactClient: Sendable {
    private struct Collection: Decodable { let artifacts: [WorkspaceArtifact] }

    private struct Download: Decodable {
        let metadata: WorkspaceArtifact
        let base64: String

        private enum CodingKeys: String, CodingKey { case contentBase64 = "content_base64" }

        init(from decoder: any Decoder) throws {
            metadata = try WorkspaceArtifact(from: decoder)
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            base64 = try fields.decode(String.self, forKey: .contentBase64)
        }

        func verifiedBytes(matching expected: WorkspaceArtifact) throws -> Data {
            let limit = ((WorkspaceArtifactUpload.byteLimit + 2) / 3) * 4
            guard metadata.isValid, metadata.id == expected.id, metadata.size == expected.size,
                  metadata.digest == expected.digest, base64.utf8.count <= limit,
                  let bytes = Data(base64Encoded: base64), bytes.base64EncodedString() == base64,
                  bytes.count == metadata.size, Self.digest(bytes) == metadata.digest else {
                throw WorkspaceArtifactError.integrity
            }
            return bytes
        }

        static func digest(_ bytes: Data) -> String {
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
    }

    let workspace: WorkspaceClient

    func list(workspaceID: String) async throws -> [WorkspaceArtifact] {
        let path = try artifactsPath(workspaceID)
        let response: Collection = try await get(path)
        guard response.artifacts.allSatisfy(\.isValid) else { throw CoordinatorError.unexpectedResponse }
        return response.artifacts
    }

    func upload(_ input: WorkspaceArtifactUpload, workspaceID: String) async throws -> WorkspaceArtifact {
        let path = try artifactsPath(workspaceID)
        let result: WorkspaceArtifact = try await workspace.client.authenticated(
            url: workspace.endpoint.route(path), credential: workspace.credential,
            body: input.encoded(), expecting: 201
        )
        guard result.isValid, result.id == input.id, result.size == input.bytes.count,
              result.name.utf8.elementsEqual(input.name.utf8), result.contentType == input.contentType,
              result.recipientID.map({ Array($0.utf8) }) == input.recipientID.map({ Array($0.utf8) }),
              result.origin == (input.fixture ? .syntheticFixture : .humanUpload),
              result.digest == Download.digest(input.bytes) else {
            throw WorkspaceArtifactError.integrity
        }
        return result
    }

    func download(_ artifact: WorkspaceArtifact, workspaceID: String) async throws -> Data {
        let path = try artifactsPath(workspaceID)
        guard artifact.isValid else { throw CoordinatorError.unexpectedResponse }
        let response: Download = try await get("\(path)/\(artifact.id)")
        return try response.verifiedBytes(matching: artifact)
    }

    private func artifactsPath(_ workspaceID: String) throws -> String {
        guard Workspace.canonicalID(workspaceID) == workspaceID else { throw CoordinatorError.unexpectedResponse }
        return "v1/workspaces/\(workspaceID)/artifacts"
    }

    private func get<Response: Decodable>(_ path: String) async throws -> Response {
        try await workspace.client.authenticated(url: workspace.endpoint.route(path), credential: workspace.credential)
    }
}
