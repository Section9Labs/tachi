import Foundation

struct Workspace: Decodable, Identifiable, Hashable, Sendable {
    enum Role: String, Decodable, Sendable {
        case owner, member
    }

    let id: String
    let role: Role

    var title: String { "Workspace \(id.prefix(8))" }

    enum CodingKeys: String, CodingKey {
        case id = "workspace_id"
        case role
    }

    static func canonicalID(_ value: String) -> String? { UUID(uuidString: value)?.uuidString.lowercased() }
}

struct WorkspaceMessage: Decodable, Identifiable, Sendable {
    let id: String
    let text: String
    let authorID: String
    let recipientID: String?

    enum CodingKeys: String, CodingKey {
        case id = "message_id"
        case text
        case authorID = "author_id"
        case recipientID = "recipient_id"
    }
}

struct WorkspaceClient: Sendable {
    struct Draft {
        let id = UUID().uuidString.lowercased()
        let text: String
        let recipientID: String?
    }

    private struct Workspaces: Decodable { let workspaces: [Workspace] }
    private struct Messages: Decodable { let messages: [WorkspaceMessage] }
    private struct Invitation: Decodable { let invitation: String }
    private struct Revocation: Decodable { let revoked: Bool }
    private struct Acknowledgement: Decodable { let message_id: String }

    let client: CoordinatorClient
    let endpoint: CoordinatorEndpoint
    let credential: CoordinatorCredential

    func list() async throws -> [Workspace] {
        let response: Workspaces = try await request(path: "v1/workspaces")
        guard response.workspaces.allSatisfy({ Workspace.canonicalID($0.id) == $0.id }) else {
            throw CoordinatorError.unexpectedResponse
        }
        return response.workspaces
    }

    func create(id: String) async throws -> Workspace {
        guard Workspace.canonicalID(id) == id else { throw CoordinatorError.unexpectedResponse }
        let workspace: Workspace = try await request(path: "v1/workspaces", body: ["workspace_id": id], expecting: 201)
        guard workspace.id == id, workspace.role == .owner else { throw CoordinatorError.unexpectedResponse }
        return workspace
    }

    func invite(workspaceID: String, recipientID: String) async throws -> String {
        let response: Invitation = try await request(
            path: path(workspaceID, "invitations"), body: ["recipient_id": recipientID], expecting: 201
        )
        guard !response.invitation.isEmpty else { throw CoordinatorError.unexpectedResponse }
        return response.invitation
    }

    func join(workspaceID: String, invitation: String) async throws -> Workspace {
        let workspace: Workspace = try await request(
            path: path(workspaceID, "redeem"), body: ["invitation": invitation]
        )
        guard workspace.id == workspaceID, workspace.role == .member else { throw CoordinatorError.unexpectedResponse }
        return workspace
    }

    func revoke(workspaceID: String, recipientID: String) async throws {
        let response: Revocation = try await request(
            path: path(workspaceID, "revocations"), body: ["recipient_id": recipientID]
        )
        guard response.revoked else { throw CoordinatorError.unexpectedResponse }
    }

    func messages(workspaceID: String) async throws -> [WorkspaceMessage] {
        let response: Messages = try await request(path: path(workspaceID, "messages"))
        return response.messages
    }

    func send(_ draft: Draft, workspaceID: String) async throws {
        var fields = ["message_id": draft.id, "text": draft.text]
        fields["recipient_id"] = draft.recipientID
        let response: Acknowledgement = try await request(path: path(workspaceID, "messages"), body: fields, expecting: 201)
        guard response.message_id == draft.id else { throw CoordinatorError.unexpectedResponse }
    }

    private func path(_ workspaceID: String, _ route: String) throws -> String {
        guard Workspace.canonicalID(workspaceID) == workspaceID else { throw CoordinatorError.unexpectedResponse }
        return "v1/workspaces/\(workspaceID)/\(route)"
    }

    private func request<Response: Decodable>(
        path: String, body: [String: String]? = nil, expecting statusCode: Int = 200
    ) async throws -> Response {
        let data = try body.map { try JSONEncoder().encode($0) }
        return try await client.authenticated(
            url: endpoint.route(path), credential: credential, body: data, expecting: statusCode
        )
    }
}
