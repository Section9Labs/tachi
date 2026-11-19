import CSoloDigest
import Foundation
import TachiAccounts
import TachiGrok
import TachiRuntime
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

enum SoloConfigurationError: Error { case invalidConfiguration }

private struct RoutineFile: Decodable {
    struct Entry: Decodable {
        let human_id, routine_id, webhook_url, webhook_secret: String
    }
    let routines: [Entry]

    static func read(_ path: String) throws -> Self {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw SoloConfigurationError.invalidConfiguration }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        let maximum = 256 * 1024
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              [0o400, 0o600].contains(info.st_mode & 0o7777), (1...maximum).contains(Int(info.st_size)),
              let data = try file.read(upToCount: maximum + 1), data.count == info.st_size,
              let config = try? JSONDecoder().decode(Self.self, from: data), config.routines.count <= 64
        else { throw SoloConfigurationError.invalidConfiguration }
        return config
    }
}

private func digest(_ text: String) -> String {
    var hash = [UInt8](repeating: 0, count: 32)
    let bytes = Array(text.utf8)
    bytes.withUnsafeBytes { solo_digest($0.baseAddress, $0.count, &hash) }
    return Data(hash).base64EncodedString()
}

private struct Routine: Sendable {
    let human: String
    let alias: String
    let lane: SoloLane
    let generation: String
    let adapter: GrokBotAdapter

    init(_ entry: RoutineFile.Entry, fixture: Bool) throws {
        let id = entry.routine_id.utf8
        let alphanumeric: (UInt8) -> Bool = { (48...57).contains($0) || (97...122).contains($0) }
        guard let first = id.first, alphanumeric(first), id.count <= 64,
              id.allSatisfy({ alphanumeric($0) || $0 == 45 || $0 == 95 }),
              !entry.human_id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !entry.human_id.utf8.contains(0) else { throw SoloConfigurationError.invalidConfiguration }

        let grant = try bindWebhook(entry.webhook_url, secret: entry.webhook_secret, allowLoopback: fixture)
        guard !fixture || (grant.scheme == "http" && grant.host == "127.0.0.1") else {
            throw SoloConfigurationError.invalidConfiguration
        }
        human = entry.human_id
        alias = entry.routine_id
        lane = try SoloLane(key: digest(human + "\0" + alias))
        // Scope pending work to this exact operator grant, including credential rotation.
        generation = digest(grant.destination() + "\0" + grant.secret)
        adapter = try GrokBotAdapter(identity: lane.identity, webhookURL: grant.destination(),
                                     webhookSecret: grant.secret, allowLoopback: fixture)
    }

    init(humanID: String, routineID: String, grant: WebhookGrant, fixture: Bool) throws {
        let id = routineID.utf8
        let alphanumeric: (UInt8) -> Bool = { (48...57).contains($0) || (97...122).contains($0) }
        guard let first = id.first, alphanumeric(first), id.count <= 64,
              id.allSatisfy({ alphanumeric($0) || $0 == 45 || $0 == 95 }),
              !humanID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !humanID.utf8.contains(0),
              !fixture || (grant.scheme == "http" && grant.host == "127.0.0.1") else {
            throw SoloConfigurationError.invalidConfiguration
        }
        human = humanID
        alias = routineID
        lane = try SoloLane(key: digest(human + "\0" + alias))
        generation = digest(grant.destination() + "\0" + grant.secret)
        adapter = try GrokBotAdapter(identity: lane.identity, grant: grant, allowLoopback: fixture)
    }
}

private struct SoloAuthority: QueueAuthority {
    let accounts: AccountStore
    let routines: [String: Routine]

    func membershipID(team: String, humanID: String) throws -> String? {
        guard let binding = routines[team], binding.human.utf8.elementsEqual(humanID.utf8) else { return nil }
        return binding.generation
    }

