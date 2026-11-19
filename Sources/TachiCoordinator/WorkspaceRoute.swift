import Foundation
import NIOHTTP1
import TachiAccounts
import TachiRuntime

enum WorkspaceRoute {
    static let root = "/v1/workspaces"
    private static let prefix = "workspace/"

    static func matches(_ uri: String) -> Bool { uri == root || uri.hasPrefix(root + "/") }

    static func reply(_ head: HTTPRequestHead, body: Data, headerError: Reply?, client: ClientPrincipal,
                      accounts: AccountStore, history: WorkspaceHistory) async throws -> Reply {
        if let headerError { return headerError }
        let human = client.humanID, device = client.clientID
        let principal = QueuePrincipal(humanID: human, clientID: device)
        func summary(_ id: String, _ role: String) -> [String: String] { ["workspace_id": id, "role": role] }
        do {
            if head.uri == root {
                switch head.method {
                case .GET:
                    let memberships = try accounts.listTeams(humanID: human, clientID: device)
                    let workspaces = memberships.compactMap { team -> [String: String]? in
                        guard team.teamID.hasPrefix(prefix) else { return nil }
                        let id = String(team.teamID.dropFirst(prefix.count))
                        return validID(id) ? summary(id, team.role) : nil
                    }
                    return try encoded(.ok, ["workspaces": workspaces])
                case .POST:
                    let fields = try input(body, required: ["workspace_id"])
                    let id = fields["workspace_id"]!
                    guard validID(id) else { throw QueueError.invalidInput }
                    try accounts.authorizeClient(humanID: human, clientID: device, scope: "teams:manage")
                    let team = prefix + id
                    do { try accounts.createTeam(humanID: human, clientID: device, teamID: team) }
                    catch AccountsError.denied {
                        guard try accounts.teamRole(teamID: team, humanID: human) != nil else { throw QueueError.notFound }
                        _ = try accounts.authorizeTeam(humanID: human, clientID: device, teamID: team, scope: "teams:manage")
                    }
                    return try encoded(.created, summary(id, "owner"))
                default: return Reply(.methodNotAllowed, error: "method_not_allowed")
                }
            }

            let parts = head.uri.dropFirst(root.count + 1).split(separator: "/", omittingEmptySubsequences: false)
            guard (parts.count == 2 || (parts.count == 3 && parts[1] == "artifacts")), validID(String(parts[0])) else { throw QueueError.notFound }
            let id = String(parts[0]), team = prefix + id
            if parts[1] == "redeem", head.method == .POST {
                let fields = try input(body, required: ["invitation"])
                let member = try accounts.acceptInvitation(humanID: human, clientID: device,
                                                           invitation: fields["invitation"]!, expectedTeamID: team)
                return try encoded(.ok, summary(id, member.role))
            }
            guard try accounts.teamMembership(teamID: team, humanID: human) != nil else { throw QueueError.notFound }
            if parts[1] == "artifacts" {
                return try await WorkspaceArtifactRoute.reply(head.method, id: parts.count == 3 ? String(parts[2]) : nil,
                                                               team: team, principal: principal, body: body, history: history)
            }
            switch (head.method, parts[1]) {
            case (.POST, "invitations"):
                let fields = try input(body, required: ["recipient_id"])
                let invitation = try accounts.inviteMember(humanID: human, clientID: device, teamID: team,
                                                           recipientID: fields["recipient_id"]!)
                return try encoded(.created, ["invitation": invitation])
            case (.POST, "revocations"):
                let fields = try input(body, required: ["recipient_id"])
                try accounts.revokeMember(humanID: human, clientID: device, teamID: team, recipientID: fields["recipient_id"]!)
                return try encoded(.ok, ["revoked": true])
            case (.POST, "messages"):
                let fields = try input(body, required: ["message_id", "text"], optional: ["recipient_id"])
                let message = fields["message_id"]!
                guard validID(message) else { throw QueueError.invalidInput }
                try await history.post(team: team, principal: principal, id: message, text: fields["text"]!,
                                       recipient: fields["recipient_id"])
                return try encoded(.created, ["message_id": message])
            case (.GET, "export"):
                var export = try await history.export(team: team, principal: principal, sha256: WorkspaceArtifactRoute.digest)
                export["workspace_id"] = .string(id)
                let encoder = JSONEncoder()
                encoder.outputFormatting = .withoutEscapingSlashes
                return try Reply(.ok, encoder.encode(export))
            case (.GET, "messages"):
                return try await encoded(.ok, ["messages": history.messages(team: team, principal: principal)])
            default: throw QueueError.notFound
            }
        } catch WorkspaceArtifactError.limitExceeded { return Reply(.payloadTooLarge, error: "artifact_limit") }
        catch WorkspaceExportError.limitExceeded { return Reply(.payloadTooLarge, error: "export_limit") }
        catch QueueError.denied { return Reply(.forbidden, error: "forbidden") }
        catch AccountsError.denied { return Reply(.forbidden, error: "forbidden") }
        catch QueueError.notFound { return Reply(.notFound, error: "not_found") }
        catch QueueError.invalidInput { return Reply(.badRequest, error: "invalid_request") }
        catch QueueError.conflict { return Reply(.conflict, error: "conflict") }
    }

    private static func input(_ data: Data, required: Set<String>, optional: Set<String> = []) throws -> [String: String] {
        guard let values = try? JSONDecoder().decode([String: String].self, from: data),
              required.isSubset(of: values.keys), Set(values.keys).isSubset(of: required.union(optional)) else {
            throw QueueError.invalidInput
        }
        return values
    }

    private static func encoded(_ status: HTTPResponseStatus, _ value: some Encodable) throws -> Reply {
        try Reply(status, JSONEncoder().encode(value))
    }

    static func validID(_ id: String) -> Bool { UUID(uuidString: id)?.uuidString.lowercased() == id }
}
