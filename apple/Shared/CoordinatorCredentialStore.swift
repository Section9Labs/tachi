import Foundation
import Security

struct CoordinatorCredentialStore: Sendable {
    let servicePrefix: String

    init(servicePrefix: String = "com.section9labs.tachi.coordinator") {
        self.servicePrefix = servicePrefix
    }

    func load(origin: URL, account: String) async throws -> CoordinatorCredential? {
        #if DEBUG && os(macOS)
        if LoopbackTestCredentials.handles(origin) {
            return await LoopbackTestCredentials.shared.load(service: service(origin), account: account)
        }
        #endif
        var query = key(origin: origin, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let credential = try? JSONDecoder().decode(CoordinatorCredential.self, from: data),
              credential.isValid else {
            throw CredentialStoreError.read
        }
        return credential
    }

    func save(_ credential: CoordinatorCredential, origin: URL, account: String) async throws {
        #if DEBUG && os(macOS)
        if LoopbackTestCredentials.handles(origin) {
            try await LoopbackTestCredentials.shared.save(credential, service: service(origin), account: account)
            return
        }
        #endif
        var item = key(origin: origin, account: account)
        item[kSecValueData as String] = try JSONEncoder().encode(credential)
        #if os(iOS)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #endif

        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw status == errSecDuplicateItem ? CredentialStoreError.occupied : CredentialStoreError.write
        }
    }

    func remove(origin: URL, account: String) async throws {
        #if DEBUG && os(macOS)
        if LoopbackTestCredentials.handles(origin) {
            await LoopbackTestCredentials.shared.remove(service: service(origin), account: account)
            return
        }
        #endif
        let status = SecItemDelete(key(origin: origin, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError.remove }
    }

    private func service(_ origin: URL) -> String {
        "\(servicePrefix):\(origin.absoluteString)"
    }

    private func key(origin: URL, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(origin),
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }
}

enum CredentialStoreError: LocalizedError {
    case read
    case write
    case occupied
    case remove

    var errorDescription: String? {
        switch self {
        case .read: "Couldn’t read the saved account from Keychain."
        case .write: "Couldn’t save this account to Keychain. Unlock Keychain and ask for a new invitation."
        case .occupied: "This label already has a saved account. Check that account or choose a different label."
        case .remove: "Access was revoked. Couldn’t remove the device’s credential from Keychain."
        }
    }
}
