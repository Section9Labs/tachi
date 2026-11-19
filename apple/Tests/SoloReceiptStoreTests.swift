import Foundation
import Testing
@testable import Tachi

struct SoloReceiptStoreTests {
    @Test func checkpointSurvivesReopenAndOlderResponsesCannotOverwriteNewTasks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let origin = try CoordinatorEndpoint("https://coordinator.example").baseURL
        let routine = SoloReceiptStore.Routine(origin: origin, humanID: "owner", routineID: "routine-a")
        let otherHuman = SoloReceiptStore.Routine(origin: origin, humanID: "other", routineID: "routine-a")
        let otherRoutine = SoloReceiptStore.Routine(origin: origin, humanID: "owner", routineID: "routine-b")
        let checkpoint = SoloTaskReceipt(taskID: "first", state: .uncertain)
        let store = SoloReceiptStore(directory: directory)
        try await store.record(checkpoint, for: routine, replacing: nil)

        let reopened = SoloReceiptStore(directory: directory)
        #expect(try await reopened.latest(for: routine) == checkpoint)
        #expect(try await reopened.latest(for: otherHuman) == nil)
        #expect(try await reopened.latest(for: otherRoutine) == nil)

        let accepted = SoloTaskReceipt(taskID: "first", state: .accepted)
        try await reopened.record(accepted, for: routine, replacing: checkpoint.taskID)
        #expect(try await reopened.latest(for: routine) == accepted)
        let next = SoloTaskReceipt(taskID: "second", state: .uncertain)
        try await reopened.record(next, for: routine, replacing: accepted.taskID)
        await #expect(throws: SoloReceiptStore.StoreError.changed) {
            try await reopened.record(accepted, for: routine, replacing: accepted.taskID)
        }
        #expect(try await reopened.latest(for: routine) == next)
    }
}
