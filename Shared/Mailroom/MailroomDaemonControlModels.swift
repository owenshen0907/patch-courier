import Foundation

struct MailroomDaemonControlFile: Codable, Hashable, Sendable {
    var host: String
    var port: UInt16
    var authToken: String
    var pid: Int32
    var startedAt: Date
}

enum MailroomDaemonControlMethod: String, Codable, Hashable, Sendable {
    case readState = "state/read"
    case resolveApproval = "approval/resolve"
    case resolveThreadDecision = "thread/resolve-decision"
    case upsertMailboxAccount = "config/mailbox-account/upsert"
    case deleteMailboxAccount = "config/mailbox-account/delete"
    case upsertSenderPolicy = "config/sender-policy/upsert"
    case deleteSenderPolicy = "config/sender-policy/delete"
    case upsertManagedProject = "config/managed-project/upsert"
    case deleteManagedProject = "config/managed-project/delete"
}

struct MailroomDaemonStateReadParams: Codable, Hashable, Sendable {
    static let `default` = MailroomDaemonStateReadParams()
}

struct MailroomDaemonResolveApprovalParams: Codable, Hashable, Sendable {
    var approvalID: String
    var decision: String?
    var answers: [String: [String]]
    var note: String?
}

enum MailroomDaemonThreadDecision: String, Codable, Hashable, Sendable {
    case startTask
    case recordOnly
}

struct MailroomDaemonResolveThreadDecisionParams: Codable, Hashable, Sendable {
    var threadToken: String
    var decision: MailroomDaemonThreadDecision
    var task: String?
}

struct MailroomDaemonMailboxAccountSummary: Codable, Hashable, Sendable {
    var account: MailboxAccount
    var hasPasswordStored: Bool
}

struct MailroomDaemonMailboxHealthSummary: Identifiable, Codable, Hashable, Sendable {
    var accountID: String
    var label: String
    var emailAddress: String
    var pollingIntervalSeconds: Int
    var hasPasswordStored: Bool
    var state: String
    var lastPollStartedAt: Date?
    var lastPollCompletedAt: Date?
    var nextPollAt: Date?
    var lastFetchedCount: Int
    var lastQueuedCount: Int
    var lastSeenUID: UInt64?
    var lastProcessedAt: Date?
    var lastError: String?
    var updatedAt: Date

    var id: String { accountID }
}

struct MailroomDaemonUpsertMailboxAccountParams: Codable, Hashable, Sendable {
    var account: MailboxAccount
    var password: String?
}

struct MailroomDaemonDeleteMailboxAccountParams: Codable, Hashable, Sendable {
    var accountID: String
}

struct MailroomDaemonUpsertSenderPolicyParams: Codable, Hashable, Sendable {
    var policy: SenderPolicy
}

struct MailroomDaemonDeleteSenderPolicyParams: Codable, Hashable, Sendable {
    var policyID: String
}

struct MailroomDaemonUpsertManagedProjectParams: Codable, Hashable, Sendable {
    var project: ManagedProject
}

struct MailroomDaemonDeleteManagedProjectParams: Codable, Hashable, Sendable {
    var projectID: String
}

struct MailroomDaemonControlRequest: Codable, Hashable, Sendable {
    var id: String
    var token: String
    var method: MailroomDaemonControlMethod
    var stateRead: MailroomDaemonStateReadParams?
    var resolveApproval: MailroomDaemonResolveApprovalParams?
    var resolveThreadDecision: MailroomDaemonResolveThreadDecisionParams?
    var upsertMailboxAccount: MailroomDaemonUpsertMailboxAccountParams?
    var deleteMailboxAccount: MailroomDaemonDeleteMailboxAccountParams?
    var upsertSenderPolicy: MailroomDaemonUpsertSenderPolicyParams?
    var deleteSenderPolicy: MailroomDaemonDeleteSenderPolicyParams?
    var upsertManagedProject: MailroomDaemonUpsertManagedProjectParams?
    var deleteManagedProject: MailroomDaemonDeleteManagedProjectParams?
}

struct MailroomDaemonControlError: Codable, Hashable, Sendable {
    var message: String
}

