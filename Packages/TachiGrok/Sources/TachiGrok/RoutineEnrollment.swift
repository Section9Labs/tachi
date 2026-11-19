import Foundation
import TachiRuntime
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Operator enrollment of one provider-issued routine grant.
///
/// Description and debug text include the human and the origin, and omit the path and the secret.
public struct RoutineEnrollment: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let humanID: String
    public let destination: String
    private let scheme: String
    private let host: String
    private let port: Int

    fileprivate init(humanID: String, grant: WebhookGrant) {
        self.humanID = humanID
        self.destination = grant.destination()
        self.scheme = grant.scheme
        self.host = grant.host
        self.port = grant.port
    }

    public var description: String {
        "RoutineEnrollment(provider: \(grokBotProviderID), human: \(humanID), scheme: \(scheme), host: \(host), port: \(port))"
    }

    public var debugDescription: String { description }
}

/// Write a private enrollment for `humanID`. The directory is mode 0700.
/// `enrollment.json` records the human and the canonical destination. The `secret`
/// file stores that destination, one LF, and then the bearer. The `secret` argument
/// is the bearer only. Both files are mode 0600 and owned by the effective user.
/// This function does not send the routine.
public func provisionRoutineGrant(
    humanID: String,
    issuedURL: String,
    secret: String,
    directory: URL,
    allowLoopback: Bool = false
) throws -> RoutineEnrollment {
    try requireHuman(humanID)
    try requireSecret(secret)
    let grant = try bindWebhook(issuedURL, secret: secret, allowLoopback: allowLoopback)
    let enrollment = RoutineEnrollment(humanID: humanID, grant: grant)
    let binding = try enrollmentDocument(humanID: humanID, destination: enrollment.destination, secret: secret)
    try prepareDirectory(directory)
    let secretURL = directory.appendingPathComponent("secret")
    let bindingURL = directory.appendingPathComponent("enrollment.json")
    var wroteSecret = false
    do {
        var payload = Data(enrollment.destination.utf8)
        payload.append(0x0A)
        payload.append(contentsOf: secret.utf8)
        try writeExclusive(secretURL, payload)
        wroteSecret = true
        try writeExclusive(bindingURL, binding)
    } catch {
        if wroteSecret { unlinkPrivate(secretURL) }
        throw GrokConnectorError.notSent
    }
    return enrollment
}

/// Runtime loads the grant for the human on the turn. A different human, a loose mode, a symlink,
/// another user's file, or a destination that does not bind again is `notSent`. This function does not POST.
public func loadRoutineGrant(
    humanID: String,
    directory: URL,
    allowLoopback: Bool = false
) throws -> WebhookGrant {
    try requireHuman(humanID)
    try requirePrivateDirectory(directory)
    let binding = try readPrivate(directory.appendingPathComponent("enrollment.json"), maxBytes: 8192)
    let document = try parseEnrollment(binding)
    guard document.version == 1, sameToken(document.provider, grokBotProviderID),
          sameToken(document.humanID, humanID) else {
        throw GrokConnectorError.notSent
    }
    let stored = try readPrivate(directory.appendingPathComponent("secret"), maxBytes: 6140)
    guard let separator = stored.firstIndex(of: 0x0A), separator > stored.startIndex else {
        throw GrokConnectorError.notSent
    }
    let recordedDestination = stored[..<separator]
    var secretBytes = Data(stored[stored.index(after: separator)...])
    if secretBytes.last == 0x0A {
        secretBytes.removeLast()
        if secretBytes.last == 0x0D { secretBytes.removeLast() }
    }
    guard secretBytes.count <= 4089,
          let secret = String(bytes: secretBytes, encoding: .utf8),
          recordedDestination.elementsEqual(Data(document.destination.utf8)) else {
        throw GrokConnectorError.notSent
    }
    let grant = try bindWebhook(document.destination, secret: secret, allowLoopback: allowLoopback)
    guard sameToken(grant.destination(), document.destination) else { throw GrokConnectorError.notSent }
    return grant
}

private struct EnrollmentDocument {
    var version: Int
    var provider: String
    var humanID: String
    var destination: String
}

private func requireHuman(_ humanID: String) throws {
    if humanID.isEmpty || humanID.utf8.contains(0) || humanID.contains(where: \.isWhitespace) {
        throw GrokConnectorError.notSent
    }
}

