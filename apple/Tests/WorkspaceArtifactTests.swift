import Foundation
import Testing
@testable import Tachi

struct WorkspaceArtifactTests {
    @Test func encodesMaximumSlashHeavyArtifactWithCanonicalBase64() throws {
        let bytes = Data(repeating: 0xff, count: WorkspaceArtifactUpload.byteLimit)
        let upload = WorkspaceArtifactUpload(name: "sample.bin", contentType: "application/octet-stream", bytes: bytes,
                                              recipientID: "member", fixture: true, source: .message(artifactFixtureID))
        let encoded = try upload.encoded()
        #expect(encoded.count < 1_500_000)
        let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let base64 = try #require(fields["content_base64"] as? String)
        #expect(base64 == bytes.base64EncodedString())
        #expect(Data(base64Encoded: base64) == bytes)
        #expect(fields["source_message_id"] as? String == artifactFixtureID)
        #expect(fields["audience"] as? String == "direct")
        #expect(fields["fixture"] as? Bool == true)
        #expect(fields["author_id"] == nil)
        #expect(fields["origin"] == nil)
    }

    @Test func acceptsZeroBytesAndRejectsOversize() throws {
        let empty = WorkspaceArtifactUpload(name: "empty.bin", contentType: "application/octet-stream", bytes: Data(),
                                            recipientID: nil, fixture: false, source: nil)
        let encoded = try empty.encoded()
        let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(fields["content_base64"] as? String == "")
        let oversize = WorkspaceArtifactUpload(
            name: "large.bin", contentType: "application/octet-stream",
            bytes: Data(repeating: 0, count: WorkspaceArtifactUpload.byteLimit + 1),
            recipientID: nil, fixture: false, source: nil
        )
        #expect(throws: WorkspaceArtifactError.sizeLimit) { try oversize.encoded() }
    }

    @Test func retrievesVerifiedBytesThroughTheAuthenticatedArtifactRoute() async throws {
        let api = try artifactClient(host: "valid.example")
        let metadata = try await api.list(workspaceID: artifactFixtureID)
        let artifact = try #require(metadata.first)
        #expect(artifact.origin == .humanUpload)
        #expect(try await api.download(artifact, workspaceID: artifactFixtureID) == Data("abc".utf8))

        let invalid = try artifactClient(host: "invalid.example")
        await #expect(throws: WorkspaceArtifactError.integrity) {
            try await invalid.download(artifact, workspaceID: artifactFixtureID)
        }
    }

    private func artifactClient(host: String) throws -> WorkspaceArtifactClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtifactURLProtocol.self]
        let endpoint = try CoordinatorEndpoint("https://\(host)")
        let workspace = WorkspaceClient(client: CoordinatorClient(configuration: configuration), endpoint: endpoint,
                                        credential: .init(clientID: "fixture-client", token: "fixture-bearer"))
        return WorkspaceArtifactClient(workspace: workspace)
    }
}

private let artifactFixtureID = "01234567-abcd-4567-89ab-0123456789ab"

private final class ArtifactURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, request.httpMethod == "GET", url.query == nil,
              request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-bearer" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let metadata = #"{"artifact_id":"\#(artifactFixtureID)","name":"sample.txt","content_type":"text/plain","size_bytes":3,"sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad","audience":"room","recipient_id":null,"origin":"human_upload","author_id":"fixture-human","source_message_id":null,"source_task_id":null}"#
        let collection = "/v1/workspaces/\(artifactFixtureID)/artifacts"
        let body: String
        switch url.path {
        case collection:
            body = #"{"artifacts":[\#(metadata)]}"#
        case "\(collection)/\(artifactFixtureID)":
            let base64 = url.host == "valid.example" ? "YWJj" : "YWJk"
            body = metadata.dropLast() + #","content_base64":"\#(base64)"}"#
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
