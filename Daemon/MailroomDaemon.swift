import Foundation

struct MailroomDaemonConfiguration: Sendable {
    var codexExecutableCandidates: [String]
    var supportRoot: String
    var databasePath: String
    var codexHome: String
    var bootstrapSourceHome: String?
    var mailboxAccountsPath: String
    var senderPoliciesPath: String
    var mailTransportScriptPath: String
    var workingDirectory: String
    var defaultWorkspaceRoot: String
    var defaultModel: String
    var defaultSandbox: CodexSandboxMode
    var defaultApprovalPolicy: CodexApprovalPolicy
    var clientInfo: ClientInfo
    var additionalEnvironment: [String: String]

    static func `default`() -> MailroomDaemonConfiguration {
        let environment = ProcessInfo.processInfo.environment
        let supportRootURL = environment["MAILROOM_SUPPORT_ROOT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/PatchCourier", isDirectory: true)

        let currentDirectory = FileManager.default.currentDirectoryPath
        let fallbackDirectory = FileManager.default.fileExists(atPath: currentDirectory) ? currentDirectory : NSHomeDirectory()
        let workingDirectory = environment["MAILROOM_WORKDIR"] ?? fallbackDirectory
        let workspaceRoot = environment["MAILROOM_WORKSPACE_ROOT"] ?? fallbackDirectory
        let defaultSourceHome = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
            .path

        return MailroomDaemonConfiguration(
            codexExecutableCandidates: [
                environment["CODEX_CLI_PATH"],
                "/Applications/Codex.app/Contents/Resources/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex"
            ].compactMap { $0 },
            supportRoot: supportRootURL.path,
            databasePath: environment["MAILROOM_DATABASE_PATH"] ?? supportRootURL.appendingPathComponent("mailroom.sqlite3").path,
            codexHome: environment["MAILROOM_CODEX_HOME"] ?? supportRootURL.appendingPathComponent("CodexHome", isDirectory: true).path,
            bootstrapSourceHome: environment["MAILROOM_CODEX_PROFILE_HOME"] ?? environment["CODEX_HOME"] ?? defaultSourceHome,
            mailboxAccountsPath: environment["MAILROOM_ACCOUNTS_PATH"] ?? supportRootURL.appendingPathComponent("mailbox-accounts.json").path,
            senderPoliciesPath: environment["MAILROOM_POLICIES_PATH"] ?? supportRootURL.appendingPathComponent("sender-policies.json").path,
            mailTransportScriptPath: environment["MAILROOM_TRANSPORT_SCRIPT_PATH"] ?? supportRootURL.appendingPathComponent("runtime-tools/mail_transport.py").path,
            workingDirectory: workingDirectory,
            defaultWorkspaceRoot: workspaceRoot,
            defaultModel: "gpt-5.4",
            defaultSandbox: .workspaceWrite,
            defaultApprovalPolicy: .onRequest,
            clientInfo: ClientInfo(name: "mailroomd", version: "0.2.0", title: "Patch Courier Daemon"),
            additionalEnvironment: [:]
        )
    }

    func makeTransportConfiguration() -> CodexAppServerTransport.Configuration {
        .init(
            executableCandidates: codexExecutableCandidates,
            codexHome: codexHome,
            bootstrapSourceHome: bootstrapSourceHome,
            workingDirectory: workingDirectory,
            additionalEnvironment: additionalEnvironment
        )
    }
}

struct MailroomStartedThread: Codable, Hashable, Sendable {
    var thread: MailroomThreadRecord
    var turn: CodexTurnDescriptor?
}

enum MailroomDaemonError: LocalizedError {
    case blankPrompt
    case missingThread(String)
    case missingCodexThread(String)
    case approvalReplyParseFailed
    case approvalNotFound(String)
    case approvalDecisionMissing(String)
    case approvalAnswersMissing(String)
    case invalidDecision(String, allowed: [String])
    case unsupportedApprovalKind(MailroomApprovalKind)

    var errorDescription: String? {
        switch self {
        case .blankPrompt:
            return "The prompt is blank."
        case .missingThread(let token):
            return "No stored Mailroom thread exists for token \(token)."
        case .missingCodexThread(let token):
            return "Mailroom thread \(token) is missing its Codex thread id."
        case .approvalReplyParseFailed:
            return "The approval reply could not be parsed."
        case .approvalNotFound(let id):
            return "No stored approval request exists for id \(id)."
        case .approvalDecisionMissing(let id):
            return "Approval \(id) needs a DECISION field."
        case .approvalAnswersMissing(let id):
            return "Approval \(id) needs at least one ANSWER_<id> field."
        case .invalidDecision(let decision, let allowed):
            return "Decision '\(decision)' is invalid. Allowed values: \(allowed.joined(separator: ", "))."
        case .unsupportedApprovalKind(let kind):
            return "Approval kind '\(kind.rawValue)' is not wired yet."
        }
    }
}

private enum PendingTurnSignal: Sendable {
    case completed(CodexTurnCompletedNotification)
    case approval(MailroomApprovalRequest)
    case systemError(threadID: String, status: JSONValue)
}

private struct PendingTurnWaiter {
    var threadID: String
    var continuation: CheckedContinuation<PendingTurnSignal, Error>
}

