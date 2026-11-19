import Foundation

actor SoloReceiptStore {
    struct Routine: Codable, Equatable, Sendable {
        let origin: URL
        let humanID: String
        let routineID: String
    }

    private struct Entry: Codable {
        let routine: Routine
        let receipt: SoloTaskReceipt
    }

    static let shared = SoloReceiptStore()

    private let directory: URL

    init(directory: URL = .applicationSupportDirectory.appendingPathComponent("com.section9labs.tachi")) {
        self.directory = directory
    }

    func latest(for routine: Routine) throws -> SoloTaskReceipt? {
        try entries().first { $0.routine == routine }?.receipt
    }

    func record(_ receipt: SoloTaskReceipt, for routine: Routine, replacing expectedID: String?) throws {
        var entries = try entries()
        let index = entries.firstIndex { $0.routine == routine }
        guard index.map({ entries[$0].receipt.taskID }) == expectedID else { throw StoreError.changed }
        let entry = Entry(routine: routine, receipt: receipt)
        if let index { entries[index] = entry } else { entries.append(entry) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entries)
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: file, options: .atomic)
        #endif
    }

    private var file: URL { directory.appendingPathComponent("solo-receipts-v1.json") }

    private func entries() throws -> [Entry] {
        do {
            return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
    }

    enum StoreError: LocalizedError, Equatable {
        case changed

        var errorDescription: String? { "This routine changed in another window. Reopen it to see the latest task." }
    }
}
