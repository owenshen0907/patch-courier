import Foundation

enum MailroomCapability: String, Codable, CaseIterable, Sendable {
    case readOnly
    case writeWorkspace
    case executeShell
    case networkedAccess
}

enum MailroomThreadStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case active
    case waitingOnUser
    case waitingOnApproval
    case completed
    case failed
    case archived
}

enum MailroomPendingThreadStage: String, Codable, CaseIterable, Sendable {
    case firstDecision
    case projectSelection
}

enum MailroomApprovalKind: String, Codable, CaseIterable, Sendable {
    case commandExecution
    case fileChange
    case userInput
    case permissions
    case other
}

enum MailroomApprovalStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case resolved
    case expired
}

enum MailroomTurnOutcomeState: String, Codable, CaseIterable, Sendable {
    case completed
    case waitingOnApproval
    case waitingOnUserInput
    case failed
    case systemError

    var requiresApprovalNotificationIdentity: Bool {
        switch self {
        case .waitingOnApproval, .waitingOnUserInput:
            return true
        case .completed, .failed, .systemError:
            return false
        }
    }
}

enum MailroomTurnOrigin: String, Codable, CaseIterable, Sendable {
    case newMail
    case reply
    case localConsole

    var isMailDriven: Bool {
        switch self {
        case .newMail, .reply:
            return true
        case .localConsole:
            return false
        }
    }
}

enum MailroomTurnStatus: String, Codable, CaseIterable, Sendable {
    case active
    case waitingOnApproval
    case waitingOnUserInput
    case completed
    case failed
    case systemError

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .systemError:
            return true
        case .active, .waitingOnApproval, .waitingOnUserInput:
            return false
        }
    }

    var notificationOutcomeState: MailroomTurnOutcomeState? {
        switch self {
        case .active:
            return nil
        case .waitingOnApproval:
            return .waitingOnApproval
        case .waitingOnUserInput:
            return .waitingOnUserInput
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .systemError:
            return .systemError
        }
    }
}

struct MailroomThreadSeed: Hashable, Sendable {
    var mailboxID: String
    var normalizedSender: String
    var subject: String
    var workspaceRoot: String
    var capability: MailroomCapability
}

struct MailroomThreadRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var mailboxID: String
    var normalizedSender: String
    var subject: String
    var codexThreadID: String?
    var workspaceRoot: String
    var capability: MailroomCapability
    var status: MailroomThreadStatus
    var pendingStage: MailroomPendingThreadStage?
    var pendingPromptBody: String?
    var managedProjectID: String?
    var lastInboundMessageID: String?
    var lastOutboundMessageID: String?
    var createdAt: Date
    var updatedAt: Date

    var tokenLabel: String {
        "[patch-courier:\(id)]"
    }
}

struct OutboundMailEnvelope: Codable, Hashable, Sendable {
    var to: [String]
    var subject: String
    var plainBody: String
    var htmlBody: String? = nil
    var inReplyTo: String?
    var references: [String]
}

struct MailroomApprovalRequest: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var rpcRequestID: JSONRPCID
    var kind: MailroomApprovalKind
    var mailThreadToken: String?
    var codexThreadID: String
    var codexTurnID: String
    var itemID: String
    var summary: String
    var detail: String?
    var availableDecisions: [String]
    var rawPayload: JSONValue
    var status: MailroomApprovalStatus
    var resolvedDecision: String?
    var resolutionNote: String?
    var createdAt: Date
    var resolvedAt: Date?
}

struct ParsedApprovalReply: Codable, Hashable, Sendable {
    var requestID: String
    var decision: String?
    var answers: [String: [String]]
    var note: String?
}

struct MailroomEventRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var source: String
    var method: String
    var codexThreadID: String?
    var codexTurnID: String?
    var payload: JSONValue
    var createdAt: Date
}

struct MailroomMailboxSyncCursor: Identifiable, Codable, Hashable, Sendable {
    var accountID: String
    var lastSeenUID: UInt64?
    var lastProcessedAt: Date?

    var id: String { accountID }
}

