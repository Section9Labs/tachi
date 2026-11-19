import Foundation
import Testing
@testable import Tachi

struct CoordinatorClientTests {
    @Test func endpointUsesVersionedStatusPath() throws {
        let endpoint = try CoordinatorEndpoint("  https://coordinator.example:9443/\n")
        #expect(endpoint.baseURL.absoluteString == "https://coordinator.example:9443")
        #expect(endpoint.statusURL.absoluteString == "https://coordinator.example:9443/v1/status")
    }

    @Test func equivalentHTTPSOriginsUseOneKeychainService() throws {
        let first = try CoordinatorEndpoint("HTTPS://COORDINATOR.example:443/")
        let second = try CoordinatorEndpoint("https://coordinator.example")
        #expect(first.baseURL == second.baseURL)
    }

    @Test func sendsWorkspaceDirectMessageWithExactRecipientBytes() async throws {
        let endpoint = try CoordinatorEndpoint("https://workspace.example")
        let api = WorkspaceClient(client: client(), endpoint: endpoint,
                                  credential: .init(clientID: "fixture-client", token: "fixture-bearer"))
        let workspaces = try await api.list()
        let workspace = try #require(workspaces.first)
        #expect(workspace.role == .member)
        let draft = WorkspaceClient.Draft(text: "fixture direct message", recipientID: "cafe\u{0301}")
        try await api.send(draft, workspaceID: workspace.id)
        let messages = try await api.messages(workspaceID: workspace.id)
        let message = try #require(messages.first)
        #expect(message.recipientID?.utf8.elementsEqual("cafe\u{0301}".utf8) == true)
        await #expect(throws: CoordinatorError.unexpectedResponse) {
            try await api.messages(workspaceID: "../workspace")
        }
    }

    @Test(arguments: [
        "coordinator.example", "https://", "ftp://coordinator.example", "https://coordinator.example:65536",
        "https://user:secret@coordinator.example", "https://coordinator.example/api",
        "https://coordinator.example?token=fixture", "https://coordinator.example/#fragment"
    ]) func rejectsInvalidBaseURLs(input: String) {
        #expect(throws: CoordinatorError.invalidURL) { try CoordinatorEndpoint(input) }
    }

    @Test func cleartextRequiresDevelopmentLoopback() throws {
        let local = try CoordinatorEndpoint(CoordinatorEndpoint.localDevelopmentURL, allowsLocalHTTP: true)
        #expect(local.statusURL.absoluteString == "http://127.0.0.1:8743/v1/status")
        #expect(throws: CoordinatorError.requiresHTTPS) {
            try CoordinatorEndpoint(CoordinatorEndpoint.localDevelopmentURL, allowsLocalHTTP: false)
        }
        #expect(throws: CoordinatorError.requiresHTTPS) {
            try CoordinatorEndpoint("http://coordinator.example", allowsLocalHTTP: true)
        }
    }

    @Test func readsReadyStatusWithAnUnauthenticatedGET() async throws {
        let status = try await client().status(at: CoordinatorEndpoint("https://ready.example"))
        #expect(status.service == "tachi")
        #expect(status.protocolVersion == 1)
        #expect(status.status == "ready")
    }

    @Test func redeemsInvitationAndChecksBoundAccount() async throws {
        let endpoint = try CoordinatorEndpoint("https://pair.example")
        let client = client()
        let credential = try await client.pair(at: endpoint, invitation: "fixture-invitation")
        let account = try await client.account(at: endpoint, credential: credential)
        #expect(account.humanID == "fixture-human")
        #expect(account.clientID == "fixture-client")
        #expect(account.scopes == ["sessions:read"])
    }

    @Test func distinguishesRejectedInvitationAndRevokedCredential() async throws {
        let endpoint = try CoordinatorEndpoint("https://denied.example")
        let client = client()
        await #expect(throws: CoordinatorError.invitationRejected) {
            try await client.pair(at: endpoint, invitation: "fixture-invitation")
        }
        let credential = CoordinatorCredential(clientID: "fixture-client", token: "fixture-bearer")
        await #expect(throws: CoordinatorError.unauthorized) {
            try await client.account(at: endpoint, credential: credential)
        }
    }

    @Test func rejectsAnUnexpectedClientIdentityAndMalformedBearer() async throws {
        let endpoint = try CoordinatorEndpoint("https://pair.example")
        let client = client()
        let wrongClient = CoordinatorCredential(clientID: "other-client", token: "fixture-bearer")
        let malformed = CoordinatorCredential(clientID: "fixture-client", token: "fixture-bearer\r\n")
        await #expect(throws: CoordinatorError.unexpectedResponse) {
            try await client.account(at: endpoint, credential: wrongClient)
        }
        await #expect(throws: CoordinatorError.unexpectedResponse) {
            try await client.account(at: endpoint, credential: malformed)
        }
    }

    @Test func usesStableMessageIDForAuthenticatedReferenceSends() async throws {
        let endpoint = try CoordinatorEndpoint("https://teams.example")
        let api = ReferenceTeamClient(client: client(), endpoint: endpoint,
                                      credential: CoordinatorCredential(clientID: "fixture-client", token: "fixture-bearer"))
        let teams = try await api.teams()
        let team = try #require(teams.first)
        #expect(team.teamID == "0123456789abcdef0123456789abcdef")
        let draft = ReferenceDraft(messageID: "client-stable-id", text: "test", audience: .room, mentions: [.lead], replyTo: nil)
        try await api.send(draft, teamID: team.id)
        try await api.send(draft, teamID: team.id)
        await #expect(throws: CoordinatorError.unexpectedResponse) {
            try await api.send(draft, teamID: "../status")
        }
    }

    @Test func listsConnectedRoutinesAndUsesGETToReadTheReceipt() async throws {
        let endpoint = try CoordinatorEndpoint("https://solo.example")
        let api = SoloRoutineClient(client: client(), endpoint: endpoint,
                                    credential: .init(clientID: "fixture-client", token: "fixture-bearer"))
        #expect(try await api.routines().map(\.id) == ["demo"])
        let receipt = try await api.submit(routineID: "demo", taskID: soloFixtureTaskID, text: "  fixture input\n")
        #expect(receipt == SoloTaskReceipt(taskID: soloFixtureTaskID, state: .queued))
        #expect(try await api.status(routineID: "demo", taskID: receipt.taskID).state == .accepted)

        await #expect(throws: CoordinatorError.unexpectedResponse) {
            try await api.status(routineID: "../demo", taskID: receipt.taskID)
        }
        await #expect(throws: CoordinatorError.unexpectedResponse) {
            try await api.submit(routineID: "demo", taskID: receipt.taskID.uppercased(), text: "fixture")
        }
    }

    @Test(arguments: [SoloTaskState.rejected, .uncertain, .denied, .blocked])
    func readsSoloOutcomeWithoutReposting(state: SoloTaskState) async throws {
        let endpoint = try CoordinatorEndpoint("https://\(state.rawValue).example")
        let api = SoloRoutineClient(client: client(), endpoint: endpoint,
                                    credential: .init(clientID: "fixture-client", token: "fixture-bearer"))
        #expect(try await api.status(routineID: "demo", taskID: soloFixtureTaskID).state == state)
    }

    @Test func attachesWithExplicitConsentAndReadsAnAssignmentReceipt() async throws {
        let endpoint = try CoordinatorEndpoint("https://workspace-assistants.example")
        let workspace = WorkspaceClient(client: client(), endpoint: endpoint,
                                        credential: .init(clientID: "fixture-client", token: "fixture-bearer"))
        let api = WorkspaceAssistantClient(workspace: workspace)
        let binding = try await api.attachWithRoomConsent(routineID: "demo", workspaceID: soloFixtureTaskID)
        #expect(binding.provider == "grok-bot")
        let draft = WorkspaceAssistantClient.Draft(assistantID: binding.id, text: "  fixture input\n")
        let receipt = try await api.send(draft, workspaceID: soloFixtureTaskID)
        #expect(receipt.id == draft.id)
        #expect(receipt.state == .queued)
        let readback = try await api.status(assignmentID: receipt.id, workspaceID: soloFixtureTaskID)
        #expect(readback.state == .active)
        #expect(readback.result == nil)
        try await api.revoke(assistantID: binding.id, workspaceID: soloFixtureTaskID)
    }

    @Test(arguments: [
        ("http-error", CoordinatorError.httpStatus(503)),
        ("invalid", CoordinatorError.unexpectedResponse),
        ("wrong-service", CoordinatorError.unexpectedResponse),
        ("future-version", CoordinatorError.unsupportedProtocol(2)),
        ("starting", CoordinatorError.notReady),
        ("offline", CoordinatorError.unreachable),
        ("timeout", CoordinatorError.timedOut)
    ]) func reportsFailure(host: String, error: CoordinatorError) async throws {
        let endpoint = try CoordinatorEndpoint("https://\(host).example")
        await #expect(throws: error) { try await client().status(at: endpoint) }
    }

    private func client() -> CoordinatorClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StatusURLProtocol.self]
        return CoordinatorClient(configuration: configuration)
    }
}

