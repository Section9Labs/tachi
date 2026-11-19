import CoreFoundation
import Foundation
import NIOHTTP1

private struct Receipt: Codable {
    let issuer, subject, resource, sample: String
}

actor Plugin {
    private let config: Configuration
    private let oauth: OAuthResource
    private let version = "2025-06-18"
    private let tool = "read_connection_sample"

    init(_ config: Configuration) {
        self.config = config
        self.oauth = OAuthResource(config)
    }

    // The operator supplies one private directory per trial. Publish the completed
    // record exclusively so simultaneous workers and restarts see one receipt.
    private func sample() throws -> String {
        let files = FileManager.default
        let target = config.receiptFile
        if !files.fileExists(atPath: target.path) {
            let record = Receipt(issuer: config.issuer.absoluteString, subject: config.subject,
                                 resource: config.resource.absoluteString, sample: UUID().uuidString)
            let temp = target.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            try JSONEncoder().encode(record).write(to: temp, options: .withoutOverwriting)
            defer { try? files.removeItem(at: temp) }
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
            do { try files.linkItem(at: temp, to: target) }
            catch { guard files.fileExists(atPath: target.path) else { throw error } }
        }
        let record = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: target))
        guard record.subject.utf8.elementsEqual(config.subject.utf8),
              record.issuer.utf8.elementsEqual(config.issuer.absoluteString.utf8),
              record.resource.utf8.elementsEqual(config.resource.absoluteString.utf8),
              UUID(uuidString: record.sample) != nil else { throw PluginError.wrongTrial }
        return record.sample
    }

    func reply(_ request: NIOHTTPServerRequestFull) async -> Reply {
        let head = request.head
        // Only server-to-server MCP clients are supported. Reject cross-origin browser calls.
        guard head.headers["origin"].isEmpty else { return Reply(.forbidden) }
        if head.method == .GET, head.uri == config.metadata.path {
            return Reply(.ok, json: ["resource": config.resource.absoluteString,
                                     "authorization_servers": [config.issuer.absoluteString],
                                     "scopes_supported": ["sample.read"], "bearer_methods_supported": ["header"]])
        }
        guard head.uri == "/mcp" else { return Reply(.notFound) }
        guard head.method == .POST else { return Reply(.methodNotAllowed) }
        guard head.headers["content-type"].first?.lowercased().split(separator: ";").first == "application/json"
        else { return Reply(.unsupportedMediaType) }
        let versions = head.headers["mcp-protocol-version"]
        guard versions.isEmpty || versions == [version] else { return Reply(.badRequest) }
        let bytes = request.body.map { Data($0.readableBytesView) } ?? Data()
        guard let object = try? JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]) else {
            return failure(NSNull(), -32700, "Parse error")
        }
        guard let rpc = object as? [String: Any], rpc["jsonrpc"] as? String == "2.0",
              let method = rpc["method"] as? String else { return failure(NSNull(), -32600, "Invalid request") }
        guard let id = rpc["id"] else {
            return method.hasPrefix("notifications/") ? Reply(.accepted) : failure(NSNull(), -32600, "Missing request ID")
        }
        guard id is String || (id as? NSNumber).map({ CFGetTypeID($0) != CFBooleanGetTypeID() }) == true
        else { return failure(NSNull(), -32600, "Invalid request ID") }
        let params = rpc["params"] as? [String: Any] ?? [:]
        func success(_ result: [String: Any]) -> Reply {
            Reply(.ok, json: ["jsonrpc": "2.0", "id": id, "result": result])
        }
        switch method {
        case "initialize":
            guard params["protocolVersion"] is String else { return failure(id, -32602, "Missing protocol version") }
            return success(["protocolVersion": version, "capabilities": ["tools": [:]],
                            "serverInfo": ["name": "tachi-dot", "version": "0.1"]])
        case "ping":
            return success([:])
        case "tools/list":
            let schemes: [[String: Any]] = [["type": "oauth2", "scopes": ["sample.read"]]]
            return success(["tools": [[
                "name": tool, "description": "Read the synthetic connection receipt for this Tachi trial.",
                "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false],
                "annotations": ["readOnlyHint": true, "openWorldHint": false],
                "securitySchemes": schemes, "_meta": ["securitySchemes": schemes],
            ]]])
        case "tools/call":
            guard params["name"] as? String == tool,
                  params["arguments"] == nil || (params["arguments"] as? [String: Any])?.isEmpty == true
            else { return failure(id, -32602, "Unknown tool or invalid arguments") }
            let challenge = "Bearer resource_metadata=\"\(config.metadata.absoluteString)\", scope=\"sample.read\""
            func linkAccount(_ error: String) -> Reply {
                let description = "Connect the authorized Tachi trial account with sample.read access."
                let value = challenge + ", error=\"\(error)\", error_description=\"\(description)\""
                var reply = success(["isError": true, "content": [["type": "text", "text": description]],
                                     "_meta": ["mcp/www_authenticate": [value]]])
                reply.challenge = value
                return reply
            }
            do {
                let header = head.headers["authorization"]
                try await oauth.authorize(header.count == 1 ? header[0] : nil)
                let value = try sample()
                return success(["content": [["type": "text", "text": value]], "structuredContent": ["receipt": value]])
            } catch PluginError.unauthorized {
                return linkAccount("invalid_token")
            } catch PluginError.insufficientScope {
                return linkAccount("insufficient_scope")
            } catch {
                return Reply(.serviceUnavailable)
            }
        default:
            return failure(id, -32601, "Method not found")
        }
    }

    private func failure(_ id: Any, _ code: Int, _ message: String) -> Reply {
        Reply(.ok, json: ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }
}
