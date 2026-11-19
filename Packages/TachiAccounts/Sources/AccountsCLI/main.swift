import Foundation
import TachiAccounts
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

let usage = """
Usage: tachi-accounts invite-client --db PATH --human-id ID --scope SCOPE [--scope SCOPE] --out NEW_FILE
       tachi-accounts list-clients --db PATH --human-id ID
       tachi-accounts revoke-client --db PATH --human-id ID --client-id ID
"""
enum CLIError: Error { case usage, destination }

func run(_ arguments: [String]) throws {
    if arguments == ["--help"] { print(usage); return }
    guard let command = arguments.first else { throw CLIError.usage }
    let required: Set<String>
    switch command {
    case "invite-client": required = ["--db", "--human-id", "--scope", "--out"]
    case "list-clients": required = ["--db", "--human-id"]
    case "revoke-client": required = ["--db", "--human-id", "--client-id"]
    default: throw CLIError.usage
    }
    var options: [String: [String]] = [:]
    var iterator = arguments.dropFirst().makeIterator()
    while let key = iterator.next() {
        guard required.contains(key), key == "--scope" || options[key] == nil,
              let value = iterator.next(), !value.isEmpty else { throw CLIError.usage }
        options[key, default: []].append(value)
    }
    guard Set(options.keys) == required, let path = options["--db"]?.first,
          let human = options["--human-id"]?.first else { throw CLIError.usage }
    let store = try AccountStore(path: path)
    switch command {
    case "invite-client":
        guard let file = options["--out"]?.first, let scopes = options["--scope"] else { throw CLIError.usage }
        let fd = open(file, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CLIError.destination }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let secret = try store.issueClientInvitation(humanID: human, scopes: Set(scopes))
        try handle.write(contentsOf: Data((secret + "\n").utf8))
        try handle.close()
    case "list-clients":
        for id in try store.listClients(humanID: human) { print(id) }
    default:
        guard let client = options["--client-id"]?.first else { throw CLIError.usage }
        try store.revokeClient(humanID: human, clientID: client)
    }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    let message: String
    switch error {
    case CLIError.usage: message = usage
    case CLIError.destination: message = "Cannot create new invitation file."
    case AccountsError.denied: message = "Operation denied."
    case AccountsError.invalidScopes: message = "Unsupported client scope."
    default: message = "Account operation failed."
    }
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
