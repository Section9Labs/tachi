import CSoloDigest
import Foundation
import NIOHTTP1
import TachiRuntime

enum WorkspaceArtifactRoute {
    // JSONEncoder may escape every slash in a 1 MiB file's base64 representation.
    static let envelopeLimit = 3 * 1024 * 1024

    static func isCollection(_ uri: String) -> Bool {
        let prefix = WorkspaceRoute.root + "/"
        guard uri.hasPrefix(prefix) else { return false }
        let parts = uri.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && WorkspaceRoute.validID(String(parts[0])) && parts[1] == "artifacts"
    }

    static func reply(_ method: HTTPMethod, id: String?, team: String, principal: QueuePrincipal,
                      body: Data, history: WorkspaceHistory) async throws -> Reply {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        switch (method, id) {
        case (.GET, nil):
            return try await Reply(.ok, encoder.encode(["artifacts": history.artifacts(team: team, principal: principal)]))
        case (.GET, let id?):
            guard WorkspaceRoute.validID(id) else { throw QueueError.notFound }
            let result = try await history.artifact(team: team, principal: principal, id: id, sha256: digest)
            return try Reply(.ok, encoder.encode(result))
        case (.POST, nil):
            let result = try await history.shareArtifact(upload(body), team: team, principal: principal, sha256: digest)
            return try Reply(.created, encoder.encode(result))
        default:
            return Reply(.methodNotAllowed, error: "method_not_allowed")
        }
    }

    static func digest(_ data: Data) -> String {
        var output = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { solo_digest($0.baseAddress, $0.count, &output) }
        return output.map { String(format: "%02x", $0) }.joined()
    }

    private static func upload(_ data: Data) throws -> WorkspaceArtifactUpload {
        let keys: Set<String> = ["artifact_id","name","content_type","content_base64","audience","recipient_id",
                                 "fixture","source_message_id","source_task_id"]
        guard let fields = try? JSONDecoder().decode(JSONObject.self, from: data), Set(fields.keys).isSubset(of: keys),
              case let .string(id) = fields["artifact_id"], case let .string(name) = fields["name"],
              case let .string(type) = fields["content_type"], case let .string(base64) = fields["content_base64"],
              case let .string(audience) = fields["audience"], case let .bool(fixture) = fields["fixture"] ?? .bool(false)
        else { throw QueueError.invalidInput }
        func optional(_ key: String) throws -> String? {
            guard let field = fields[key] else { return nil }
            guard case let .string(value) = field, !value.isEmpty else { throw QueueError.invalidInput }
            return value
        }
        let recipient = try optional("recipient_id")
        guard audience == (recipient == nil ? "room" : "direct") else { throw QueueError.invalidInput }
        guard base64.utf8.count <= ((WorkspaceArtifactUpload.byteLimit + 2) / 3) * 4 else {
            throw WorkspaceArtifactError.limitExceeded
        }
        guard let bytes = Data(base64Encoded: base64), bytes.base64EncodedString() == base64 else { throw QueueError.invalidInput }
        return try WorkspaceArtifactUpload(id: id, name: name, contentType: type, bytes: bytes, recipient: recipient,
                                           sourceMessage: optional("source_message_id"), sourceTask: optional("source_task_id"),
                                           fixture: fixture)
    }
}
