import Foundation
import NIOHTTP1
import TachiAccounts
import TachiRuntime

struct WorkspaceAssistantService: Sendable {
    let queue: TeamQueue
    let registry: AdapterRegistry
    let lookup: WorkspaceRoutineLookup

    init(path: String, accounts: AccountStore, solo: SoloRoutines?) throws {
        queue = try TeamQueue(path: path, authority: CoordinatorAuthority(accounts: accounts))
        registry = solo?.registry ?? AdapterRegistry()
        lookup = { human, routine in solo?.workspaceGrant(human: human, routineID: routine) }
    }

    func runWorker() async throws {
        // Keep unrelated rooms moving while a routine waits for response headers.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    while true {
                        try Task.checkCancellation()
                        do {
                            if try await queue.dispatchWorkspaceAssignment(registry: registry, lookup: lookup) != nil { continue }
                        } catch QueueError.storage(let code) where code == 5 || code == 6 {}
                        try await Task.sleep(for: .milliseconds(250))
                    }
                }
            }
            while try await group.next() != nil {}
        }
    }
}

struct WorkspaceAssistantRoute {
    let team: String
    private let section: Substring
    private let tail: [Substring]

    init?(_ uri: String) {
        let prefix = WorkspaceRoute.root + "/"
        guard uri.hasPrefix(prefix) else { return nil }
        let parts = uri.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard (2...4).contains(parts.count), WorkspaceRoute.validID(String(parts[0])),
              ["assistants", "assignments"].contains(parts[1]) else { return nil }
        team = "workspace/" + parts[0]
        section = parts[1]
        tail = Array(parts.dropFirst(2))
    }

    func reply(_ method: HTTPMethod, body: Data, headerError: Reply?, client: ClientPrincipal,
               accounts: AccountStore, service: WorkspaceAssistantService) async throws -> Reply {
        if let headerError { return headerError }
        let principal = QueuePrincipal(humanID: client.humanID, clientID: client.clientID)
        let queue = service.queue
        do {
            guard try accounts.teamMembership(teamID: team, humanID: client.humanID) != nil else { throw QueueError.notFound }
            switch (method, section, tail.count) {
            case (.GET, "assistants", 0):
                return try await encoded(.ok, ["assistants": queue.workspaceAssistants(team: team, principal: principal, lookup: service.lookup)])
            case (.POST, "assistants", 0):
                let fields = try input(body, ["routine_id","allow_room_assignments"])
                guard case let .string(routine) = fields["routine_id"], fields["allow_room_assignments"] == .bool(true)
                else { throw QueueError.invalidInput }
                return try await encoded(.created, queue.bindWorkspaceRoutine(team: team, principal: principal, routine: routine,
                                                                              lookup: service.lookup))
            case (.POST, "assistants", 2) where tail[1] == "revoke" && WorkspaceRoute.validID(String(tail[0])):
                _ = try input(body, [])
                try await queue.revokeWorkspaceAssistant(team: team, principal: principal, id: String(tail[0]))
                return try encoded(.ok, ["revoked": true])
            case (.POST, "assignments", 0):
                let fields = try input(body, ["assignment_id","assistant_id","text"])
                guard case let .string(id) = fields["assignment_id"], case let .string(assistant) = fields["assistant_id"],
                      WorkspaceRoute.validID(assistant), case let .string(text) = fields["text"] else { throw QueueError.invalidInput }
                return try await encoded(.accepted, queue.assign(team: team, principal: principal, id: id, assistantID: assistant,
                                                                  text: text, lookup: service.lookup))
            case (.GET, "assignments", 0):
                return try await encoded(.ok, ["assignments": queue.workspaceAssignments(team: team, principal: principal, id: nil)])
            case (.GET, "assignments", 1) where WorkspaceRoute.validID(String(tail[0])):
                let rows = try await queue.workspaceAssignments(team: team, principal: principal, id: String(tail[0]))
                guard let row = rows.first else { throw QueueError.notFound }
                return try encoded(.ok, row)
            default: throw QueueError.notFound
            }
        } catch QueueError.denied { return Reply(.forbidden, error: "forbidden") }
        catch QueueError.notFound { return Reply(.notFound, error: "not_found") }
        catch QueueError.invalidInput { return Reply(.badRequest, error: "invalid_request") }
        catch QueueError.conflict { return Reply(.conflict, error: "conflict") }
    }

    private func input(_ body: Data, _ keys: Set<String>) throws -> JSONObject {
        guard let fields = try? JSONDecoder().decode(JSONObject.self, from: body), Set(fields.keys) == keys
        else { throw QueueError.invalidInput }
        return fields
    }

    private func encoded(_ status: HTTPResponseStatus, _ value: some Encodable) throws -> Reply {
        try Reply(status, JSONEncoder().encode(value))
    }
}
