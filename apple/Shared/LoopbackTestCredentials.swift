#if DEBUG && os(macOS)
import Foundation

/// Disposable local coordinator credentials shared by views in this app process.
actor LoopbackTestCredentials {
    static let shared = LoopbackTestCredentials()

    private struct Entry: Hashable {
        let service: String
        let account: Data
    }

    private var credentials: [Entry: CoordinatorCredential] = [:]

    static func handles(_ origin: URL) -> Bool {
        origin.scheme == "http" && origin.host == "127.0.0.1"
    }

    func load(service: String, account: String) -> CoordinatorCredential? {
        credentials[Entry(service: service, account: Data(account.utf8))]
    }

    func save(_ credential: CoordinatorCredential, service: String, account: String) throws {
        let entry = Entry(service: service, account: Data(account.utf8))
        guard credentials[entry] == nil else { throw CredentialStoreError.occupied }
        credentials[entry] = credential
    }

    func remove(service: String, account: String) {
        credentials.removeValue(forKey: Entry(service: service, account: Data(account.utf8)))
    }
}
#endif
