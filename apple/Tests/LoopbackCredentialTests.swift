#if DEBUG && os(macOS)
import Foundation
import Testing
@testable import Tachi

struct LoopbackCredentialTests {
    @Test func localPairingSurvivesViewRecreationWithoutKeychainAccess() async throws {
        let first = try CoordinatorEndpoint("http://127.0.0.1:18473").baseURL
        let second = try CoordinatorEndpoint("http://127.0.0.1:28473").baseURL
        let account = UUID().uuidString
        let credential = CoordinatorCredential(clientID: "fixture", token: "synthetic")
        let store = CoordinatorCredentialStore()
        try await store.save(credential, origin: first, account: account)

        let reopened = CoordinatorCredentialStore()
        #expect(try await reopened.load(origin: first, account: account)?.token == credential.token)
        #expect(try await reopened.load(origin: second, account: account) == nil)
        #expect(try await reopened.load(origin: first, account: "other-" + account) == nil)
        await #expect(throws: CredentialStoreError.occupied) {
            try await reopened.save(credential, origin: first, account: account)
        }
        try await reopened.remove(origin: first, account: account)
        #expect(try await store.load(origin: first, account: account) == nil)
    }

    @Test func httpsUsesThePersistentStore() throws {
        let endpoint = try CoordinatorEndpoint("https://127.0.0.1:18473")
        #expect(!LoopbackTestCredentials.handles(endpoint.baseURL))
    }
}
#endif
