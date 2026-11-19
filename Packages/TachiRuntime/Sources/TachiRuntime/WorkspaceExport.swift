import Foundation

public enum WorkspaceExportError: Error { case limitExceeded }

extension WorkspaceHistory {
    /// Materialize one complete export under the same SQLite lock as revocation and rejoin.
    public func export(team: String, principal: QueuePrincipal, sha256: @Sendable (Data) -> String) throws -> JSONObject {
        let messageLimit = 100, artifactLimit = 16, byteLimit = 4 * 1024 * 1024
        return try db.transaction {
            let audience = try readAudience(team: team, principal: principal)
            let messages = try visibleMessages(audience, limit: messageLimit + 1)
            guard messages.count <= messageLimit else { throw WorkspaceExportError.limitExceeded }
            let rows = try visibleArtifactRows(audience, limit: artifactLimit + 1)
            guard rows.count <= artifactLimit else { throw WorkspaceExportError.limitExceeded }

            var bytes = 0
            for row in rows {
                guard let size = try Int(row.required("size_bytes")), (0...WorkspaceArtifactUpload.byteLimit).contains(size)
                else { throw QueueError.corruptStore }
                bytes += size
            }
            guard bytes <= byteLimit else { throw WorkspaceExportError.limitExceeded }
            let artifacts = try rows.map { row in
                try JSONValue.object(verifiedArtifact(row.required("artifact"), audience: audience, sha256: sha256))
            }
            return ["messages": .array(messages.map(JSONValue.object)), "artifacts": .array(artifacts)]
        }
    }
}