private let soloFixtureTaskID = "01234567-abcd-4567-89ab-0123456789ab"

private final class StatusURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, url.query == nil,
              request.value(forHTTPHeaderField: "Accept") == "application/json",
              request.value(forHTTPHeaderField: "Cookie") == nil else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        switch url.path {
        case "/v1/workspaces" where request.httpMethod == "GET" && authorization == "Bearer fixture-bearer":
            respond(200, #"{"workspaces":[{"workspace_id":"\#(soloFixtureTaskID)","role":"member"}]}"#, url: url)
            return
        case "/v1/workspaces/\(soloFixtureTaskID)/messages" where authorization == "Bearer fixture-bearer":
            if request.httpMethod == "GET" {
                respond(200, #"{"messages":[{"message_id":"\#(soloFixtureTaskID)","text":"fixture direct message","author_id":"fixture-human","recipient_id":"cafe\u0301"}]}"#, url: url)
                return
            }
            guard request.httpMethod == "POST",
                  request.value(forHTTPHeaderField: "Content-Type") == "application/json",
                  let body = requestBody(), let fields = try? JSONDecoder().decode([String: String].self, from: body),
                  Set(fields.keys) == ["message_id", "text", "recipient_id"],
                  let identifier = fields["message_id"], Workspace.canonicalID(identifier) == identifier,
                  fields["text"] == "fixture direct message",
                  fields["recipient_id"]?.utf8.elementsEqual("cafe\u{0301}".utf8) == true else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            respond(201, #"{"message_id":"\#(identifier)"}"#, url: url)
            return
        case "/v1/solo/routines" where request.httpMethod == "GET" && authorization == "Bearer fixture-bearer":
            respond(200, #"{"routines":[{"routine_id":"demo","provider":"grok-bot"},{"routine_id":"../other","provider":"grok-bot"},{"routine_id":"fixture-other","provider":"other"}]}"#, url: url)
            return
        case "/v1/solo/routines/demo/tasks" where request.httpMethod == "POST" && authorization == "Bearer fixture-bearer"
            && request.value(forHTTPHeaderField: "Content-Type") == "application/json":
            let fields: NSDictionary = ["task_id": soloFixtureTaskID, "payload": ["text": "  fixture input\n"]]
            guard let body = requestBody(), let input = try? JSONSerialization.jsonObject(with: body) as? NSDictionary,
                  input == fields else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            respond(202, soloSnapshot(state: "queued"), url: url)
            return
        case "/v1/solo/routines/demo/tasks/\(soloFixtureTaskID)"
            where request.httpMethod == "GET" && authorization == "Bearer fixture-bearer":
            let state = url.host == "solo.example" ? "accepted" : url.host?.split(separator: ".").first.map(String.init) ?? ""
            respond(200, soloSnapshot(state: state), url: url)
            return
        case "/v1/workspaces/\(soloFixtureTaskID)/assistants"
            where request.httpMethod == "POST" && authorization == "Bearer fixture-bearer":
            let consent: NSDictionary = ["routine_id": "demo", "allow_room_assignments": true]
            if let body = requestBody(), let input = try? JSONSerialization.jsonObject(with: body) as? NSDictionary,
               input == consent {
                respond(201, #"{"assistant_id":"\#(soloFixtureTaskID)","provider":"grok-bot","capabilities":["task"],"native_session_observed":false}"#, url: url)
            } else {
                respond(400, "{}", url: url)
            }
            return
        case "/v1/workspaces/\(soloFixtureTaskID)/assistants/\(soloFixtureTaskID)/revoke"
            where request.httpMethod == "POST" && authorization == "Bearer fixture-bearer":
            respond(requestBody() == Data("{}".utf8) ? 200 : 400, #"{"revoked":true}"#, url: url)
            return
        case "/v1/workspaces/\(soloFixtureTaskID)/assignments"
            where request.httpMethod == "POST" && authorization == "Bearer fixture-bearer":
            guard let body = requestBody(), let input = try? JSONDecoder().decode([String: String].self, from: body),
                  Set(input.keys) == ["assignment_id", "assistant_id", "text"],
                  let id = input["assignment_id"], Workspace.canonicalID(id) == id,
                  input["assistant_id"] == soloFixtureTaskID, input["text"] == "  fixture input\n" else {
                respond(400, "{}", url: url)
                return
            }
            respond(202, assignmentSnapshot(id: id, state: "queued"), url: url)
            return
        case let path where path.hasPrefix("/v1/workspaces/\(soloFixtureTaskID)/assignments/")
            && request.httpMethod == "GET" && authorization == "Bearer fixture-bearer":
            respond(200, assignmentSnapshot(id: url.lastPathComponent, state: "active"), url: url)
            return
        case "/v1/reference-teams" where request.httpMethod == "GET" && authorization == "Bearer fixture-bearer":
            respond(200, #"{"teams":[{"teamID":"0123456789abcdef0123456789abcdef","mode":"reference","assistants":["lead","peer"],"runState":"running","turnLimit":12,"turnsUsed":0}]}"#, url: url)
            return
        case "/v1/reference-teams/0123456789abcdef0123456789abcdef/messages"
            where request.httpMethod == "POST" && authorization == "Bearer fixture-bearer"
            && request.value(forHTTPHeaderField: "Content-Type") == "application/json":
            guard let body = requestBody(), let draft = try? JSONDecoder().decode(ReferenceDraft.self, from: body),
                  draft.messageID == "client-stable-id", draft.audience == .room, draft.mentions == [.lead] else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            respond(200, #"{"messageID":"client-stable-id"}"#, url: url)
            return
        case "/v1/client/pair" where request.httpMethod == "POST" && authorization == nil
            && request.value(forHTTPHeaderField: "Content-Type") == "application/json":
            guard let body = requestBody(), let object = try? JSONDecoder().decode([String: String].self, from: body),
                  object == ["invitation": "fixture-invitation"] else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            if url.host == "denied.example" { respond(401, "{}", url: url) }
            else { respond(201, #"{"clientID":"fixture-client","token":"fixture-bearer"}"#, url: url) }
            return
        case "/v1/client/me" where request.httpMethod == "GET" && authorization == "Bearer fixture-bearer":
            if url.host == "denied.example" { respond(401, "{}", url: url) }
            else { respond(200, #"{"humanID":"fixture-human","clientID":"fixture-client","scopes":["sessions:read"]}"#, url: url) }
            return
        case "/v1/status" where request.httpMethod == "GET" && authorization == nil:
            break
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        if url.host == "offline.example" || url.host == "timeout.example" {
            let code: URLError.Code = url.host == "offline.example" ? .cannotConnectToHost : .timedOut
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }

        let (code, body): (Int, String) = switch url.host {
        case "ready.example": (200, #"{"service":"tachi","protocolVersion":1,"status":"ready"}"#)
        case "wrong-service.example": (200, #"{"service":"other","protocolVersion":1,"status":"ready"}"#)
        case "future-version.example": (200, #"{"service":"tachi","protocolVersion":2,"status":"ready"}"#)
        case "starting.example": (200, #"{"service":"tachi","protocolVersion":1,"status":"starting"}"#)
        case "http-error.example": (503, "")
        default: (200, "{}")
        }
        respond(code, body, url: url)
    }

    private func soloSnapshot(state: String) -> String {
        #"{"task_id":"\#(soloFixtureTaskID)","routine_id":"demo","state":"\#(state)","native_result_available":false,"result":null}"#
    }

    private func assignmentSnapshot(id: String, state: String) -> String {
        #"{"assignment_id":"\#(id)","assistant_id":"\#(soloFixtureTaskID)","author_id":"fixture-member","text":"  fixture input\n","state":"\#(state)","native_result_available":false,"result":null}"#
    }

    private func requestBody() -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { return body }
            body.append(contentsOf: buffer.prefix(count))
        }
    }

    private func respond(_ code: Int, _ body: String, url: URL) {
        let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