struct MailroomDaemonControlResponse: Codable, Hashable, Sendable {
    var id: String
    var snapshot: MailroomDaemonStateSnapshot?
    var error: MailroomDaemonControlError?
}

struct MailroomDaemonWorkerSummary: Identifiable, Codable, Hashable, Sendable {
    var workerKey: String
    var mailboxID: String
    var mailboxAddress: String
    var isActive: Bool
    var queuedItemCount: Int
    var currentMessageID: String?
    var currentSender: String?
    var currentSubject: String?
    var currentReceivedAt: Date?
    var currentThreadToken: String?
    var lastError: String?
    var updatedAt: Date

    var id: String { workerKey }

    var laneKind: String {
        if workerKey.hasPrefix("thread:") {
            return "thread"
        }
        if workerKey.hasPrefix("codex:") {
            return "codex"
        }
        if workerKey.hasPrefix("message:") {
            return "message"
        }
        return "worker"
    }

    var laneValue: String {
        guard let separator = workerKey.firstIndex(of: ":") else {
            return workerKey
        }
        return String(workerKey[workerKey.index(after: separator)...])
    }

    var displayThreadToken: String? {
        if let currentThreadToken, !currentThreadToken.isEmpty {
            return currentThreadToken
        }
        if laneKind == "thread" {
            return laneValue
        }
        return nil
    }
}

struct MailroomDaemonRecentMessageSummary: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var accountID: String
    var mailboxLabel: String
    var mailboxEmailAddress: String
    var uid: UInt64
    var messageID: String
    var sender: String
    var subject: String
    var action: String
    var threadToken: String?
    var outboundMessageID: String?
    var note: String
    var receivedAt: Date
    var processedAt: Date
}

struct MailroomDaemonStateSnapshot: Codable, Hashable, Sendable {
    var generatedAt: Date
    var supportRoot: String
    var databasePath: String
    var mailboxAccounts: [MailroomDaemonMailboxAccountSummary]
    var mailboxHealth: [MailroomDaemonMailboxHealthSummary]
    var senderPolicies: [SenderPolicy]
    var managedProjects: [ManagedProject]
    var workers: [MailroomDaemonWorkerSummary]
    var activeWorkerKeys: [String]
    var queuedWorkItemCount: Int
    var threads: [MailroomDaemonThreadSummary]
    var turns: [MailroomDaemonTurnSummary]
    var approvals: [MailroomDaemonApprovalSummary]
    var syncCursors: [MailroomDaemonSyncCursorSummary]
    var mailboxMessages: [MailroomMailboxMessageRecord]
    var mailboxPollIncidents: [MailroomMailboxPollIncidentRecord]
    var recentMailActivity: [MailroomDaemonRecentMessageSummary]

    private enum CodingKeys: String, CodingKey {
        case generatedAt
        case supportRoot
        case databasePath
        case mailboxAccounts
        case mailboxHealth
        case senderPolicies
        case managedProjects
        case workers
        case activeWorkerKeys
        case queuedWorkItemCount
        case threads
        case turns
        case approvals
        case syncCursors
        case mailboxMessages
        case mailboxPollIncidents
        case recentMailActivity
    }

