import Foundation
import Testing
@testable import Tachi

struct ReferenceOutboxTests {
    @Test func reopensPendingMessagesAndKeepsClientAuthorityIsolated() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let origin = try CoordinatorEndpoint("https://coordinator.example").baseURL
        let originB = try CoordinatorEndpoint("https://another.example").baseURL
        let owner = ReferenceOutbox.Account(origin: origin, humanID: "owner", clientID: "first-client")
        let sibling = ReferenceOutbox.Account(origin: origin, humanID: "owner", clientID: "second-client")
        let otherOrigin = ReferenceOutbox.Account(origin: originB, humanID: "owner", clientID: "first-client")
        let draft = ReferenceDraft(messageID: "pending-one", text: "fixture message", audience: .room,
                                   mentions: [.peer], replyTo: "first")
        let outbox = ReferenceOutbox(directory: directory)
        try await outbox.enqueue(draft, account: owner, teamID: "team")

        let reopened = ReferenceOutbox(directory: directory)
        #expect(try await reopened.pending(account: owner, teamID: "team").map(\.draft) == [draft])
        #expect(try await reopened.pending(account: sibling, teamID: "team").isEmpty)
        #expect(try await reopened.pending(account: otherOrigin, teamID: "team").isEmpty)
        #expect(try await reopened.pending(account: owner, teamID: "other-team").isEmpty)

        try await reopened.acknowledge(draft.id, account: sibling, teamID: "team")
        #expect(try await reopened.pending(account: owner, teamID: "team").map(\.draft) == [draft])
        try await reopened.reject(draft.id, account: owner, teamID: "team")
        #expect(try await reopened.pending(account: owner, teamID: "team").map(\.rejected) == [true])
        try await reopened.acknowledge(draft.id, account: owner, teamID: "team")
        #expect(try await reopened.pending(account: owner, teamID: "team").isEmpty)
    }
}
