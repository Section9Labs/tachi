import Foundation
#if os(macOS)
import Darwin
import CTachiAccounts
#endif

public struct FolderScope: Sendable {
    public let ownerID, hostID, grantID, folderID, action, relativePath: String

    public init(ownerID: String, hostID: String, grantID: String, folderID: String,
                action: String, relativePath: String) {
        self.ownerID = ownerID
        self.hostID = hostID
        self.grantID = grantID
        self.folderID = folderID
        self.action = action
        self.relativePath = relativePath
    }
}

public enum FolderError: Error, Equatable {
    case unavailable, directChildrenOnly, invalidBody, byteLimit, fileChanged, posix(Int32)
}

public final class FolderExecutor: @unchecked Sendable {
    public typealias Authorize = @Sendable (FolderScope, HostSession) throws -> Void
    public static let maxBytes = 1_048_576
    public let folderID: String
    private let hostID: String
    private let authorize: Authorize
    private let lock = NSLock()
    // All uses of the descriptor, including close, are serialized by lock.
    private var root: Int32

    public init(folder: String, hostID: String, authorize: @escaping Authorize) throws {
        #if os(macOS)
        try identifier(hostID)
        guard folder.utf8.first == 47, !folder.utf8.contains(0) else { throw AccountsError.denied }
        let fd = open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { throw FolderError.posix(errno) }
        root = fd
        self.hostID = hostID
        self.folderID = newID()
        self.authorize = authorize
        #else
        throw FolderError.unavailable
        #endif
    }

    public func close() {
        #if os(macOS)
        lock.withLock {
            if root >= 0 { _ = Darwin.close(root); root = -1 }
        }
        #endif
    }

    deinit { close() }

    public func execute(_ scope: FolderScope, session: HostSession, body: Data? = nil) throws -> Data? {
        #if os(macOS)
        return try lock.withLock {
            guard root >= 0, scope.hostID.utf8.elementsEqual(hostID.utf8),
                  session.hostID.utf8.elementsEqual(hostID.utf8),
                  scope.folderID.utf8.elementsEqual(folderID.utf8) else { throw AccountsError.denied }
            guard !scope.relativePath.utf8.contains(47) else { throw FolderError.directChildrenOnly }
            try validateRelativePath(scope.relativePath)
            func check() throws { try authorize(scope, session) }
            try check()
            switch (scope.action, body) {
            case ("read", nil): return try readFile(scope.relativePath, check: check)
            case ("write", let data?):
                guard data.count <= Self.maxBytes else { throw FolderError.byteLimit }
                try createFile(scope.relativePath, data: data, check: check)
                return nil
            default: throw FolderError.invalidBody
            }
        }
        #else
        throw FolderError.unavailable
        #endif
    }

    #if os(macOS)
    private func regular(_ info: stat) throws {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw AccountsError.denied }
        guard info.st_size <= Self.maxBytes else { throw FolderError.byteLimit }
    }

    private func entry(_ name: String) throws -> stat {
        var info = stat()
        guard fstatat(root, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw FolderError.posix(errno) }
        try regular(info)
        return info
    }

    private func readFile(_ name: String, check: () throws -> Void) throws -> Data {
        let selected = try entry(name)
        try check()
        let fd = tachi_open_child(root, name)
        guard fd >= 0 else { throw FolderError.posix(errno) }
        defer { _ = Darwin.close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0 else { throw FolderError.posix(errno) }
        try regular(opened)
        guard selected.st_dev == opened.st_dev, selected.st_ino == opened.st_ino else { throw FolderError.fileChanged }

        func verifyEntry() throws {
            let current = try entry(name)
            guard current.st_dev == opened.st_dev, current.st_ino == opened.st_ino,
                  current.st_ctimespec.tv_sec == opened.st_ctimespec.tv_sec,
                  current.st_ctimespec.tv_nsec == opened.st_ctimespec.tv_nsec else { throw FolderError.fileChanged }
        }
        try check()
        try verifyEntry()
        var data = Data(count: Int(opened.st_size) + 1)
        let count = try data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            var count = 0
            while count < buffer.count {
                let n = Darwin.read(fd, buffer.baseAddress!.advanced(by: count), buffer.count - count)
                if n == 0 { break }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw FolderError.posix(errno)
                }
                count += n
            }
            return count
        }
        try check()
        try verifyEntry()
        guard count == opened.st_size else { throw FolderError.fileChanged }
        data.count = count
        return data
    }

    private func createFile(_ name: String, data: Data, check: () throws -> Void) throws {
        guard let file = tmpfile() else { throw FolderError.posix(errno) }
        defer { fclose(file) }
        let fd = fileno(file)
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw FolderError.posix(errno) }
        guard info.st_nlink == 0 else { throw AccountsError.denied }
        if !data.isEmpty {
            try data.withUnsafeBytes { buffer in
                guard fwrite(buffer.baseAddress, 1, buffer.count, file) == buffer.count else { throw FolderError.posix(errno) }
            }
        }
        guard fflush(file) == 0 else { throw FolderError.posix(errno) }
        try check()
        guard fclonefileat(fd, root, name, 0) == 0 else { throw FolderError.posix(errno) }
    }
    #endif
}
