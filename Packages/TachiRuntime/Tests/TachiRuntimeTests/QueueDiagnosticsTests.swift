import Foundation
import RuntimeSQLite
import Testing
@testable import TachiRuntime

@Test func diagnosticsUseAQueryOnlyConnectionAndFixedCounters() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("private.sqlite").path
    #expect(throws: QueueError.storage(SQLITE_CANTOPEN)) { _ = try QueueDiagnostics.snapshot(path: path) }
    #expect(!FileManager.default.fileExists(atPath: path))

    let writer = try RuntimeDatabase(path: path)
    let reader = try RuntimeDatabase(path: path, readOnly: true)
    #expect(try reader.query("PRAGMA query_only").first?["query_only"] == "1")
    #expect(throws: QueueError.storage(SQLITE_READONLY)) { try reader.query("CREATE TEMP TABLE no_write(x)") }
    #expect(throws: QueueError.storage(SQLITE_READONLY)) { try reader.query("DELETE FROM rt_run") }

    let runStates = ["running", "paused", "cancelled", "completed"]
    let deliveryStates = ["queued", "active", "blocked", "uncertain", "denied", "completed", "failed", "cancelled"]
    try writer.query("INSERT INTO rt_assistant VALUES ('team','lead','private-provider','account','assistant','session')")
    try writer.transaction {
        for state in runStates + ["private-future-run"] {
            try writer.query("INSERT INTO rt_run(team,run,lead,state,turn_limit) VALUES ('team',?,'lead',?,5)", [state, state])
        }
        for (index, state) in (deliveryStates + ["private-future-delivery", "BLOCKED"]).enumerated() {
            let id = String(index)
            try writer.query("""
                INSERT INTO rt_message(team,message,run,author,mentions,capability,payload,human,client,membership)
                VALUES ('team',?,'running','author','[]','task','private-content','human','client','membership')
                """, [id])
            try writer.query("""
                INSERT INTO rt_delivery(team,message,target,request,state,reason)
                VALUES ('team',?,'lead',?,?,'private-reason')
                """, [id, id, state])
        }
    }
    let report = try QueueDiagnostics.snapshot(path: path)
    var runs = Dictionary(uniqueKeysWithValues: runStates.map { ($0, Int64(1)) })
    var deliveries = Dictionary(uniqueKeysWithValues: deliveryStates.map { ($0, Int64(1)) })
    runs["other"] = 1
    deliveries["other"] = 2
    #expect(report.runs == runs)
    #expect(report.deliveries == deliveries)
}
