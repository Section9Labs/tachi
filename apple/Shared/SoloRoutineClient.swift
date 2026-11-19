import Foundation

struct SoloRoutine: Decodable, Identifiable, Sendable {
    let id: String
    let provider: String
    let originText: String?

    enum CodingKeys: String, CodingKey {
        case id = "routine_id"
        case provider, origin
    }

    private struct Origin: Decodable {
        let scheme: String
        let host: String
        let port: Int

        var displayText: String? {
            let loopback = host.lowercased() == "localhost" || host == "127.0.0.1"
            guard scheme == (loopback ? "http" : "https"), (1...65535).contains(port), !host.isEmpty,
                  host.unicodeScalars.allSatisfy({
                      CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_"
                  }) else { return nil }
            return "\(scheme)://\(host):\(port)"
        }
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(String.self, forKey: .id)
        provider = try fields.decode(String.self, forKey: .provider)
        originText = (try? fields.decode(Origin.self, forKey: .origin))?.displayText
    }

    static func isValidID(_ id: String) -> Bool {
        id.range(of: #"\A[a-z0-9][a-z0-9_-]{0,63}\z"#, options: .regularExpression) != nil
    }
}

enum SoloTaskState: String, Codable, Sendable {
    case queued, accepted, rejected, uncertain, denied, blocked

    var canStartAnotherTask: Bool { self == .rejected }
}

struct SoloTaskReceipt: Codable, Equatable, Sendable {
    let taskID: String
    let state: SoloTaskState
}

struct SoloRoutineClient: Sendable {
    let client: CoordinatorClient
    let endpoint: CoordinatorEndpoint
    let credential: CoordinatorCredential

    private struct Routines: Decodable {
        let routines: [SoloRoutine]
    }

    private struct Submission: Encodable {
        struct Payload: Encodable { let text: String }

        let taskID: String
        let payload: Payload

        enum CodingKeys: String, CodingKey {
            case taskID = "task_id"
            case payload
        }
    }

    private struct Snapshot: Decodable {
        let taskID: String
        let routineID: String
        let state: SoloTaskState
        let nativeResultAvailable: Bool
        let result: String?

        enum CodingKeys: String, CodingKey {
            case taskID = "task_id"
            case routineID = "routine_id"
            case state
            case nativeResultAvailable = "native_result_available"
            case result
        }
    }

    func routines() async throws -> [SoloRoutine] {
        let response: Routines = try await client.authenticated(url: endpoint.route("v1/solo/routines"), credential: credential)
        return response.routines.filter { $0.provider == "grok-bot" && SoloRoutine.isValidID($0.id) }
    }

    func submit(routineID: String, taskID: String, text: String) async throws -> SoloTaskReceipt {
        let path = try tasksPath(routineID: routineID, taskID: taskID)
        let body = try JSONEncoder().encode(Submission(taskID: taskID, payload: .init(text: text)))
        let snapshot: Snapshot = try await client.authenticated(
            url: endpoint.route(path), credential: credential, body: body, expecting: 202
        )
        return try receipt(snapshot, routineID: routineID, taskID: taskID)
    }

    func status(routineID: String, taskID: String) async throws -> SoloTaskReceipt {
        let path = try tasksPath(routineID: routineID, taskID: taskID)
        let snapshot: Snapshot = try await client.authenticated(
            url: endpoint.route("\(path)/\(taskID)"), credential: credential
        )
        return try receipt(snapshot, routineID: routineID, taskID: taskID)
    }

    private func tasksPath(routineID: String, taskID: String) throws -> String {
        guard SoloRoutine.isValidID(routineID), UUID(uuidString: taskID)?.uuidString.lowercased() == taskID else {
            throw CoordinatorError.unexpectedResponse
        }
        return "v1/solo/routines/\(routineID)/tasks"
    }

    private func receipt(_ snapshot: Snapshot, routineID: String, taskID: String) throws -> SoloTaskReceipt {
        guard snapshot.routineID == routineID, snapshot.taskID == taskID,
              !snapshot.nativeResultAvailable, snapshot.result == nil else {
            throw CoordinatorError.unexpectedResponse
        }
        return SoloTaskReceipt(taskID: taskID, state: snapshot.state)
    }
}