actor MailroomDaemon {
    struct ProbeSummary: Codable, Hashable, Sendable {
        var supportRoot: String
        var databasePath: String
        var codexHome: String
        var platform: String
        var userAgent: String
        var threadID: String
        var threadPath: String?
    }

    struct QueuedMailWorkItem: Sendable {
        var workerKey: String
        var account: MailboxAccount
        var message: InboundMailMessage
    }

    struct MailWorkerRuntimeState: Sendable {
        var workerKey: String
        var mailboxID: String
        var mailboxAddress: String
        var isActive: Bool
        var currentMessageID: String?
        var currentSender: String?
        var currentSubject: String?
        var currentReceivedAt: Date?
        var currentThreadToken: String?
        var lastError: String?
        var updatedAt: Date
    }

    struct MailboxPollRuntimeState: Sendable {
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
        var lastError: String?
        var updatedAt: Date
    }

    let configuration: MailroomDaemonConfiguration
    let threadStore: ThreadStore
    let turnStore: TurnStore
    let approvalStore: ApprovalStore
    let eventStore: EventStore
    let syncStore: MailboxSyncStore
    let mailboxMessageStore: MailboxMessageStore
    let accountStore: MailboxAccountConfigStore
    let senderPolicyStore: SenderPolicyConfigStore
    let managedProjectStore: ManagedProjectConfigStore
    let appServer: CodexAppServerClient
    let legacyAccountStore: MailboxAccountStore
    let legacySenderPolicyStore: SenderPolicyStore
    let secretStore: KeychainSecretStore
    let transportClient: MailTransportClient

    private var eventTask: Task<Void, Never>?
    private var initializeResponse: InitializeResponse?
    private var pendingTurnWaiters: [String: PendingTurnWaiter] = [:]
    var queuedMailWorkByWorkerKey: [String: [QueuedMailWorkItem]] = [:]
    var activeMailWorkerTasks: [String: Task<Void, Never>] = [:]
    var mailWorkerStates: [String: MailWorkerRuntimeState] = [:]
    var mailboxPollStates: [String: MailboxPollRuntimeState] = [:]
    var recentMailActivity: [MailroomDaemonRecentMessageSummary] = []
    var nextPollAtByAccount: [String: Date] = [:]
    private var recoveryTurnTasks: [String: Task<Void, Never>] = [:]
    private var controlServer: MailroomControlServer?
    private var didStartPersistentRecovery = false

    init(
        configuration: MailroomDaemonConfiguration,
        threadStore: ThreadStore,
        turnStore: TurnStore,
        approvalStore: ApprovalStore,
        eventStore: EventStore,
        syncStore: MailboxSyncStore,
        mailboxMessageStore: MailboxMessageStore,
        accountStore: MailboxAccountConfigStore,
        senderPolicyStore: SenderPolicyConfigStore,
        managedProjectStore: ManagedProjectConfigStore
    ) {
        self.configuration = configuration
        self.threadStore = threadStore
        self.turnStore = turnStore
        self.approvalStore = approvalStore
        self.eventStore = eventStore
        self.syncStore = syncStore
        self.mailboxMessageStore = mailboxMessageStore
        self.accountStore = accountStore
        self.senderPolicyStore = senderPolicyStore
        self.managedProjectStore = managedProjectStore
        self.appServer = CodexAppServerClient(
            transport: CodexAppServerTransport(configuration: configuration.makeTransportConfiguration()),
            clientInfo: configuration.clientInfo
        )
        self.legacyAccountStore = MailboxAccountStore(accountsURL: URL(fileURLWithPath: configuration.mailboxAccountsPath))
        self.legacySenderPolicyStore = SenderPolicyStore(fileURL: URL(fileURLWithPath: configuration.senderPoliciesPath))
        self.secretStore = KeychainSecretStore()
        self.transportClient = MailTransportClient(scriptURL: URL(fileURLWithPath: configuration.mailTransportScriptPath))
    }

    func boot() async throws -> InitializeResponse {
        if let initializeResponse { return initializeResponse }
        try await importLegacyConfigurationIfNeeded()
        let response = try await appServer.start()
        initializeResponse = response
        startEventLoopIfNeeded()
        return response
    }

    func probeCodex() async throws -> ProbeSummary {
        let initResponse = try await boot()
        let threadResponse = try await appServer.startThread(params: CodexThreadStartParams(
            cwd: configuration.defaultWorkspaceRoot,
            approvalPolicy: .never,
            approvalsReviewer: .user,
            sandbox: .workspaceWrite,
            model: configuration.defaultModel,
            baseInstructions: "This is a daemon bootstrap probe. Do not execute any user task.",
            developerInstructions: nil,
            ephemeral: false
        ))

        return ProbeSummary(
            supportRoot: configuration.supportRoot,
            databasePath: configuration.databasePath,
            codexHome: initResponse.codexHome,
            platform: "\(initResponse.platformFamily)/\(initResponse.platformOs)",
            userAgent: initResponse.userAgent,
            threadID: threadResponse.thread.id,
            threadPath: threadResponse.thread.path
        )
    }

    func probeTurn(prompt: String) async throws -> MailroomTurnOutcome {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw MailroomDaemonError.blankPrompt
        }

        _ = try await boot()
        let threadResponse = try await appServer.startThread(params: CodexThreadStartParams(
            cwd: configuration.defaultWorkspaceRoot,
            approvalPolicy: .never,
            approvalsReviewer: .user,
            sandbox: .workspaceWrite,
            model: configuration.defaultModel,
            baseInstructions: "This is a daemon bootstrap probe. Execute the prompt normally and keep the reply concise.",
            developerInstructions: nil,
            ephemeral: false
        ))
        let turnResponse = try await appServer.startTurn(
            threadID: threadResponse.thread.id,
            prompt: trimmedPrompt,
            cwd: configuration.defaultWorkspaceRoot,
            model: configuration.defaultModel
        )
        return try await waitForTurnOutcome(
            codexThreadID: threadResponse.thread.id,
            turnID: turnResponse.turn.id,
            mailThreadToken: nil
        )
    }

    func listThreads() async throws -> [MailroomThreadRecord] {
        try await threadStore.allThreads()
    }

    func listApprovals() async throws -> [MailroomApprovalRequest] {
        try await approvalStore.allApprovals()
    }

    func listEvents() async throws -> [MailroomEventRecord] {
        try await eventStore.allEvents()
    }

    func listTurns() async throws -> [MailroomTurnRecord] {
        try await turnStore.allTurns()
    }

    func importLegacyConfigurationIfNeeded() async throws {
        if try await accountStore.allMailboxAccounts().isEmpty {
            let legacyAccounts = try legacyAccountStore.load()
            for account in legacyAccounts {
                try await accountStore.upsertMailboxAccount(account)
            }
        }

        if try await senderPolicyStore.allSenderPolicies().isEmpty {
            let legacyPolicies = try legacySenderPolicyStore.load()
            for policy in legacyPolicies {
                try await senderPolicyStore.upsertSenderPolicy(policy)
            }
        }
    }

    func startControlServerIfNeeded() async throws -> MailroomDaemonControlFile {
        if let controlServer {
            return try await controlServer.start()
        }

        let controlFileURL = try MailroomPaths.daemonControlFileURL(supportRootPath: configuration.supportRoot)
        let controlServer = MailroomControlServer(
            controlFileURL: controlFileURL,
            handlers: .init(
                readState: { [self] in
                    try await makeControlSnapshot()
                },
                resolveApproval: { [self] params in
                    try await resolveApprovalControl(params)
                },
                resolveThreadDecision: { [self] params in
                    try await resolveThreadDecisionControl(params)
                },
                upsertMailboxAccount: { [self] params in
                    try await upsertMailboxAccountControl(params)
                },
                deleteMailboxAccount: { [self] params in
                    try await deleteMailboxAccountControl(params)
                },
                upsertSenderPolicy: { [self] params in
                    try await upsertSenderPolicyControl(params)
                },
                deleteSenderPolicy: { [self] params in
                    try await deleteSenderPolicyControl(params)
                },
                upsertManagedProject: { [self] params in
                    try await upsertManagedProjectControl(params)
                },
                deleteManagedProject: { [self] params in
                    try await deleteManagedProjectControl(params)
                }
            )
        )
        self.controlServer = controlServer

        do {
            return try await controlServer.start()
        } catch {
            self.controlServer = nil
            throw error
        }
    }

    func makeControlSnapshot() async throws -> MailroomDaemonStateSnapshot {
        let mailboxAccounts = try await accountStore.allMailboxAccounts().map { account in
            MailroomDaemonMailboxAccountSummary(
                account: account,
                hasPasswordStored: secretStore.containsPassword(for: account.id)
            )
        }
        let senderPolicies = try await senderPolicyStore.allSenderPolicies()
        let managedProjects = try await managedProjectStore.allManagedProjects()
        let managedProjectNamesByID = Dictionary(
            uniqueKeysWithValues: managedProjects.map { ($0.id, $0.displayName) }
        )
        let threadSummaries = try await threadStore.allThreads().map { thread in
            MailroomDaemonThreadSummary(
                id: thread.id,
                mailboxID: thread.mailboxID,
                normalizedSender: thread.normalizedSender,
                subject: thread.subject,
                workspaceRoot: thread.workspaceRoot,
                capability: thread.capability.rawValue,
                status: thread.status.rawValue,
                pendingStage: thread.pendingStage?.rawValue,
                managedProjectID: thread.managedProjectID,
                managedProjectName: thread.managedProjectID.flatMap { managedProjectNamesByID[$0] },
                lastInboundMessageID: thread.lastInboundMessageID,
                lastOutboundMessageID: thread.lastOutboundMessageID,
                updatedAt: thread.updatedAt
            )
        }
        let turnSummaries = try await turnStore.allTurns().map { turn in
            MailroomDaemonTurnSummary(
                id: turn.id,
                mailThreadToken: turn.mailThreadToken,
                codexThreadID: turn.codexThreadID,
                origin: turn.origin.rawValue,
                status: turn.status.rawValue,
                promptPreview: turn.promptPreview,
                lastNotifiedState: turn.lastNotifiedState?.rawValue,
                lastNotificationMessageID: turn.lastNotificationMessageID,
                startedAt: turn.startedAt,
                completedAt: turn.completedAt,
                updatedAt: turn.updatedAt
            )
        }
        let approvalSummaries = try await approvalStore.allApprovals().map { approval in
            try makeApprovalSummary(from: approval)
        }
        let syncCursorSummaries = try await syncStore.allSyncCursors().map { cursor in
            MailroomDaemonSyncCursorSummary(
                id: cursor.accountID,
                lastSeenUID: cursor.lastSeenUID,
                lastProcessedAt: cursor.lastProcessedAt
            )
        }
        let mailboxMessages = try await mailboxMessageStore.recentMailboxMessages(limit: 200, mailboxID: nil)
        let mailboxHealth = makeMailboxHealthSummaries(
            mailboxAccounts: mailboxAccounts,
            syncCursors: syncCursorSummaries
        )

        return MailroomDaemonStateSnapshot(
            generatedAt: Date(),
            supportRoot: configuration.supportRoot,
            databasePath: configuration.databasePath,
            mailboxAccounts: mailboxAccounts,
            mailboxHealth: mailboxHealth,
            senderPolicies: senderPolicies,
            managedProjects: managedProjects,
            workers: makeWorkerSummaries(),
            activeWorkerKeys: activeMailWorkerTasks.keys.sorted(),
            queuedWorkItemCount: queuedMailWorkByWorkerKey.values.reduce(0) { partialResult, items in
                partialResult + items.count
            },
            threads: threadSummaries,
            turns: turnSummaries,
            approvals: approvalSummaries,
            syncCursors: syncCursorSummaries,
            mailboxMessages: mailboxMessages,
            recentMailActivity: recentMailActivity
        )
    }

    func syncMailboxPollingRegistrations(accounts: [MailboxAccount]) {
        let validAccountIDs = Set(accounts.map(\.id))
        mailboxPollStates = mailboxPollStates.filter { validAccountIDs.contains($0.key) }
        nextPollAtByAccount = nextPollAtByAccount.filter { validAccountIDs.contains($0.key) }

        let now = Date()
        for account in accounts {
            let hasPasswordStored = secretStore.containsPassword(for: account.id)
            var state = mailboxPollStates[account.id] ?? MailboxPollRuntimeState(
                accountID: account.id,
                label: account.label,
                emailAddress: account.emailAddress,
                pollingIntervalSeconds: account.pollingIntervalSeconds,
                hasPasswordStored: hasPasswordStored,
                state: hasPasswordStored ? "waiting" : "paused",
                lastPollStartedAt: nil,
                lastPollCompletedAt: nil,
                nextPollAt: nextPollAtByAccount[account.id],
                lastFetchedCount: 0,
                lastQueuedCount: 0,
                lastError: nil,
                updatedAt: now
            )

            state.label = account.label
            state.emailAddress = account.emailAddress
            state.pollingIntervalSeconds = account.pollingIntervalSeconds
            state.hasPasswordStored = hasPasswordStored
            state.nextPollAt = nextPollAtByAccount[account.id]

            if !hasPasswordStored {
                state.state = "paused"
                state.lastError = nil
            } else if state.state == "paused" {
                state.state = "waiting"
            }

            state.updatedAt = now
            mailboxPollStates[account.id] = state
        }
    }

    func setNextPollDate(_ nextPollAt: Date?, for account: MailboxAccount) {
        nextPollAtByAccount[account.id] = nextPollAt
        guard var state = mailboxPollStates[account.id] else {
            return
        }
        state.nextPollAt = nextPollAt
        state.updatedAt = Date()
        mailboxPollStates[account.id] = state
    }

    func noteMailboxPaused(account: MailboxAccount) {
        var state = mailboxPollStates[account.id] ?? MailboxPollRuntimeState(
            accountID: account.id,
            label: account.label,
            emailAddress: account.emailAddress,
            pollingIntervalSeconds: account.pollingIntervalSeconds,
            hasPasswordStored: false,
            state: "paused",
            lastPollStartedAt: nil,
            lastPollCompletedAt: nil,
            nextPollAt: nextPollAtByAccount[account.id],
            lastFetchedCount: 0,
            lastQueuedCount: 0,
            lastError: nil,
            updatedAt: Date()
        )

        state.label = account.label
        state.emailAddress = account.emailAddress
        state.pollingIntervalSeconds = account.pollingIntervalSeconds
        state.hasPasswordStored = false
        state.state = "paused"
        state.lastError = nil
        state.nextPollAt = nextPollAtByAccount[account.id]
        state.updatedAt = Date()
        mailboxPollStates[account.id] = state
    }

    func noteMailboxPollStarted(account: MailboxAccount) {
        let now = Date()
        var state = mailboxPollStates[account.id] ?? MailboxPollRuntimeState(
            accountID: account.id,
            label: account.label,
            emailAddress: account.emailAddress,
            pollingIntervalSeconds: account.pollingIntervalSeconds,
            hasPasswordStored: true,
            state: "polling",
            lastPollStartedAt: now,
            lastPollCompletedAt: nil,
            nextPollAt: nextPollAtByAccount[account.id],
            lastFetchedCount: 0,
            lastQueuedCount: 0,
            lastError: nil,
            updatedAt: now
        )

        state.label = account.label
        state.emailAddress = account.emailAddress
        state.pollingIntervalSeconds = account.pollingIntervalSeconds
        state.hasPasswordStored = true
        state.state = "polling"
        state.lastPollStartedAt = now
        state.lastError = nil
        state.updatedAt = now
        mailboxPollStates[account.id] = state
    }

    func noteMailboxPollSucceeded(
        account: MailboxAccount,
        fetchedCount: Int,
        queuedCount: Int,
        didBootstrap: Bool
    ) {
        let now = Date()
        var state = mailboxPollStates[account.id] ?? MailboxPollRuntimeState(
            accountID: account.id,
            label: account.label,
            emailAddress: account.emailAddress,
            pollingIntervalSeconds: account.pollingIntervalSeconds,
            hasPasswordStored: true,
            state: didBootstrap ? "bootstrapped" : "healthy",
            lastPollStartedAt: now,
            lastPollCompletedAt: now,
            nextPollAt: nextPollAtByAccount[account.id],
            lastFetchedCount: fetchedCount,
            lastQueuedCount: queuedCount,
            lastError: nil,
            updatedAt: now
        )

        state.label = account.label
        state.emailAddress = account.emailAddress
        state.pollingIntervalSeconds = account.pollingIntervalSeconds
        state.hasPasswordStored = true
        state.state = didBootstrap ? "bootstrapped" : "healthy"
        state.lastPollCompletedAt = now
        state.lastFetchedCount = fetchedCount
        state.lastQueuedCount = queuedCount
        state.lastError = nil
        state.nextPollAt = nextPollAtByAccount[account.id]
        state.updatedAt = now
        mailboxPollStates[account.id] = state
    }

    func noteMailboxPollFailed(account: MailboxAccount, error: String) {
        let now = Date()
        var state = mailboxPollStates[account.id] ?? MailboxPollRuntimeState(
            accountID: account.id,
            label: account.label,
            emailAddress: account.emailAddress,
            pollingIntervalSeconds: account.pollingIntervalSeconds,
            hasPasswordStored: true,
            state: "failed",
            lastPollStartedAt: now,
            lastPollCompletedAt: now,
            nextPollAt: nextPollAtByAccount[account.id],
            lastFetchedCount: 0,
            lastQueuedCount: 0,
            lastError: error,
            updatedAt: now
        )

        state.label = account.label
        state.emailAddress = account.emailAddress
        state.pollingIntervalSeconds = account.pollingIntervalSeconds
        state.hasPasswordStored = true
        state.state = "failed"
        state.lastPollCompletedAt = now
        state.lastError = error
        state.nextPollAt = nextPollAtByAccount[account.id]
        state.updatedAt = now
        mailboxPollStates[account.id] = state
    }

    func noteRecentMailActivity(
        account: MailboxAccount,
        message: InboundMailMessage,
        result: MailroomMailboxMessageResult
    ) {
        let event = MailroomDaemonRecentMessageSummary(
            id: "\(account.id):\(message.uid):\(message.messageID)",
            accountID: account.id,
            mailboxLabel: account.label,
            mailboxEmailAddress: account.emailAddress,
            uid: message.uid,
            messageID: message.messageID,
            sender: message.fromAddress,
            subject: MailroomMailParser.normalizeSubject(message.subject),
            action: result.action.rawValue,
            threadToken: result.threadToken,
            outboundMessageID: result.outboundMessageID,
            note: result.note,
            receivedAt: message.receivedAt,
            processedAt: Date()
        )

        recentMailActivity.removeAll { $0.id == event.id }
        recentMailActivity.insert(event, at: 0)
        if recentMailActivity.count > 40 {
            recentMailActivity.removeLast(recentMailActivity.count - 40)
        }
    }

    func makeMailboxHealthSummaries(
        mailboxAccounts: [MailroomDaemonMailboxAccountSummary],
        syncCursors: [MailroomDaemonSyncCursorSummary]
    ) -> [MailroomDaemonMailboxHealthSummary] {
        let cursorByAccountID = Dictionary(uniqueKeysWithValues: syncCursors.map { ($0.id, $0) })

        return mailboxAccounts.map { mailbox in
            let account = mailbox.account
            let runtimeState = mailboxPollStates[account.id]
            let syncCursor = cursorByAccountID[account.id]
            return MailroomDaemonMailboxHealthSummary(
                accountID: account.id,
                label: account.label,
                emailAddress: account.emailAddress,
                pollingIntervalSeconds: account.pollingIntervalSeconds,
                hasPasswordStored: mailbox.hasPasswordStored,
                state: runtimeState?.state ?? (mailbox.hasPasswordStored ? "waiting" : "paused"),
                lastPollStartedAt: runtimeState?.lastPollStartedAt,
                lastPollCompletedAt: runtimeState?.lastPollCompletedAt,
                nextPollAt: runtimeState?.nextPollAt ?? nextPollAtByAccount[account.id],
                lastFetchedCount: runtimeState?.lastFetchedCount ?? 0,
                lastQueuedCount: runtimeState?.lastQueuedCount ?? 0,
                lastSeenUID: syncCursor?.lastSeenUID,
                lastProcessedAt: syncCursor?.lastProcessedAt,
                lastError: runtimeState?.lastError,
                updatedAt: runtimeState?.updatedAt ?? account.updatedAt
            )
        }
        .sorted { lhs, rhs in
            lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
    }

    func noteQueuedMailWork(_ workItem: QueuedMailWorkItem) {
        let now = Date()
        let state = mailWorkerStates[workItem.workerKey] ?? MailWorkerRuntimeState(
            workerKey: workItem.workerKey,
            mailboxID: workItem.account.id,
            mailboxAddress: workItem.account.emailAddress,
            isActive: false,
            currentMessageID: nil,
            currentSender: nil,
            currentSubject: nil,
            currentReceivedAt: nil,
            currentThreadToken: Self.threadToken(for: workItem),
            lastError: nil,
            updatedAt: now
        )

        mailWorkerStates[workItem.workerKey] = MailWorkerRuntimeState(
            workerKey: state.workerKey,
            mailboxID: workItem.account.id,
            mailboxAddress: workItem.account.emailAddress,
            isActive: state.isActive,
            currentMessageID: state.currentMessageID,
            currentSender: state.currentSender,
            currentSubject: state.currentSubject,
            currentReceivedAt: state.currentReceivedAt,
            currentThreadToken: state.currentThreadToken ?? Self.threadToken(for: workItem),
            lastError: state.lastError,
            updatedAt: now
        )
    }

    func noteWorkerBecameActive(workerKey: String) {
        guard var state = mailWorkerStates[workerKey] else {
            return
        }
        state.isActive = true
        state.updatedAt = Date()
        mailWorkerStates[workerKey] = state
    }

    func noteWorkerStartedItem(_ workItem: QueuedMailWorkItem) {
        let now = Date()
        mailWorkerStates[workItem.workerKey] = MailWorkerRuntimeState(
            workerKey: workItem.workerKey,
            mailboxID: workItem.account.id,
            mailboxAddress: workItem.account.emailAddress,
            isActive: true,
            currentMessageID: workItem.message.messageID,
            currentSender: workItem.message.fromAddress,
            currentSubject: MailroomMailParser.normalizeSubject(workItem.message.subject),
            currentReceivedAt: workItem.message.receivedAt,
            currentThreadToken: Self.threadToken(for: workItem),
            lastError: nil,
            updatedAt: now
        )
    }

    func noteWorkerFinishedItem(workerKey: String) {
        guard var state = mailWorkerStates[workerKey] else {
            return
        }
        state.currentMessageID = nil
        state.currentSender = nil
        state.currentSubject = nil
        state.currentReceivedAt = nil
        state.updatedAt = Date()
        mailWorkerStates[workerKey] = state
    }

    func noteWorkerError(workerKey: String, message: String) {
        guard var state = mailWorkerStates[workerKey] else {
            return
        }
        state.lastError = message
        state.updatedAt = Date()
        mailWorkerStates[workerKey] = state
    }

    func noteWorkerExited(workerKey: String) {
        guard var state = mailWorkerStates[workerKey] else {
            return
        }

        state.isActive = false
        state.currentMessageID = nil
        state.currentSender = nil
        state.currentSubject = nil
        state.currentReceivedAt = nil
        state.updatedAt = Date()

        let hasQueuedItems = !(queuedMailWorkByWorkerKey[workerKey] ?? []).isEmpty
        if hasQueuedItems {
            mailWorkerStates[workerKey] = state
        } else {
            mailWorkerStates.removeValue(forKey: workerKey)
        }
    }

    func makeWorkerSummaries() -> [MailroomDaemonWorkerSummary] {
        let allKeys = Set(mailWorkerStates.keys)
            .union(queuedMailWorkByWorkerKey.keys)
            .union(activeMailWorkerTasks.keys)

        return allKeys.sorted().compactMap { workerKey in
            var state = mailWorkerStates[workerKey]
            if state == nil, let queuedItem = queuedMailWorkByWorkerKey[workerKey]?.first {
                state = MailWorkerRuntimeState(
                    workerKey: workerKey,
                    mailboxID: queuedItem.account.id,
                    mailboxAddress: queuedItem.account.emailAddress,
                    isActive: activeMailWorkerTasks[workerKey] != nil,
                    currentMessageID: nil,
                    currentSender: nil,
                    currentSubject: nil,
                    currentReceivedAt: nil,
                    currentThreadToken: Self.threadToken(for: queuedItem),
                    lastError: nil,
                    updatedAt: Date()
                )
            }

            guard let state else {
                return nil
            }

            return MailroomDaemonWorkerSummary(
                workerKey: workerKey,
                mailboxID: state.mailboxID,
                mailboxAddress: state.mailboxAddress,
                isActive: state.isActive || activeMailWorkerTasks[workerKey] != nil,
                queuedItemCount: queuedMailWorkByWorkerKey[workerKey]?.count ?? 0,
                currentMessageID: state.currentMessageID,
                currentSender: state.currentSender,
                currentSubject: state.currentSubject,
                currentReceivedAt: state.currentReceivedAt,
                currentThreadToken: state.currentThreadToken,
                lastError: state.lastError,
                updatedAt: state.updatedAt
            )
        }
    }

    private static func threadToken(for workItem: QueuedMailWorkItem) -> String? {
        if workItem.workerKey.hasPrefix("thread:") {
            return String(workItem.workerKey.dropFirst("thread:".count))
        }
        return MailroomMailParser.extractReplyToken(
            subject: workItem.message.subject,
            body: workItem.message.plainBody
        )
    }

    func resolveApprovalControl(_ params: MailroomDaemonResolveApprovalParams) async throws -> MailroomDaemonStateSnapshot {
        _ = try await resolveApprovalReply(parsed: ParsedApprovalReply(
            requestID: params.approvalID,
            decision: params.decision,
            answers: params.answers,
            note: params.note
        ))
        return try await makeControlSnapshot()
    }

    func upsertMailboxAccountControl(_ params: MailroomDaemonUpsertMailboxAccountParams) async throws -> MailroomDaemonStateSnapshot {
        let trimmedPassword = params.password?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedPassword {
            guard !trimmedPassword.isEmpty else {
                throw MailroomValidationError.emptyPassword
            }
            try secretStore.savePassword(trimmedPassword, for: params.account.id)
        }

        try await accountStore.upsertMailboxAccount(params.account)
        return try await makeControlSnapshot()
    }

    func deleteMailboxAccountControl(_ params: MailroomDaemonDeleteMailboxAccountParams) async throws -> MailroomDaemonStateSnapshot {
        try await accountStore.deleteMailboxAccount(accountID: params.accountID)
        try secretStore.deletePassword(for: params.accountID)
        return try await makeControlSnapshot()
    }

    func upsertSenderPolicyControl(_ params: MailroomDaemonUpsertSenderPolicyParams) async throws -> MailroomDaemonStateSnapshot {
        try await senderPolicyStore.upsertSenderPolicy(params.policy)
        return try await makeControlSnapshot()
    }

    func deleteSenderPolicyControl(_ params: MailroomDaemonDeleteSenderPolicyParams) async throws -> MailroomDaemonStateSnapshot {
        try await senderPolicyStore.deleteSenderPolicy(policyID: params.policyID)
        return try await makeControlSnapshot()
    }

    func upsertManagedProjectControl(_ params: MailroomDaemonUpsertManagedProjectParams) async throws -> MailroomDaemonStateSnapshot {
        try await managedProjectStore.upsertManagedProject(params.project)
        return try await makeControlSnapshot()
    }

    func deleteManagedProjectControl(_ params: MailroomDaemonDeleteManagedProjectParams) async throws -> MailroomDaemonStateSnapshot {
        try await managedProjectStore.deleteManagedProject(projectID: params.projectID)
        return try await makeControlSnapshot()
    }

    func startMailWorkflow(
        seed: MailroomThreadSeed,
        prompt: String? = nil,
        origin: MailroomTurnOrigin = .localConsole
    ) async throws -> MailroomStartedThread {
        let thread = try await startMailThread(seed: seed)
        guard let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
            return MailroomStartedThread(thread: thread, turn: nil)
        }
        let turn = try await continueMailThread(token: thread.id, prompt: prompt, origin: origin)
        return MailroomStartedThread(thread: thread, turn: turn)
    }

    func startMailThread(seed: MailroomThreadSeed) async throws -> MailroomThreadRecord {
        _ = try await boot()
        let threadResponse = try await appServer.startThread(params: CodexThreadStartParams(
            cwd: seed.workspaceRoot,
            approvalPolicy: configuration.defaultApprovalPolicy,
            approvalsReviewer: .user,
            sandbox: configuration.defaultSandbox,
            model: configuration.defaultModel,
            baseInstructions: "This thread is controlled by Patch Courier. Follow the current mailroom policy and stay inside the approved workspace.",
            developerInstructions: nil,
            ephemeral: false
        ))

        let now = Date()
        let record = MailroomThreadRecord(
            id: Self.makeThreadToken(),
            mailboxID: seed.mailboxID,
            normalizedSender: seed.normalizedSender,
            subject: seed.subject,
            codexThreadID: threadResponse.thread.id,
            workspaceRoot: seed.workspaceRoot,
            capability: seed.capability,
            status: .active,
            pendingStage: nil,
            pendingPromptBody: nil,
            managedProjectID: nil,
            lastInboundMessageID: nil,
            lastOutboundMessageID: nil,
            createdAt: now,
            updatedAt: now
        )
        try await threadStore.save(thread: record)
        try await eventStore.append(event: MailroomEventRecord(
            id: UUID().uuidString,
            source: "mailroom_internal",
            method: "mail_thread/created",
            codexThreadID: record.codexThreadID,
            codexTurnID: nil,
            payload: .object([
                "mailThreadToken": .string(record.id),
                "sender": .string(record.normalizedSender),
                "subject": .string(record.subject),
                "workspaceRoot": .string(record.workspaceRoot)
            ]),
            createdAt: now
        ))
        return record
    }

    func activatePendingMailThread(token: String) async throws -> MailroomThreadRecord {
        guard var thread = try await threadStore.thread(token: token) else {
            throw MailroomDaemonError.missingThread(token)
        }

        if thread.codexThreadID != nil {
            return thread
        }

        _ = try await boot()
        let threadResponse = try await appServer.startThread(params: CodexThreadStartParams(
            cwd: thread.workspaceRoot,
            approvalPolicy: configuration.defaultApprovalPolicy,
            approvalsReviewer: .user,
            sandbox: configuration.defaultSandbox,
            model: configuration.defaultModel,
            baseInstructions: "This thread is controlled by Patch Courier. Follow the current mailroom policy and stay inside the approved workspace.",
            developerInstructions: nil,
            ephemeral: false
        ))

        thread.codexThreadID = threadResponse.thread.id
        thread.status = .active
        thread.pendingStage = nil
        thread.updatedAt = Date()
        try await threadStore.save(thread: thread)
        try await eventStore.append(event: MailroomEventRecord(
            id: UUID().uuidString,
            source: "mailroom_internal",
            method: "mail_thread/activated",
            codexThreadID: thread.codexThreadID,
            codexTurnID: nil,
            payload: .object([
                "mailThreadToken": .string(thread.id),
                "sender": .string(thread.normalizedSender),
                "subject": .string(thread.subject),
                "workspaceRoot": .string(thread.workspaceRoot)
            ]),
            createdAt: thread.updatedAt
        ))
        return thread
    }

    func continueMailThread(
        token: String,
        prompt: String,
        origin: MailroomTurnOrigin = .localConsole
    ) async throws -> CodexTurnDescriptor {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw MailroomDaemonError.blankPrompt
        }

        guard var thread = try await threadStore.thread(token: token) else {
            throw MailroomDaemonError.missingThread(token)
        }
        guard let codexThreadID = thread.codexThreadID else {
            throw MailroomDaemonError.missingCodexThread(token)
        }

        let response = try await appServer.startTurn(
            threadID: codexThreadID,
            prompt: trimmedPrompt,
            cwd: thread.workspaceRoot,
            model: configuration.defaultModel
        )
        let now = Date()
        thread.status = .active
        thread.updatedAt = now
        try await threadStore.save(thread: thread)
        try await saveTurnRecord(MailroomTurnRecord(
            id: response.turn.id,
            mailThreadToken: thread.id,
            codexThreadID: codexThreadID,
            origin: origin,
            status: .active,
            promptPreview: String(trimmedPrompt.prefix(240)),
            lastNotifiedState: nil,
            lastNotificationMessageID: nil,
            startedAt: now,
            completedAt: nil,
            updatedAt: now
        ))
        try await eventStore.append(event: MailroomEventRecord(
            id: UUID().uuidString,
            source: "mailroom_internal",
            method: "turn/start",
            codexThreadID: codexThreadID,
            codexTurnID: response.turn.id,
            payload: .object([
                "mailThreadToken": .string(thread.id),
                "promptPreview": .string(String(trimmedPrompt.prefix(240)))
            ]),
            createdAt: now
        ))
        return response.turn
    }

    func continueMailThreadAndWait(token: String, prompt: String) async throws -> MailroomTurnOutcome {
        let turn = try await continueMailThread(token: token, prompt: prompt)
        guard let thread = try await threadStore.thread(token: token), let codexThreadID = thread.codexThreadID else {
            throw MailroomDaemonError.missingCodexThread(token)
        }
        return try await waitForTurnOutcome(codexThreadID: codexThreadID, turnID: turn.id, mailThreadToken: token)
    }

    func waitForTurnOutcome(token: String, turnID: String) async throws -> MailroomTurnOutcome {
        guard let thread = try await threadStore.thread(token: token) else {
            throw MailroomDaemonError.missingThread(token)
        }
        guard let codexThreadID = thread.codexThreadID else {
            throw MailroomDaemonError.missingCodexThread(token)
        }
        return try await waitForTurnOutcome(codexThreadID: codexThreadID, turnID: turnID, mailThreadToken: token)
    }

    func waitForTurnOutcome(codexThreadID: String, turnID: String, mailThreadToken: String?) async throws -> MailroomTurnOutcome {
        _ = try await boot()

        if let immediateOutcome = try await currentTurnOutcome(codexThreadID: codexThreadID, turnID: turnID, mailThreadToken: mailThreadToken) {
            try await persistOutcome(immediateOutcome)
            return immediateOutcome
        }

        let signal = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let existing = pendingTurnWaiters.removeValue(forKey: turnID) {
                    existing.continuation.resume(throwing: CancellationError())
                }
                pendingTurnWaiters[turnID] = PendingTurnWaiter(threadID: codexThreadID, continuation: continuation)
            }
        } onCancel: {
            Task { await self.removePendingTurnWaiter(turnID: turnID) }
        }

        switch signal {
        case .approval(let approval):
            let waitingOutcome = outcome(for: approval)
            try await persistOutcome(waitingOutcome)
            return waitingOutcome

        case .completed(let notification):
            if let refreshedOutcome = try await currentTurnOutcome(
                codexThreadID: notification.threadId,
                turnID: notification.turn.id,
                mailThreadToken: mailThreadToken
            ) {
                try await persistOutcome(refreshedOutcome)
                return refreshedOutcome
            }
            let completedOutcome = MailroomTurnOutcome(
                state: notification.turn.status.turnTerminalState,
                mailThreadToken: mailThreadToken,
                codexThreadID: notification.threadId,
                turnID: notification.turn.id,
                finalAnswer: Self.extractFinalAnswer(from: notification.turn),
                approvalID: nil,
                approvalKind: nil,
                approvalSummary: nil,
                turnStatus: notification.turn.status,
                threadStatus: nil,
                turnError: notification.turn.error
            )
            try await persistOutcome(completedOutcome)
            return completedOutcome

        case .systemError(let threadID, let status):
            if let refreshedOutcome = try await currentTurnOutcome(
                codexThreadID: threadID,
                turnID: turnID,
                mailThreadToken: mailThreadToken
            ) {
                try await persistOutcome(refreshedOutcome)
                return refreshedOutcome
            }
            let systemErrorOutcome = MailroomTurnOutcome(
                state: .systemError,
                mailThreadToken: mailThreadToken,
                codexThreadID: threadID,
                turnID: turnID,
                finalAnswer: nil,
                approvalID: nil,
                approvalKind: nil,
                approvalSummary: nil,
                turnStatus: nil,
                threadStatus: status,
                turnError: nil
            )
            try await persistOutcome(systemErrorOutcome)
            return systemErrorOutcome
        }
    }

    func resolveApprovalReply(body: String) async throws -> MailroomApprovalRequest {
        guard let parsed = ApprovalReplyParser.parse(body) else {
            throw MailroomDaemonError.approvalReplyParseFailed
        }
        return try await resolveApprovalReply(parsed: parsed)
    }

    func resolveApprovalReply(parsed: ParsedApprovalReply) async throws -> MailroomApprovalRequest {
        _ = try await boot()
        guard var approval = try await approvalStore.approval(id: parsed.requestID) else {
            throw MailroomDaemonError.approvalNotFound(parsed.requestID)
        }

        switch approval.kind {
        case .commandExecution:
            let decision = try validatedDecision(
                from: parsed.decision,
                approvalID: approval.id,
                allowed: allowedDecisions(for: approval, fallback: ["accept", "acceptForSession", "decline", "cancel"])
            )
            try await appServer.respond(to: approval.rpcRequestID, commandDecision: .init(decision: .string(decision)))
            approval.resolvedDecision = decision

        case .fileChange:
            let decision = try validatedDecision(
                from: parsed.decision,
                approvalID: approval.id,
                allowed: allowedDecisions(for: approval, fallback: ["accept", "acceptForSession", "decline", "cancel"])
            )
            try await appServer.respond(to: approval.rpcRequestID, fileDecision: .init(decision: decision))
            approval.resolvedDecision = decision

        case .userInput:
            guard !parsed.answers.isEmpty else {
                throw MailroomDaemonError.approvalAnswersMissing(approval.id)
            }
            let answerPayload = parsed.answers.mapValues(ToolRequestUserInputResponse.Answer.init(answers:))
            try await appServer.respond(to: approval.rpcRequestID, userInput: ToolRequestUserInputResponse(answers: answerPayload))
            approval.resolvedDecision = parsed.decision ?? "provided"

        case .permissions, .other:
            throw MailroomDaemonError.unsupportedApprovalKind(approval.kind)
        }

        let resolvedAt = Date()
        approval.status = .resolved
        approval.resolutionNote = parsed.note
        approval.resolvedAt = resolvedAt
        try await approvalStore.save(approval: approval)
        try await transitionThread(codexThreadID: approval.codexThreadID, status: .active)
        try await transitionTurn(id: approval.codexTurnID, status: .active, completedAt: nil)
        try await eventStore.append(event: MailroomEventRecord(
            id: UUID().uuidString,
            source: "mailroom_internal",
            method: "approval/resolved",
            codexThreadID: approval.codexThreadID,
            codexTurnID: approval.codexTurnID,
            payload: try JSONValue.object(from: parsed),
            createdAt: resolvedAt
        ))
        return approval
    }

    func runSkeleton() async throws {
        let initResponse = try await boot()
        try await startPersistentRecoveryIfNeeded()
        let controlFile = try await startControlServerIfNeeded()
        print("mailroomd ready")
        print("- support root: \(configuration.supportRoot)")
        print("- database path: \(configuration.databasePath)")
        print("- codex home: \(initResponse.codexHome)")
        if let bootstrapSourceHome = configuration.bootstrapSourceHome {
            print("- profile seed home: \(bootstrapSourceHome)")
        }
        print("- accounts path: \(configuration.mailboxAccountsPath)")
        print("- policies path: \(configuration.senderPoliciesPath)")
        print("- workspace root: \(configuration.defaultWorkspaceRoot)")
        print("- model: \(configuration.defaultModel)")
        print("- control endpoint: \(controlFile.host):\(controlFile.port)")
        print("- control file: \(try MailroomPaths.daemonControlFileURL(supportRootPath: configuration.supportRoot).path)")
        print("- waiting for mail transport integration and local IPC...")

        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(60))
        }
    }

    func shutdown() async {
        controlServer?.stop()
        controlServer = nil

        eventTask?.cancel()
        eventTask = nil

        let workerTasks = Array(activeMailWorkerTasks.values)
        activeMailWorkerTasks.removeAll()
        queuedMailWorkByWorkerKey.removeAll()
        mailWorkerStates.removeAll()
        mailboxPollStates.removeAll()
        nextPollAtByAccount.removeAll()
        for task in workerTasks {
            task.cancel()
        }

        let turnRecoveryTasks = Array(recoveryTurnTasks.values)
        recoveryTurnTasks.removeAll()
        didStartPersistentRecovery = false
        for task in turnRecoveryTasks {
            task.cancel()
        }

        let waiters = pendingTurnWaiters.values
        pendingTurnWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(throwing: CancellationError())
        }

        for task in workerTasks {
            _ = await task.result
        }

        for task in turnRecoveryTasks {
            _ = await task.result
        }

        await appServer.stop()
    }

    private func startEventLoopIfNeeded() {
        guard eventTask == nil else { return }
        eventTask = Task { [self] in await consumeEvents() }
    }

    private func consumeEvents() async {
        for await event in appServer.events {
            do {
                switch event {
                case .notification(let method, let params):
                    let threadID = params?.objectValue?["threadId"]?.stringValue
                    let turnID = params?.objectValue?["turnId"]?.stringValue
                    try await eventStore.append(event: MailroomEventRecord(
                        id: UUID().uuidString,
                        source: "app_server_notification",
                        method: method,
                        codexThreadID: threadID,
                        codexTurnID: turnID,
                        payload: params ?? .null,
                        createdAt: Date()
                    ))
                    try await applyThreadStatusHint(method: method, params: params, codexThreadID: threadID)
                    try resumeWaitersIfNeeded(method: method, params: params)

                case .request(let request):
                    let approval = try await mapApprovalRequest(from: request)
                    try await approvalStore.save(approval: approval)
                    try await eventStore.append(event: MailroomEventRecord(
                        id: UUID().uuidString,
                        source: "app_server_request",
                        method: approval.kind.rawValue,
                        codexThreadID: approval.codexThreadID,
                        codexTurnID: approval.codexTurnID,
                        payload: approval.rawPayload,
                        createdAt: Date()
                    ))
                    switch approval.kind {
                    case .userInput:
                        try await transitionThread(codexThreadID: approval.codexThreadID, status: .waitingOnUser)
                        try await transitionTurn(id: approval.codexTurnID, status: .waitingOnUserInput, completedAt: nil)
                    case .commandExecution, .fileChange, .permissions, .other:
                        try await transitionThread(codexThreadID: approval.codexThreadID, status: .waitingOnApproval)
                        try await transitionTurn(id: approval.codexTurnID, status: .waitingOnApproval, completedAt: nil)
                    }
                    resumeTurnWaiter(turnID: approval.codexTurnID, signal: .approval(approval))

                case .log(let level, let target, let payload):
                    try await eventStore.append(event: MailroomEventRecord(
                        id: UUID().uuidString,
                        source: "transport_log",
                        method: "log:\(level)",
                        codexThreadID: nil,
                        codexTurnID: nil,
                        payload: .object([
                            "target": target.map(JSONValue.string) ?? .null,
                            "payload": payload ?? .null
                        ]),
                        createdAt: Date()
                    ))
                }
            } catch {
                print("mailroomd event handling error: \(error.localizedDescription)")
            }
        }
    }

    func startPersistentRecoveryIfNeeded() async throws {
        guard !didStartPersistentRecovery else {
            return
        }
        didStartPersistentRecovery = true
        try await recoverPendingMailTurns()
    }

    func saveTurnRecord(_ turn: MailroomTurnRecord) async throws {
        try await turnStore.save(turn: turn)
    }

    func transitionTurn(id: String, status: MailroomTurnStatus, completedAt: Date? = nil) async throws {
        guard var turn = try await turnStore.turn(id: id) else {
            return
        }
        turn.status = status
        if let completedAt {
            turn.completedAt = completedAt
        } else if !status.isTerminal {
            turn.completedAt = nil
        }
        turn.updatedAt = Date()
        try await turnStore.save(turn: turn)
    }

    func persistOutcome(_ outcome: MailroomTurnOutcome) async throws {
        let status = turnStatus(for: outcome.state)
        try await transitionTurn(
            id: outcome.turnID,
            status: status,
            completedAt: status.isTerminal ? Date() : nil
        )
    }

    func markTurnNotification(turnID: String, state: MailroomTurnOutcomeState, messageID: String?) async throws {
        guard var turn = try await turnStore.turn(id: turnID) else {
            return
        }
        turn.lastNotifiedState = state
        if let messageID {
            turn.lastNotificationMessageID = messageID
        }
        turn.updatedAt = Date()
        try await turnStore.save(turn: turn)
    }

    func turnStatus(for state: MailroomTurnOutcomeState) -> MailroomTurnStatus {
        switch state {
        case .completed:
            return .completed
        case .waitingOnApproval:
            return .waitingOnApproval
        case .waitingOnUserInput:
            return .waitingOnUserInput
        case .failed:
            return .failed
        case .systemError:
            return .systemError
        }
    }

    func startRecoveryTurnTask(turnID: String, operation: @escaping @Sendable () async -> Void) {
        guard recoveryTurnTasks[turnID] == nil else {
            return
        }

        recoveryTurnTasks[turnID] = Task { [self] in
            await operation()
            finishRecoveryTurnTask(turnID: turnID)
        }
    }

    func finishRecoveryTurnTask(turnID: String) {
        recoveryTurnTasks.removeValue(forKey: turnID)
    }

    private func mapApprovalRequest(from request: CodexServerRequest) async throws -> MailroomApprovalRequest {
        switch request {
        case .commandApproval(let id, let params):
            return MailroomApprovalRequest(
                id: id.description,
                rpcRequestID: id,
                kind: .commandExecution,
                mailThreadToken: try await threadStore.thread(codexThreadID: params.threadId)?.id,
                codexThreadID: params.threadId,
                codexTurnID: params.turnId,
                itemID: params.itemId,
                summary: params.command ?? "Codex requested shell execution.",
                detail: params.reason,
                availableDecisions: (params.availableDecisions ?? []).map { $0.stringValue ?? $0.prettyPrinted() },
                rawPayload: try JSONValue.object(from: params),
                status: .pending,
                resolvedDecision: nil,
                resolutionNote: nil,
                createdAt: Date(),
                resolvedAt: nil
            )

        case .fileChangeApproval(let id, let params):
            let summary = params.grantRoot.map { "Codex requested file-change approval under \($0)." } ?? "Codex requested file-change approval."
            return MailroomApprovalRequest(
                id: id.description,
                rpcRequestID: id,
                kind: .fileChange,
                mailThreadToken: try await threadStore.thread(codexThreadID: params.threadId)?.id,
                codexThreadID: params.threadId,
                codexTurnID: params.turnId,
                itemID: params.itemId,
                summary: summary,
                detail: params.reason,
                availableDecisions: ["accept", "acceptForSession", "decline", "cancel"],
                rawPayload: try JSONValue.object(from: params),
                status: .pending,
                resolvedDecision: nil,
                resolutionNote: nil,
                createdAt: Date(),
                resolvedAt: nil
            )

        case .toolRequestUserInput(let id, let params):
            let questionSummary = params.questions.map(\.header).joined(separator: ", ")
            let detail = params.questions.map { "\($0.header): \($0.question)" }.joined(separator: "\n\n")
            return MailroomApprovalRequest(
                id: id.description,
                rpcRequestID: id,
                kind: .userInput,
                mailThreadToken: try await threadStore.thread(codexThreadID: params.threadId)?.id,
                codexThreadID: params.threadId,
                codexTurnID: params.turnId,
                itemID: params.itemId,
                summary: questionSummary.isEmpty ? "Codex requested additional user input." : "Codex needs input: \(questionSummary)",
                detail: detail.isEmpty ? nil : detail,
                availableDecisions: [],
                rawPayload: try JSONValue.object(from: params),
                status: .pending,
                resolvedDecision: nil,
                resolutionNote: nil,
                createdAt: Date(),
                resolvedAt: nil
            )

        case .other(let id, let method, let params):
            return MailroomApprovalRequest(
                id: id.description,
                rpcRequestID: id,
                kind: .other,
                mailThreadToken: nil,
                codexThreadID: params?.objectValue?["threadId"]?.stringValue ?? "unknown",
                codexTurnID: params?.objectValue?["turnId"]?.stringValue ?? "unknown",
                itemID: params?.objectValue?["itemId"]?.stringValue ?? method,
                summary: "Unhandled server request: \(method)",
                detail: nil,
                availableDecisions: [],
                rawPayload: params ?? .null,
                status: .pending,
                resolvedDecision: nil,
                resolutionNote: nil,
                createdAt: Date(),
                resolvedAt: nil
            )
        }
    }

    private func applyThreadStatusHint(method: String, params: JSONValue?, codexThreadID: String?) async throws {
        switch method {
        case "turn/completed":
            if let notification = try? (params ?? .object([:])).decoded(as: CodexTurnCompletedNotification.self) {
                let turnStatus = notification.turn.status.turnTerminalState == .failed ? MailroomTurnStatus.failed : .completed
                try await transitionTurn(id: notification.turn.id, status: turnStatus, completedAt: Date())
                try await transitionThread(
                    codexThreadID: notification.threadId,
                    status: notification.turn.status.turnTerminalState == .failed ? .failed : .completed
                )
                return
            }

        case "thread/status/changed":
            if let notification = try? (params ?? .object([:])).decoded(as: CodexThreadStatusChangedNotification.self),
               let mappedStatus = mailroomThreadStatus(for: notification.status) {
                try await transitionThread(codexThreadID: notification.threadId, status: mappedStatus)
                return
            }

        default:
            break
        }

        let normalized = method.lowercased()
        if normalized.contains("turn/completed") {
            try await transitionThread(codexThreadID: codexThreadID, status: .completed)
            if let turnID = params?.objectValue?["turnId"]?.stringValue {
                try await transitionTurn(id: turnID, status: .completed, completedAt: Date())
            }
        } else if normalized.contains("turn/failed") || normalized.contains("turn/error") {
            try await transitionThread(codexThreadID: codexThreadID, status: .failed)
            if let turnID = params?.objectValue?["turnId"]?.stringValue {
                try await transitionTurn(id: turnID, status: .failed, completedAt: Date())
            }
        } else if normalized.contains("turn/started") || normalized.contains("turn/start") {
            try await transitionThread(codexThreadID: codexThreadID, status: .active)
            if let turnID = params?.objectValue?["turnId"]?.stringValue {
                try await transitionTurn(id: turnID, status: .active, completedAt: nil)
            }
        }
    }

    private func mailroomThreadStatus(for codexStatus: JSONValue) -> MailroomThreadStatus? {
        switch codexStatus.threadStatusType {
        case "idle":
            return .completed
        case "systemError":
            return .failed
        case "active":
            if codexStatus.activeFlags.contains("waitingOnUserInput") {
                return .waitingOnUser
            }
            if codexStatus.activeFlags.contains("waitingOnApproval") {
                return .waitingOnApproval
            }
            return .active
        case "notLoaded":
            return .pending
        default:
            return nil
        }
    }

    func currentTurnOutcome(codexThreadID: String, turnID: String, mailThreadToken: String?) async throws -> MailroomTurnOutcome? {
        if let approval = try await pendingApproval(codexThreadID: codexThreadID, turnID: turnID) {
            return outcome(for: approval)
        }

        let threadResponse: CodexThreadReadResponse
        do {
            threadResponse = try await appServer.readThread(threadID: codexThreadID, includeTurns: true)
        } catch let error as CodexAppServerError {
            if case .server(let payload) = error,
               payload.message.localizedCaseInsensitiveContains("not materialized yet") {
                return nil
            }
            throw error
        }
        let threadStatus = threadResponse.thread.status
        let turn = threadResponse.thread.turns?.first(where: { $0.id == turnID })

        if let turn {
            switch turn.status.turnStatusType {
            case "completed":
                return MailroomTurnOutcome(
                    state: .completed,
                    mailThreadToken: mailThreadToken,
                    codexThreadID: codexThreadID,
                    turnID: turnID,
                    finalAnswer: Self.extractFinalAnswer(from: turn),
                    approvalID: nil,
                    approvalKind: nil,
                    approvalSummary: nil,
                    turnStatus: turn.status,
                    threadStatus: threadStatus,
                    turnError: turn.error
                )

            case "failed", "interrupted":
                return MailroomTurnOutcome(
                    state: .failed,
                    mailThreadToken: mailThreadToken,
                    codexThreadID: codexThreadID,
                    turnID: turnID,
                    finalAnswer: Self.extractFinalAnswer(from: turn),
                    approvalID: nil,
                    approvalKind: nil,
                    approvalSummary: nil,
                    turnStatus: turn.status,
                    threadStatus: threadStatus,
                    turnError: turn.error
                )

            default:
                break
            }
        }

        if threadStatus.threadStatusType == "systemError" {
            return MailroomTurnOutcome(
                state: .systemError,
                mailThreadToken: mailThreadToken,
                codexThreadID: codexThreadID,
                turnID: turnID,
                finalAnswer: nil,
                approvalID: nil,
                approvalKind: nil,
                approvalSummary: nil,
                turnStatus: turn?.status,
                threadStatus: threadStatus,
                turnError: turn?.error
            )
        }

        return nil
    }

    private func pendingApproval(codexThreadID: String, turnID: String) async throws -> MailroomApprovalRequest? {
        try await approvalStore
            .allApprovals()
            .filter { $0.codexThreadID == codexThreadID && $0.codexTurnID == turnID && $0.status == .pending }
            .sorted { $0.createdAt > $1.createdAt }
            .first
    }

    private func outcome(for approval: MailroomApprovalRequest) -> MailroomTurnOutcome {
        let state: MailroomTurnOutcomeState = approval.kind == .userInput ? .waitingOnUserInput : .waitingOnApproval
        return MailroomTurnOutcome(
            state: state,
            mailThreadToken: approval.mailThreadToken,
            codexThreadID: approval.codexThreadID,
            turnID: approval.codexTurnID,
            finalAnswer: nil,
            approvalID: approval.id,
            approvalKind: approval.kind,
            approvalSummary: approval.summary,
            turnStatus: nil,
            threadStatus: nil,
            turnError: nil
        )
    }

    private func resumeWaitersIfNeeded(method: String, params: JSONValue?) throws {
        switch method {
        case "turn/completed":
            guard let notification = try? (params ?? .object([:])).decoded(as: CodexTurnCompletedNotification.self) else {
                return
            }
            resumeTurnWaiter(turnID: notification.turn.id, signal: .completed(notification))

        case "thread/status/changed":
            guard let notification = try? (params ?? .object([:])).decoded(as: CodexThreadStatusChangedNotification.self) else {
                return
            }
            guard notification.status.threadStatusType == "systemError" else {
                return
            }
            resumeTurnWaiters(threadID: notification.threadId, signal: .systemError(threadID: notification.threadId, status: notification.status))

        default:
            return
        }
    }

    private func resumeTurnWaiter(turnID: String, signal: PendingTurnSignal) {
        guard let waiter = pendingTurnWaiters.removeValue(forKey: turnID) else { return }
        waiter.continuation.resume(returning: signal)
    }

    private func resumeTurnWaiters(threadID: String, signal: PendingTurnSignal) {
        let matchingTurnIDs = pendingTurnWaiters.compactMap { key, value in
            value.threadID == threadID ? key : nil
        }
        for turnID in matchingTurnIDs {
            resumeTurnWaiter(turnID: turnID, signal: signal)
        }
    }

    private func removePendingTurnWaiter(turnID: String) {
        pendingTurnWaiters.removeValue(forKey: turnID)
    }

    private func transitionThread(codexThreadID: String?, status: MailroomThreadStatus) async throws {
        guard let codexThreadID,
              var thread = try await threadStore.thread(codexThreadID: codexThreadID) else {
            return
        }
        thread.status = status
        thread.updatedAt = Date()
        try await threadStore.save(thread: thread)
    }

    private func allowedDecisions(for approval: MailroomApprovalRequest, fallback: [String]) -> [String] {
        let source = approval.availableDecisions.isEmpty ? fallback : approval.availableDecisions
        return Array(NSOrderedSet(array: source).compactMap { $0 as? String })
    }

    private func defaultAvailableDecisions(for approvalKind: MailroomApprovalKind) -> [String] {
        switch approvalKind {
        case .commandExecution, .fileChange:
            return ["accept", "acceptForSession", "decline", "cancel"]
        case .userInput, .permissions, .other:
            return []
        }
    }

    private func makeApprovalSummary(from approval: MailroomApprovalRequest) throws -> MailroomDaemonApprovalSummary {
        let questions: [MailroomDaemonApprovalQuestionSummary]
        if approval.kind == .userInput,
           let params = try? approval.rawPayload.decoded(as: ToolRequestUserInputParams.self) {
            questions = params.questions.map { question in
                MailroomDaemonApprovalQuestionSummary(
                    id: question.id,
                    header: question.header,
                    question: question.question,
                    isOther: question.isOther ?? false,
                    isSecret: question.isSecret ?? false,
                    options: (question.options ?? []).map { option in
                        MailroomDaemonApprovalOptionSummary(
                            label: option.label,
                            description: option.description
                        )
                    }
                )
            }
        } else {
            questions = []
        }

        return MailroomDaemonApprovalSummary(
            id: approval.id,
            kind: approval.kind.rawValue,
            status: approval.status.rawValue,
            mailThreadToken: approval.mailThreadToken,
            codexThreadID: approval.codexThreadID,
            codexTurnID: approval.codexTurnID,
            itemID: approval.itemID,
            summary: approval.summary,
            detail: approval.detail,
            availableDecisions: allowedDecisions(
                for: approval,
                fallback: defaultAvailableDecisions(for: approval.kind)
            ),
            resolvedDecision: approval.resolvedDecision,
            resolutionNote: approval.resolutionNote,
            createdAt: approval.createdAt,
            resolvedAt: approval.resolvedAt,
            questions: questions
        )
    }

    private func validatedDecision(from rawDecision: String?, approvalID: String, allowed: [String]) throws -> String {
        guard let decision = rawDecision?.trimmingCharacters(in: .whitespacesAndNewlines), !decision.isEmpty else {
            throw MailroomDaemonError.approvalDecisionMissing(approvalID)
        }
        guard allowed.contains(decision) else {
            throw MailroomDaemonError.invalidDecision(decision, allowed: allowed)
        }
        return decision
    }

    private static func extractFinalAnswer(from turn: CodexTurnDescriptor) -> String? {
        var lastMessage: String?
        var finalAnswer: String?

        for item in turn.items {
            guard let object = item.objectValue,
                  object["type"]?.stringValue == "agentMessage",
                  let text = object["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                continue
            }

            lastMessage = text
            let phase = object["phase"]?.stringValue
            if phase == "final_answer" || phase == "finalAnswer" {
                finalAnswer = text
            }
        }

        return finalAnswer ?? lastMessage
    }

    private static func makeThreadToken() -> String {
        "MRM-\(UUID().uuidString.prefix(8).uppercased())"
    }
}

private extension JSONValue {
    static func object<T: Encodable>(from value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    var threadStatusType: String? {
        objectValue?["type"]?.stringValue ?? stringValue
    }

    var activeFlags: [String] {
        objectValue?["activeFlags"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    var turnStatusType: String? {
        stringValue ?? objectValue?["type"]?.stringValue
    }

    var turnTerminalState: MailroomTurnOutcomeState {
        switch turnStatusType {
        case "failed", "interrupted":
            return .failed
        default:
            return .completed
        }
    }
}