    init(
        generatedAt: Date,
        supportRoot: String,
        databasePath: String,
        mailboxAccounts: [MailroomDaemonMailboxAccountSummary],
        mailboxHealth: [MailroomDaemonMailboxHealthSummary],
        senderPolicies: [SenderPolicy],
        managedProjects: [ManagedProject],
        workers: [MailroomDaemonWorkerSummary],
        activeWorkerKeys: [String],
        queuedWorkItemCount: Int,
        threads: [MailroomDaemonThreadSummary],
        turns: [MailroomDaemonTurnSummary],
        approvals: [MailroomDaemonApprovalSummary],
        syncCursors: [MailroomDaemonSyncCursorSummary],
        mailboxMessages: [MailroomMailboxMessageRecord],
        mailboxPollIncidents: [MailroomMailboxPollIncidentRecord],
        recentMailActivity: [MailroomDaemonRecentMessageSummary]
    ) {
        self.generatedAt = generatedAt
        self.supportRoot = supportRoot
        self.databasePath = databasePath
        self.mailboxAccounts = mailboxAccounts
        self.mailboxHealth = mailboxHealth
        self.senderPolicies = senderPolicies
        self.managedProjects = managedProjects
        self.workers = workers
        self.activeWorkerKeys = activeWorkerKeys
        self.queuedWorkItemCount = queuedWorkItemCount
        self.threads = threads
        self.turns = turns
        self.approvals = approvals
        self.syncCursors = syncCursors
        self.mailboxMessages = mailboxMessages
        self.mailboxPollIncidents = mailboxPollIncidents
        self.recentMailActivity = recentMailActivity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        supportRoot = try container.decode(String.self, forKey: .supportRoot)
        databasePath = try container.decode(String.self, forKey: .databasePath)
        mailboxAccounts = try container.decodeIfPresent([MailroomDaemonMailboxAccountSummary].self, forKey: .mailboxAccounts) ?? []
        mailboxHealth = try container.decodeIfPresent([MailroomDaemonMailboxHealthSummary].self, forKey: .mailboxHealth) ?? []
        senderPolicies = try container.decodeIfPresent([SenderPolicy].self, forKey: .senderPolicies) ?? []
        managedProjects = try container.decodeIfPresent([ManagedProject].self, forKey: .managedProjects) ?? []
        workers = try container.decodeIfPresent([MailroomDaemonWorkerSummary].self, forKey: .workers) ?? []
        activeWorkerKeys = try container.decodeIfPresent([String].self, forKey: .activeWorkerKeys) ?? []
        queuedWorkItemCount = try container.decodeIfPresent(Int.self, forKey: .queuedWorkItemCount) ?? 0
        threads = try container.decodeIfPresent([MailroomDaemonThreadSummary].self, forKey: .threads) ?? []
        turns = try container.decodeIfPresent([MailroomDaemonTurnSummary].self, forKey: .turns) ?? []
        approvals = try container.decodeIfPresent([MailroomDaemonApprovalSummary].self, forKey: .approvals) ?? []
        syncCursors = try container.decodeIfPresent([MailroomDaemonSyncCursorSummary].self, forKey: .syncCursors) ?? []
        mailboxMessages = try container.decodeIfPresent([MailroomMailboxMessageRecord].self, forKey: .mailboxMessages) ?? []
        mailboxPollIncidents = try container.decodeIfPresent([MailroomMailboxPollIncidentRecord].self, forKey: .mailboxPollIncidents) ?? []
        recentMailActivity = try container.decodeIfPresent([MailroomDaemonRecentMessageSummary].self, forKey: .recentMailActivity) ?? []
    }
}

struct MailroomDaemonThreadSummary: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var mailboxID: String
    var normalizedSender: String
    var subject: String
    var workspaceRoot: String
    var capability: String
    var status: String
    var pendingStage: String?
    var managedProjectID: String?
    var managedProjectName: String?
    var lastInboundMessageID: String?
    var lastOutboundMessageID: String?
    var updatedAt: Date
}

struct MailroomDaemonTurnSummary: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var mailThreadToken: String?
    var codexThreadID: String
    var origin: String
    var status: String
    var promptPreview: String?
    var lastNotifiedState: String?
    var lastNotifiedApprovalID: String?
    var lastNotificationMessageID: String?
    var startedAt: Date
    var completedAt: Date?
    var updatedAt: Date
}

struct MailroomDaemonApprovalOptionSummary: Codable, Hashable, Sendable {
    var label: String
    var description: String
}

struct MailroomDaemonApprovalQuestionSummary: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var header: String
    var question: String
    var isOther: Bool
    var isSecret: Bool
    var options: [MailroomDaemonApprovalOptionSummary]
}

struct MailroomDaemonApprovalSummary: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var kind: String
    var status: String
    var mailThreadToken: String?
    var codexThreadID: String
    var codexTurnID: String
    var itemID: String
    var summary: String
    var detail: String?
    var availableDecisions: [String]
    var resolvedDecision: String?
    var resolutionNote: String?
    var createdAt: Date
    var resolvedAt: Date?
    var questions: [MailroomDaemonApprovalQuestionSummary]
}

struct MailroomDaemonSyncCursorSummary: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var lastSeenUID: UInt64?
    var lastProcessedAt: Date?
}
