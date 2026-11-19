import Foundation
import TachiRuntime

enum DiagnosticsCommand {
    static func run(_ arguments: ArraySlice<String>) -> Int32 {
        guard arguments.count == 2, arguments.first == "--db", let path = arguments.last, !path.isEmpty else {
            FileHandle.standardError.write(Data("Usage: tachi-coordinator diagnostics --db PATH\n".utf8))
            return 1
        }
        do {
            let report = try QueueDiagnostics.snapshot(path: path)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            var output = try encoder.encode(report)
            output.append(0x0a)
            try FileHandle.standardOutput.write(contentsOf: output)
            return 0
        } catch {
            FileHandle.standardError.write(Data("Queue diagnostics unavailable.\n".utf8))
            return 1
        }
    }
}
