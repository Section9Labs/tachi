import Foundation

struct WorkspaceAssistant: Decodable, Identifiable, Sendable {
    let id: String
    let provider: String
    let capabilities: [String]
    let nativeSessionObserved: Bool

    enum CodingKeys: String, CodingKey {
        case id = "assistant_id"
        case provider, capabilities
        case nativeSessionObserved = "native_session_observed"
    }

    var isSupported: Bool {
        Workspace.canonicalID(id) == id && provider == "grok-bot"
            && capabilities == ["task"] && !nativeSessionObserved
    }
}

struct WorkspaceAssignment: Decodable, Identifiable, Sendable {
    enum State: String, Decodable, Sendable {
        case queued, active, uncertain, failed, denied, blocked

        var holdsRoutine: Bool { self == .queued || self == .active || self == .uncertain }
    }

    let id: String
    let assistantID: String
    let authorID: String
    let text: String
    let state: State
    let nativeResultAvailable: Bool
    let result: String?

    enum CodingKeys: String, CodingKey {
        case id = "assignment_id"
        case assistantID = "assistant_id"
        case authorID = "author_id"
        case text, state, result
        case nativeResultAvailable = "native_result_available"
    }

    var isValid: Bool {
        Workspace.canonicalID(id) == id && Workspace.canonicalID(assistantID) == assistantID
            && !nativeResultAvailable && result == nil
    }
}

struct WorkspaceAssistantClient: Sendable {
    struct Draft: Encodable, Identifiable {
        let id = UUID().uuidString.lowercased()
        let assistantID: String
        let text: String

        enum CodingKeys: String, CodingKey {
            case id = "assignment_id"
            case assistantID = "assistant_id"
            case text
        }

        static func validText(_ text: String) -> Bool {
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.unicodeScalars.count <= 4_000
        }
    }

    private struct Assistants: Decodable { let assistants: [WorkspaceAssistant] }
    private struct Assignments: Decodable { let assignments: [WorkspaceAssignment] }
    private struct Revocation: Decodable { let revoked: Bool }

    private struct BindingRequest: Encodable {
        let routineID: String
        let allowRoomAssignments = true

        enum CodingKeys: String, CodingKey {
            case routineID = "routine_id"
            case allowRoomAssignments = "allow_room_assignments"
        }
    }

    let workspace: WorkspaceClient

    func routines() async throws -> [SoloRoutine] {
        try await SoloRoutineClient(client: workspace.client, endpoint: workspace.endpoint,
                                    credential: workspace.credential).routines()
    }

    func assistant(workspaceID: String) async throws -> WorkspaceAssistant? {
        let response: Assistants = try await request(workspaceID, "assistants")
        guard response.assistants.count <= 1, response.assistants.allSatisfy(\.isSupported) else {
            throw CoordinatorError.unexpectedResponse
        }
        return response.assistants.first
    }

    func attachWithRoomConsent(routineID: String, workspaceID: String) async throws -> WorkspaceAssistant {
        guard SoloRoutine.isValidID(routineID) else { throw CoordinatorError.unexpectedResponse }
        let body = try JSONEncoder().encode(BindingRequest(routineID: routineID))
        let assistant: WorkspaceAssistant = try await request(workspaceID, "assistants", body: body, expecting: 201)
        guard assistant.isSupported else { throw CoordinatorError.unexpectedResponse }
        return assistant
    }

    func revoke(assistantID: String, workspaceID: String) async throws {
        guard Workspace.canonicalID(assistantID) == assistantID else { throw CoordinatorError.unexpectedResponse }
        let response: Revocation = try await request(workspaceID, "assistants/\(assistantID)/revoke", body: Data("{}".utf8))
        guard response.revoked else { throw CoordinatorError.unexpectedResponse }
    }

    func assignments(workspaceID: String) async throws -> [WorkspaceAssignment] {
        let response: Assignments = try await request(workspaceID, "assignments")
        guard response.assignments.allSatisfy(\.isValid) else { throw CoordinatorError.unexpectedResponse }
        return response.assignments
    }

    func send(_ draft: Draft, workspaceID: String) async throws -> WorkspaceAssignment {
        guard Workspace.canonicalID(draft.assistantID) == draft.assistantID, Draft.validText(draft.text) else {
            throw CoordinatorError.unexpectedResponse
        }
        let body = try JSONEncoder().encode(draft)
        let assignment: WorkspaceAssignment = try await request(workspaceID, "assignments", body: body, expecting: 202)
        guard assignment.isValid, assignment.id == draft.id, assignment.assistantID == draft.assistantID,
              assignment.text.utf8.elementsEqual(draft.text.utf8) else {
            throw CoordinatorError.unexpectedResponse
        }
        return assignment
    }

    func status(assignmentID: String, workspaceID: String) async throws -> WorkspaceAssignment {
        guard Workspace.canonicalID(assignmentID) == assignmentID else { throw CoordinatorError.unexpectedResponse }
        let assignment: WorkspaceAssignment = try await request(workspaceID, "assignments/\(assignmentID)")
        guard assignment.isValid, assignment.id == assignmentID else { throw CoordinatorError.unexpectedResponse }
        return assignment
    }

    private func request<Response: Decodable>(
        _ workspaceID: String, _ route: String, body: Data? = nil, expecting code: Int = 200
    ) async throws -> Response {
        guard Workspace.canonicalID(workspaceID) == workspaceID else { throw CoordinatorError.unexpectedResponse }
        return try await workspace.client.authenticated(
            url: workspace.endpoint.route("v1/workspaces/\(workspaceID)/\(route)"),
            credential: workspace.credential, body: body, expecting: code
        )
    }
}