private func requireSecret(_ secret: String) throws {
    if secret.utf8.count > 4089 {
        throw GrokConnectorError.notSent
    }
}

private func sameToken(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.elementsEqual(rhs.utf8)
}

private func enrollmentDocument(humanID: String, destination: String, secret: String) throws -> Data {
    let object: [String: Any] = [
        "destination": destination,
        "human_id": humanID,
        "provider": grokBotProviderID,
        "version": 1,
    ]
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    if data.range(of: Data(secret.utf8)) != nil { throw GrokConnectorError.notSent }
    return data + Data([0x0A])
}

private func parseEnrollment(_ data: Data) throws -> EnrollmentDocument {
    let value: JSONValue
    do {
        value = try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
        throw GrokConnectorError.notSent
    }
    guard case .object(let object) = value, object.count == 4,
          case .integer(1) = object["version"],
          case .string(let provider) = object["provider"],
          case .string(let humanID) = object["human_id"],
          case .string(let destination) = object["destination"] else {
        throw GrokConnectorError.notSent
    }
    return EnrollmentDocument(
        version: 1, provider: provider, humanID: humanID, destination: destination
    )
}

private func prepareDirectory(_ directory: URL) throws {
    let path = try absolutePath(directory)
    if linkInfo(path) != nil {
        try requirePrivateDirectory(directory)
        return
    }
    if mkdir(path, mode_t(0o700)) != 0 || chmod(path, mode_t(0o700)) != 0 {
        throw GrokConnectorError.notSent
    }
    try requirePrivateDirectory(directory)
}

private func requirePrivateDirectory(_ directory: URL) throws {
    guard let info = try linkInfo(absolutePath(directory)) else { throw GrokConnectorError.notSent }
    let mode = info.st_mode
    guard (mode & S_IFMT) == S_IFDIR, (mode & 0o777) == 0o700, info.st_uid == geteuid() else {
        throw GrokConnectorError.notSent
    }
}

private func absolutePath(_ url: URL) throws -> String {
    let path = url.path
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard url.isFileURL, path.hasPrefix("/"), !parts.contains("."), !parts.contains("..") else {
        throw GrokConnectorError.notSent
    }
    return path
}

private func linkInfo(_ path: String) -> stat? {
    var info = stat()
    let rc = path.withCString { lstat($0, &info) }
    return rc == 0 ? info : nil
}

private func writeExclusive(_ url: URL, _ bytes: Data) throws {
    let path = try absolutePath(url)
    let fd = path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600)) }
    if fd < 0 { throw GrokConnectorError.notSent }
    var failed = false
    bytes.withUnsafeBytes { raw in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
            failed = raw.count != 0
            return
        }
        var written = 0
        while written < raw.count {
            let n = write(fd, base + written, raw.count - written)
            if n <= 0 {
                failed = true
                return
            }
            written += n
        }
    }
    var info = stat()
    if failed || fchmod(fd, mode_t(0o600)) != 0 || fstat(fd, &info) != 0 || fsync(fd) != 0
        || (info.st_mode & S_IFMT) != S_IFREG || (info.st_mode & 0o777) != 0o600
        || info.st_uid != geteuid() {
        _ = close(fd)
        unlinkPrivate(url)
        throw GrokConnectorError.notSent
    }
    if close(fd) != 0 {
        unlinkPrivate(url)
        throw GrokConnectorError.notSent
    }
}

private func readPrivate(_ url: URL, maxBytes: Int) throws -> Data {
    let path = try absolutePath(url)
    let fd = path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
    if fd < 0 { throw GrokConnectorError.notSent }
    defer { _ = close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
          (info.st_mode & 0o077) == 0, (info.st_mode & 0o400) == 0o400,
          info.st_uid == geteuid(), info.st_size >= 0, info.st_size <= maxBytes else {
        throw GrokConnectorError.notSent
    }
    var data = Data(count: Int(info.st_size))
    var failed = false
    data.withUnsafeMutableBytes { raw in
        guard info.st_size > 0, let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
        var got = 0
        while got < raw.count {
            let n = read(fd, base + got, raw.count - got)
            if n <= 0 {
                failed = true
                return
            }
            got += n
        }
    }
    if failed { throw GrokConnectorError.notSent }
    return data
}

private func unlinkPrivate(_ url: URL) {
    guard let path = try? absolutePath(url) else { return }
    _ = path.withCString { unlink($0) }
}
