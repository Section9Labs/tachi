import Foundation
import Testing
@testable import Tachi

struct SoloReceiptStoreTests {
    @Test func keepsByteDistinctHumanIDsIsolated() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let origin = try CoordinatorEndpoint("https://coordinator.example").baseURL
        let firstHuman = "caf\u{00E9}"
        let secondHuman = "cafe\u{0301}"
        #expect(firstHuman == secondHuman)

        let first = SoloReceiptStore.Routine(origin: origin, humanID: firstHuman, routineID: "demo")
        let second = SoloReceiptStore.Routine(origin: origin, humanID: secondHuman, routineID: "demo")
        let firstReceipt = SoloTaskReceipt(taskID: "first", state: .accepted)
        let secondReceipt = SoloTaskReceipt(taskID: "second", state: .uncertain)
        let store = SoloReceiptStore(directory: directory)
        try await store.record(firstReceipt, for: first, replacing: nil)
        #expect(try await store.latest(for: second) == nil)
        try await store.record(secondReceipt, for: second, replacing: nil)

        let reopened = SoloReceiptStore(directory: directory)
        #expect(try await reopened.latest(for: first) == firstReceipt)
        #expect(try await reopened.latest(for: second) == secondReceipt)
    }

    @Test func onlyAnExplicitRejectionOffersAnotherSubmission() {
        #expect(SoloTaskState.rejected.canStartAnotherTask)
        for state: SoloTaskState in [.queued, .accepted, .uncertain, .denied, .blocked] {
            #expect(!state.canStartAnotherTask)
        }
    }

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
