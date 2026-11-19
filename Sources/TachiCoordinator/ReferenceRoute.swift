import Foundation
import NIOHTTP1
import TachiAccounts
import TachiRuntime

enum ReferenceRoute {
    static let root = "/v1/reference-teams"
    static func matches(_ path: String) -> Bool { path == root || path.hasPrefix(root + "/") }

    static func reply(_ head: HTTPRequestHead, body: Data, headerError: Reply?,
                      client: ClientPrincipal, service: ReferenceTeams) async throws -> Reply {
        let principal = QueuePrincipal(humanID: client.humanID, clientID: client.clientID)
        let parts = head.uri.dropFirst(root.count).split(separator: "/", omittingEmptySubsequences: false)
        let team: String?
        let section: String?
        if head.uri == root {
            team = nil
            section = nil
        } else {
            guard (2...3).contains(parts.count), parts[1].utf8.count == 32,
                  parts[1].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  parts.count == 2 || ["messages", "run"].contains(parts[2]) else {
                return Reply(.notFound, error: "not_found")
            }
            team = String(parts[1])
            section = parts.count == 3 ? String(parts[2]) : nil
        }

        do {
            switch (head.method, team, section) {
            case (.GET, nil, nil):
                return try await encoded(["teams": service.list(principal: principal)])
            case (.GET, let team?, nil):
                return try await encoded(service.summary(teamID: team, principal: principal))
            case (.GET, let team?, "messages"):
                return try await encoded(["messages": service.messages(teamID: team, principal: principal)])
            case (.POST, nil, nil):
                if let headerError { return headerError }
                let input = try fields(body, required: ["creationID","turnLimit"])
                guard let id = input["creationID"] as? String else { throw QueueError.invalidInput }
                return try await encoded(service.create(principal: principal, creationID: id, turnLimit: limit(input["turnLimit"])))
            case (.POST, let team?, "run"):
                if let headerError { return headerError }
                let input = try fields(body, required: ["state"], optional: ["turnLimit"])
                guard let raw = input["state"] as? String, let state = RunState(rawValue: raw) else { throw QueueError.invalidInput }
                return try await encoded(service.intervene(teamID: team, principal: principal, state: state,
                                                           turnLimit: input["turnLimit"].map(limit)))
            case (.POST, let team?, "messages"):
                if let headerError { return headerError }
                let input = try fields(body, required: ["messageID","text","audience"], optional: ["mentions","replyTo"])
                guard let id = input["messageID"] as? String, let text = input["text"] as? String,
                      let audience = input["audience"] as? String,
                      let mentions = (input["mentions"] ?? [String]()) as? [String],
                      input["replyTo"] == nil || input["replyTo"] is NSNull || input["replyTo"] is String
                else { throw QueueError.invalidInput }
                let receipt = try await service.post(teamID: team, principal: principal, messageID: id, text: text,
                                                     audience: audience, mentions: mentions, replyTo: input["replyTo"] as? String)
                return try encoded(["messageID": receipt])
            default:
                return Reply(.methodNotAllowed, error: "method_not_allowed")
            }
        } catch QueueError.denied { return Reply(.forbidden, error: "forbidden") }
        catch QueueError.notFound { return Reply(.notFound, error: "not_found") }
        catch QueueError.invalidInput { return Reply(.badRequest, error: "invalid_request") }
        catch QueueError.conflict { return Reply(.conflict, error: "conflict") }
    }

    private static func encoded(_ value: some Encodable) throws -> Reply {
        try Reply(.ok, JSONEncoder().encode(value))
    }

    private static func fields(_ data: Data, required: Set<String>, optional: Set<String> = []) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              required.isSubset(of: object.keys), Set(object.keys).isSubset(of: required.union(optional))
        else { throw QueueError.invalidInput }
        return object
    }

    private static func limit(_ value: Any?) throws -> Int {
        guard let number = value as? NSNumber, ["i","s","l","q","I","S","L","Q"].contains(String(cString: number.objCType)),
              (1...1000).contains(number.int64Value) else { throw QueueError.invalidInput }
        return number.intValue
    }
}
