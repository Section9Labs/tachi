import Foundation
import TachiGrok

struct FixtureInput: Decodable {
    let human: String
    let url: URL
    let secret: String
    let directory: URL
}

do {
    let input = try JSONDecoder().decode(FixtureInput.self, from: FileHandle.standardInput.readDataToEndOfFile())
    guard input.url.scheme == "http", input.url.host == "127.0.0.1", input.directory.isFileURL else {
        throw GrokConnectorError.notSent
    }
    _ = try provisionRoutineGrant(humanID: input.human, issuedURL: input.url.absoluteString,
                                  secret: input.secret, directory: input.directory, allowLoopback: true)
} catch {
    FileHandle.standardError.write(Data("Loopback grant provisioning failed.\n".utf8))
    exit(1)
}
