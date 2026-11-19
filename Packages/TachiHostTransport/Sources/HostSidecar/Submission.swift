import Foundation
import TachiAccounts
import TachiRuntime
import TachiHostTransport

/// Local operator tooling uses the same authenticated TeamQueue insertion path
/// as a coordinator integration. It has no separate work store.
func submitOrBind(_ args: [String]) async throws {
    let accounts = try AccountStore(path: args[1])
    let token = try String(contentsOfFile: args[2], encoding: .utf8).trimmingCharacters(in: .newlines)
    let human = try accounts.authenticate(token: token)
    let principal = QueuePrincipal(humanID: human.humanID, clientID: human.clientID)
    let queue = try TeamQueue(path: args[1], authority: OriginAuthority(accounts))
    let team = args[3]
    if args[0] == "bind" {
        let alias = args[4]
        try await queue.addAssistant(team: team, principal: principal, alias: alias,
            identity: AdapterIdentity(provider: "tachi-folder", accountID: team, assistantID: alias), sessionID: alias)
        return
    }
    let run = args[4], alias = args[5], message = args[6]
    let scope = try HostScope(ownerID: human.humanID, hostID: args[7], grantID: args[8], folderID: args[9],
                              action: args[10], relativePath: args[11])
    var payload: JSONObject = [:]
    if scope.action == "write" {
        var bytes = Data()
        while bytes.count <= FolderExecutor.maxBytes {
            guard let part = try FileHandle.standardInput.read(upToCount: FolderExecutor.maxBytes + 1 - bytes.count),
                  !part.isEmpty else { break }
            bytes.append(part)
        }
        guard bytes.count <= FolderExecutor.maxBytes else { throw TransportError.invalid }
        payload["bodyBase64"] = .string(bytes.base64EncodedString())
    }
    try await queue.post(team: team, principal: principal, run: run, message: message, payload: payload,
                         directTo: "assistant:" + alias, capability: .task, scope: scope)
}
