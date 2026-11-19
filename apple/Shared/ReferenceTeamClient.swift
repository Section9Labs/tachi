import Foundation

struct ReferenceTeam: Decodable, Identifiable, Sendable {
    let teamID: String
    let mode: String
    let assistants: [String]
    let runState: ReferenceRunState
    let turnLimit: Int
    let turnsUsed: Int

    var id: String { teamID }
    var title: String { "Team \(teamID.prefix(8))" }
}

enum ReferenceRunState: String, Codable, Sendable {
    case running, paused, completed, cancelled

    var isActive: Bool { self == .running || self == .paused }
}

enum ReferenceAudience: String, Codable, CaseIterable, Identifiable, Sendable {
    case room, lead, peer

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

struct ReferenceDraft: Codable, Equatable, Identifiable, Sendable {
    let messageID: String
    let text: String
    let audience: ReferenceAudience
    let mentions: [ReferenceAudience]?
    let replyTo: String?

    var id: String { messageID }
}

struct ReferenceMessage: Decodable, Identifiable, Sendable {
    struct Delivery: Decodable, Sendable {
        let assistant: String
        let state: String
        let result: String?
    }

    let messageID: String
    let author: String
    let audience: ReferenceAudience
    let mentions: [ReferenceAudience]
    let text: String
    let replyTo: String?
    let deliveries: [Delivery]

    var id: String { messageID }
}

struct ReferenceTeamClient: Sendable {
    private struct Teams: Decodable { let teams: [ReferenceTeam] }
    private struct Messages: Decodable { let messages: [ReferenceMessage] }
    private struct Acknowledgement: Decodable { let messageID: String }
    private struct Creation: Encodable {
        let creationID: String
        let turnLimit: Int
    }
    private struct Intervention: Encodable {
        let state: ReferenceRunState
        let turnLimit: Int?
    }

    let client: CoordinatorClient
    let endpoint: CoordinatorEndpoint
    let credential: CoordinatorCredential

    func teams() async throws -> [ReferenceTeam] {
        let response: Teams = try await request()
        return response.teams
    }

    func create(id: String, turnLimit: Int) async throws -> ReferenceTeam {
        try await request(body: JSONEncoder().encode(Creation(creationID: id, turnLimit: turnLimit)))
    }

    func team(_ id: String) async throws -> ReferenceTeam {
        try await request(teamID: id)
    }

    func messages(teamID: String) async throws -> [ReferenceMessage] {
        let response: Messages = try await request(teamID: teamID, section: "messages")
        return response.messages
    }

    func send(_ draft: ReferenceDraft, teamID: String) async throws {
        let response: Acknowledgement = try await request(
            teamID: teamID, section: "messages", body: JSONEncoder().encode(draft)
        )
        guard response.messageID == draft.messageID else { throw CoordinatorError.unexpectedResponse }
    }

    func intervene(teamID: String, state: ReferenceRunState, turnLimit: Int? = nil) async throws -> ReferenceTeam {
        try await request(
            teamID: teamID, section: "run", body: JSONEncoder().encode(Intervention(state: state, turnLimit: turnLimit))
        )
    }

    private func request<Response: Decodable>(
        teamID: String? = nil, section: String? = nil, body: Data? = nil
    ) async throws -> Response {
        var path = "v1/reference-teams"
        if let teamID {
            guard teamID.range(of: #"\A[a-f0-9]{32}\z"#, options: .regularExpression) != nil else {
                throw CoordinatorError.unexpectedResponse
            }
            path += "/\(teamID)"
        }
        if let section { path += "/\(section)" }
        return try await client.authenticated(url: endpoint.route(path), credential: credential, body: body)
    }
}
