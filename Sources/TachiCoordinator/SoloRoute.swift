import Foundation
import NIOHTTP1
import TachiAccounts
import TachiRuntime

enum SoloRoute {
    static let root = "/v1/solo/routines"
    static func matches(_ path: String) -> Bool { path == root || path.hasPrefix(root + "/") }

    static func reply(_ head: HTTPRequestHead, body: Data, headerError: Reply?,
                      client: ClientPrincipal, service: SoloRoutines?) async throws -> Reply {
        let principal = QueuePrincipal(humanID: client.humanID, clientID: client.clientID)
        let scope = head.method == .POST ? "messages:send" : "sessions:read"
        guard client.scopes.contains(scope) else { return Reply(.forbidden, error: "forbidden") }
        if head.uri == root, head.method == .GET {
            return try Reply(.ok, JSONEncoder().encode(["routines": service?.list(principal) ?? []]))
        }
        let parts = head.uri.dropFirst(root.count).split(separator: "/", omittingEmptySubsequences: false)
        guard let service, (3...4).contains(parts.count), !parts[1].isEmpty, parts[2] == "tasks" else {
            return Reply(.notFound, error: "not_found")
        }
        let taskID: String
        let payload: JSONObject?
        switch (head.method, parts.count) {
        case (.POST, 3):
            if let headerError { return headerError }
            guard let input = try? JSONDecoder().decode(JSONObject.self, from: body), input.count == 2,
                  case let .string(id) = input["task_id"], case let .object(fields) = input["payload"],
                  validTaskID(id) else { return Reply(.badRequest, error: "invalid_request") }
            taskID = id
            payload = fields
        case (.GET, 4):
            taskID = String(parts[3])
            guard validTaskID(taskID) else { return Reply(.notFound, error: "not_found") }
            payload = nil
        default: return Reply(.methodNotAllowed, error: "method_not_allowed")
        }
        do {
            let snapshot = try await service.task(principal, routineID: String(parts[1]), taskID: taskID, payload: payload)
            return try Reply(payload == nil ? .ok : .accepted, JSONEncoder().encode(snapshot))
        } catch QueueError.notFound { return Reply(.notFound, error: "not_found") }
        catch QueueError.denied { return Reply(.forbidden, error: "forbidden") }
        catch QueueError.conflict { return Reply(.conflict, error: "conflict") }
        catch QueueError.invalidInput { return Reply(.badRequest, error: "invalid_request") }
    }

    private static func validTaskID(_ id: String) -> Bool {
        UUID(uuidString: id)?.uuidString.lowercased() == id
    }
}
