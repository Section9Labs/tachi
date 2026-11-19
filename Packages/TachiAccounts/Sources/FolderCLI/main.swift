import Foundation
import TachiAccounts
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

let usage = "Usage: tachi-folder capabilities | (read|write) --folder ABSOLUTE_DIRECTORY CHILD_NAME"

func run(_ args: [String]) throws {
    if args == ["--help"] { print(usage); return }
    if args == ["capabilities"] {
        let caps: [String: Any] = [
            "actions": ["read": "regular-file", "write": "exclusive-create"],
            "path_scope": "direct-children-only", "max_bytes": FolderExecutor.maxBytes, "hard_links": false,
            "write_volume": "clone-capable, same filesystem as private temporary storage"
        ]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: caps, options: [.sortedKeys]))
        print()
        return
    }
    guard args.count == 4, ["read", "write"].contains(args[0]), args[1] == "--folder" else {
        throw FolderError.invalidBody
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try HostStore(path: dir.appendingPathComponent("stub.sqlite").path)
    let owner = "local-demo"
    let invitation = try store.issuePairing(ownerID: owner)
    let session = try store.connect(credential: store.pair(pairingSecret: invitation))
    let executor = try FolderExecutor(folder: args[2], hostID: session.hostID) { scope, session in
        try store.authorize(ownerID: scope.ownerID, session: session, grantID: scope.grantID,
                            folderID: scope.folderID, action: scope.action, relativePath: scope.relativePath)
    }
    defer { executor.close() }
    let grant = try store.grant(ownerID: owner, hostID: session.hostID, folderID: executor.folderID, action: args[0])
    let scope = FolderScope(ownerID: owner, hostID: session.hostID, grantID: grant,
                            folderID: executor.folderID, action: args[0], relativePath: args[3])
    if args[0] == "write" {
        var body = Data()
        while body.count <= FolderExecutor.maxBytes {
            guard let part = try FileHandle.standardInput.read(upToCount: FolderExecutor.maxBytes + 1 - body.count),
                  !part.isEmpty else { break }
            body.append(part)
        }
        _ = try executor.execute(scope, session: session, body: body)
    } else if let bytes = try executor.execute(scope, session: session) {
        try FileHandle.standardOutput.write(contentsOf: bytes)
    }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    let message: String
    switch error {
    case FolderError.directChildrenOnly: message = "Only direct children of the selected folder are supported."
    case FolderError.invalidBody: message = usage
    case FolderError.byteLimit: message = "File exceeds 1 MiB."
    case FolderError.unavailable: message = "Mac folder confinement unavailable."
    case FolderError.posix(let code): message = String(cString: strerror(code))
    default: message = "Folder operation denied or unavailable."
    }
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
