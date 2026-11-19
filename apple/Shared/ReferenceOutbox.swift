import Foundation

actor ReferenceOutbox {
    struct Account: Codable, Equatable, Sendable {
        let origin: URL
        let humanID: String
        let clientID: String
    }

    struct Pending: Identifiable, Sendable {
        let draft: ReferenceDraft
        let rejected: Bool

        var id: String { draft.id }
    }

    private struct Entry: Codable {
        let account: Account
        let teamID: String
        let draft: ReferenceDraft
        var rejected: Bool?
    }

    static let shared = ReferenceOutbox()

    private let directory: URL

    init(directory: URL = .applicationSupportDirectory.appendingPathComponent("com.section9labs.tachi")) {
        self.directory = directory
    }

    func pending(account: Account, teamID: String) throws -> [Pending] {
        try entries().filter { $0.account == account && $0.teamID == teamID }
            .map { Pending(draft: $0.draft, rejected: $0.rejected == true) }
    }

    func enqueue(_ draft: ReferenceDraft, account: Account, teamID: String) throws {
        var pending = try entries()
        pending.append(Entry(account: account, teamID: teamID, draft: draft))
        try write(pending)
    }

    func acknowledge(_ messageID: String, account: Account, teamID: String) throws {
        var pending = try entries()
        pending.removeAll { $0.account == account && $0.teamID == teamID && $0.draft.id == messageID }
        try write(pending)
    }

    func reject(_ messageID: String, account: Account, teamID: String) throws {
        var entries = try entries()
        guard let index = entries.firstIndex(where: {
            $0.account == account && $0.teamID == teamID && $0.draft.id == messageID
        }) else { return }
        entries[index].rejected = true
        try write(entries)
    }

    private var file: URL { directory.appendingPathComponent("reference-outbox-v1.json") }

    private func entries() throws -> [Entry] {
        do {
            return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
    }

    private func write(_ entries: [Entry]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entries)
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: file, options: .atomic)
        #endif
    }
}