struct MailroomTurnRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var mailThreadToken: String?
    var codexThreadID: String
    var origin: MailroomTurnOrigin
    var status: MailroomTurnStatus
    var promptPreview: String?
    var lastNotifiedState: MailroomTurnOutcomeState?
    var lastNotifiedApprovalID: String?
    var lastNotificationMessageID: String?
    var startedAt: Date
    var completedAt: Date?
    var updatedAt: Date

    func hasRecordedNotification(state: MailroomTurnOutcomeState, approvalID: String?) -> Bool {
        guard lastNotifiedState == state else {
            return false
        }
        guard state.requiresApprovalNotificationIdentity else {
            return true
        }
        guard let lastNotifiedApprovalID else {
            // Older databases only stored the state. Treat same-state waiting turns as notified
            // to avoid a one-time duplicate approval email after upgrade.
            return true
        }
        return lastNotifiedApprovalID == approvalID
    }
}

struct MailroomTurnOutcome: Codable, Hashable, Sendable {
    var state: MailroomTurnOutcomeState
    var mailThreadToken: String?
    var codexThreadID: String
    var turnID: String
    var finalAnswer: String?
    var approvalID: String?
    var approvalKind: MailroomApprovalKind?
    var approvalSummary: String?
    var turnStatus: JSONValue?
    var threadStatus: JSONValue?
    var turnError: JSONValue?
}

protocol ThreadStore: Sendable {
    func save(thread: MailroomThreadRecord) async throws
    func thread(token: String) async throws -> MailroomThreadRecord?
    func thread(codexThreadID: String) async throws -> MailroomThreadRecord?
    func allThreads() async throws -> [MailroomThreadRecord]
}

protocol ApprovalStore: Sendable {
    func save(approval: MailroomApprovalRequest) async throws
    func approval(id: String) async throws -> MailroomApprovalRequest?
    func allApprovals() async throws -> [MailroomApprovalRequest]
}

protocol EventStore: Sendable {
    func append(event: MailroomEventRecord) async throws
    func allEvents() async throws -> [MailroomEventRecord]
}

protocol MailboxSyncStore: Sendable {
    func save(syncCursor: MailroomMailboxSyncCursor) async throws
    func syncCursor(accountID: String) async throws -> MailroomMailboxSyncCursor?
    func allSyncCursors() async throws -> [MailroomMailboxSyncCursor]
}

protocol MailboxMessageStore: Sendable {
    func save(mailboxMessage: MailroomMailboxMessageRecord) async throws
    func mailboxMessage(mailboxID: String, uid: UInt64) async throws -> MailroomMailboxMessageRecord?
    func recentMailboxMessages(limit: Int, mailboxID: String?) async throws -> [MailroomMailboxMessageRecord]
}

protocol MailboxPollIncidentStore: Sendable {
    func save(pollIncident: MailroomMailboxPollIncidentRecord) async throws
    func resolveOpenPollIncidents(accountID: String, resolvedAt: Date) async throws
    func recentPollIncidents(limit: Int, mailboxID: String?) async throws -> [MailroomMailboxPollIncidentRecord]
}

protocol TurnStore: Sendable {
    func save(turn: MailroomTurnRecord) async throws
    func turn(id: String) async throws -> MailroomTurnRecord?
    func allTurns() async throws -> [MailroomTurnRecord]
}

protocol MailboxAccountConfigStore: Sendable {
    func allMailboxAccounts() async throws -> [MailboxAccount]
    func upsertMailboxAccount(_ account: MailboxAccount) async throws
    func deleteMailboxAccount(accountID: String) async throws
}

protocol SenderPolicyConfigStore: Sendable {
    func allSenderPolicies() async throws -> [SenderPolicy]
    func upsertSenderPolicy(_ policy: SenderPolicy) async throws
    func deleteSenderPolicy(policyID: String) async throws
}

protocol ManagedProjectConfigStore: Sendable {
    func allManagedProjects() async throws -> [ManagedProject]
    func upsertManagedProject(_ project: ManagedProject) async throws
    func deleteManagedProject(projectID: String) async throws
}
