import Foundation

public struct ReferenceTeamSummary: Encodable, Equatable, Sendable {
    public let teamID: String
    public let mode = "reference"
    public let assistants = ["lead", "peer"]
    public let runState: String
    public let turnLimit, turnsUsed: Int
}

public struct ReferenceDelivery: Encodable, Equatable, Sendable {
    public let assistant, state: String
    public let result: String?

    private enum CodingKeys: String, CodingKey { case assistant, state, result }
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(assistant, forKey: .assistant)
        try fields.encode(state, forKey: .state)
        try fields.encode(result, forKey: .result)
    }
}

public struct ReferenceMessage: Encodable, Equatable, Sendable {
    public let messageID: String
    public let author = "you"
    public let text, audience: String
    public let mentions: [String]
    public let replyTo: String?
    public let deliveries: [ReferenceDelivery]

    private enum CodingKeys: String, CodingKey { case messageID, author, text, audience, mentions, replyTo, deliveries }
    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(messageID, forKey: .messageID)
        try fields.encode(author, forKey: .author)
        try fields.encode(text, forKey: .text)
        try fields.encode(audience, forKey: .audience)
        try fields.encode(mentions, forKey: .mentions)
        try fields.encode(replyTo, forKey: .replyTo)
        try fields.encode(deliveries, forKey: .deliveries)
    }

    init?(_ record: MessageRecord, teamID: String, principal: QueuePrincipal) {
        guard sameID(record.author, "human:" + principal.humanID), case .string(let text) = record.payload["text"] else {
            return nil
        }
        if let direct = record.directTo {
            guard let alias = Self.alias(direct) else { return nil }
            audience = alias
        } else { audience = "room" }
        let mentions = record.mentions.compactMap(Self.alias)
        guard mentions.count == record.mentions.count else { return nil }
        self.messageID = record.messageID
        self.text = text
        self.mentions = mentions
        self.replyTo = record.replyTo
        self.deliveries = record.deliveries.compactMap { delivery in
            guard let alias = Self.alias(delivery.target), delivery.identity.provider == "tachi-reference",
                  sameID(delivery.identity.accountID, teamID), delivery.identity.assistantID == alias else { return nil }
            var result: String?
            for event in delivery.events where event.kind == .completed {
                if case let .integer(words) = event.payload["words"] {
                    result = "Reference \(alias) counted \(words) word\(words == 1 ? "" : "s")."
                }
            }
            return ReferenceDelivery(assistant: alias, state: delivery.state, result: result)
        }
    }

    private static func alias(_ address: String) -> String? {
        switch address {
        case "assistant:lead": "lead"
        case "assistant:peer": "peer"
        default: nil
        }
    }
}
