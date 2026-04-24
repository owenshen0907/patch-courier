import Foundation

enum MailroomMailboxMessageAction: String, Codable, Hashable, Sendable {
    case received
    case ignored
    case historical
    case challenged
    case recorded
    case completed
    case approvalRequested
    case rejected
    case failed
}

struct InboundMailMessage: Identifiable, Codable, Hashable, Sendable {
    var uid: UInt64
    var messageID: String
    var fromAddress: String
    var fromDisplayName: String?
    var subject: String
    var plainBody: String
    var receivedAt: Date
    var inReplyTo: String?
    var references: [String]

    var id: String { messageID }

    private enum CodingKeys: String, CodingKey {
        case uid
        case messageID = "message_id"
        case fromAddress = "from_address"
        case fromDisplayName = "from_display_name"
        case subject
        case plainBody = "plain_body"
        case receivedAt = "received_at"
        case inReplyTo = "in_reply_to"
        case references
    }
}

struct MailroomMailboxMessageRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var mailboxID: String
    var mailboxLabel: String?
    var mailboxEmailAddress: String?
    var uid: UInt64
    var messageID: String
    var fromAddress: String
    var fromDisplayName: String?
    var subject: String
    var plainBody: String
    var receivedAt: Date
    var inReplyTo: String?
    var references: [String]
    var threadToken: String?
    var action: MailroomMailboxMessageAction
    var outboundMessageID: String?
    var note: String
    var processedAt: Date?
    var updatedAt: Date

    static func makeID(mailboxID: String, uid: UInt64) -> String {
        "\(mailboxID):\(uid)"
    }
}

struct MailroomMailboxPollIncidentRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var mailboxID: String
    var mailboxLabel: String?
    var mailboxEmailAddress: String?
    var phase: String
    var message: String
    var lastSeenUID: UInt64?
    var retryAt: Date?
    var occurredAt: Date
    var resolvedAt: Date?
    var updatedAt: Date
}

struct OutboundMailMessage: Codable, Hashable, Sendable {
    var to: [String]
    var subject: String
    var plainBody: String
    var htmlBody: String? = nil
    var inReplyTo: String?
    var references: [String]
}

struct MailFetchResult: Codable, Hashable, Sendable {
    var lastUID: UInt64?
    var messages: [InboundMailMessage]
    var didBootstrap: Bool

    private enum CodingKeys: String, CodingKey {
        case lastUID = "last_uid"
        case messages
        case didBootstrap = "did_bootstrap"
    }
}

struct MailHistoryResult: Codable, Hashable, Sendable {
    var visibleCount: Int
    var messages: [InboundMailMessage]

    private enum CodingKeys: String, CodingKey {
        case visibleCount = "visible_count"
        case messages
    }
}

struct MailSendResult: Codable, Hashable, Sendable {
    var messageID: String?

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
    }
}

struct MailroomRuntimeState: Codable, Hashable, Sendable {
    var syncStates: [MailboxSyncState]
    var conversations: [MailConversationRecord]

    static let empty = MailroomRuntimeState(syncStates: [], conversations: [])
}

struct MailboxSyncState: Identifiable, Codable, Hashable, Sendable {
    var accountID: String
    var lastSeenUID: UInt64?
    var lastProcessedAt: Date?

    var id: String { accountID }
}

enum MailConversationStatus: String, Codable, CaseIterable, Sendable {
    case waitingForToken
    case waitingForUser
    case queuedReview
    case completed
    case rejected
}

struct MailConversationRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var mailboxAccountID: String
    var senderAddress: String
    var subject: String
    var workspaceRoot: String
    var capability: MailCapability
    var latestJobID: String?
    var originalRequestBody: String
    var latestAssistantSummary: String?
    var latestAssistantBody: String?
    var latestQuestionBody: String?
    var lastInboundMessageID: String?
    var lastOutboundMessageID: String?
    var status: MailConversationStatus
    var createdAt: Date
    var updatedAt: Date

    var tokenLabel: String {
        "[patch-courier:\(id)]"
    }
}

enum MailroomAgentResponseKind: String, Codable, Sendable {
    case final
    case needInput
}

struct MailroomAgentResponse: Codable, Hashable, Sendable {
    var kind: MailroomAgentResponseKind
    var subject: String
    var summary: String
    var body: String
    var rawText: String

    static func fallback(subject: String, rawText: String, status: MailJobStatus) -> MailroomAgentResponse {
        let summary: String
        switch status {
        case .succeeded:
            summary = LT(
                "Codex finished the request and prepared a mail reply.",
                "Codex 已完成请求，并准备好了邮件回复。",
                "Codex が要求を完了し、メール返信を用意した。"
            )
        case .failed:
            summary = LT(
                "Codex stopped before it could prepare a successful reply.",
                "Codex 在准备成功回复前停止了。",
                "Codex は正常な返信を準備する前に停止した。"
            )
        default:
            summary = LT(
                "Codex returned an unexpected state.",
                "Codex 返回了意外状态。",
                "Codex が想定外の状態を返した。"
            )
        }

        return MailroomAgentResponse(
            kind: .final,
            subject: subject,
            summary: summary,
            body: rawText.trimmingCharacters(in: .whitespacesAndNewlines),
            rawText: rawText
        )
    }
}

struct MailroomParsedCommand: Hashable, Sendable {
    var cleanedSubject: String
    var workspaceRoot: String
    var capability: MailCapability
    var actionSummary: String
    var promptBody: String
    var explicitPromptBody: String?
    var projectReference: String?
    var detectedToken: String?
}

struct MailroomSyncOutcome: Sendable {
    var processedJobs: [ExecutionJobRecord]
    var ignoredCount: Int
    var needsReload: Bool
    var statusMessage: String?

    var latestJobID: String? {
        processedJobs.last?.id
    }
}