    func authorize(_ principal: QueuePrincipal, team: String, scope: String, membershipID: String?) throws -> String {
        guard let generation = try self.membershipID(team: team, humanID: principal.humanID),
              membershipID == nil || membershipID == generation else { throw QueueError.denied }
        do { try accounts.authorizeClient(humanID: principal.humanID, clientID: principal.clientID, scope: scope) }
        catch AccountsError.denied { throw QueueError.denied }
        return generation
    }
}

struct SoloRoutines: Sendable {
    private let routines: [Routine]
    private let queue: TeamQueue
    let registry: AdapterRegistry

    init(path: String, accounts: AccountStore, config: String, fixture: Bool) async throws {
        try await self.init(path: path, accounts: accounts,
                            routines: try RoutineFile.read(config).routines.map { try Routine($0, fixture: fixture) })
    }

    /// Load one enrollment directory. The private JSON file is untouched, and the secret stays in that directory.
    init(path: String, accounts: AccountStore, directory: String, humanID: String, routineID: String,
         fixture: Bool) async throws {
        let grant: WebhookGrant
        do {
            grant = try loadRoutineGrant(humanID: humanID, directory: URL(fileURLWithPath: directory),
                                         allowLoopback: fixture)
        } catch {
            throw SoloConfigurationError.invalidConfiguration
        }
        let routine = try Routine(humanID: humanID, routineID: routineID, grant: grant, fixture: fixture)
        try await self.init(path: path, accounts: accounts, routines: [routine])
    }

    private init(path: String, accounts: AccountStore, routines: [Routine]) async throws {
        self.routines = routines
        var bindings: [String: Routine] = [:]
        registry = AdapterRegistry()
        for routine in routines {
            guard bindings.updateValue(routine, forKey: routine.lane.teamID) == nil else {
                throw SoloConfigurationError.invalidConfiguration
            }
            try await registry.register(routine.adapter)
        }
        queue = try TeamQueue(path: path, authority: SoloAuthority(accounts: accounts, routines: bindings))
    }

    func workspaceGrant(human: String, routineID: String) -> WorkspaceRoutineGrant? {
        guard let routine = routines.first(where: {
            $0.human.utf8.elementsEqual(human.utf8) && $0.alias.utf8.elementsEqual(routineID.utf8)
        }) else { return nil }
        return WorkspaceRoutineGrant(identity: routine.adapter.identity, generation: routine.generation)
    }

    func list(_ principal: QueuePrincipal) -> [[String: String]] {
        routines.filter { $0.human.utf8.elementsEqual(principal.humanID.utf8) }
            .map { ["routine_id": $0.alias, "provider": grokBotProviderID] }
    }

    func task(_ principal: QueuePrincipal, routineID: String, taskID: String, payload: JSONObject?) async throws -> JSONObject {
        guard let binding = routines.first(where: {
            $0.human.utf8.elementsEqual(principal.humanID.utf8) && $0.alias.utf8.elementsEqual(routineID.utf8)
        }) else { throw QueueError.notFound }
        let state: String
        if let payload {
            state = try await queue.submitSolo(lane: binding.lane, principal: principal, taskID: taskID, payload: payload)
        } else {
            state = try await queue.soloTask(lane: binding.lane, principal: principal, taskID: taskID)
        }
        return ["task_id": .string(taskID), "routine_id": .string(routineID), "state": .string(state),
                "native_result_available": .bool(false), "result": .null]
    }

    func runWorker() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for routine in routines {
                group.addTask {
                    while true {
                        try Task.checkCancellation()
                        do {
                            if try await queue.dispatchOne(registry: registry, teamID: routine.lane.teamID) != nil { continue }
                        } catch QueueError.storage(let code) where code == 5 || code == 6 {
                            // Another SQLite connection holds the database lock.
                        }
                        try await Task.sleep(for: .milliseconds(250))
                    }
                }
            }
            while try await group.next() != nil {}
        }
    }
}
