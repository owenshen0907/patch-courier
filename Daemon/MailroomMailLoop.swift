import Foundation

struct MailroomMailboxMessageResult: Codable, Hashable, Sendable {
    var uid: UInt64
    var messageID: String
    var sender: String
    var subject: String
    var action: MailroomMailboxMessageAction
    var threadToken: String?
    var outboundMessageID: String?
    var note: String
}

struct MailroomMailboxSyncReport: Codable, Hashable, Sendable {
    var accountID: String
    var emailAddress: String
    var didBootstrap: Bool
    var fetchedCount: Int
    var processedCount: Int
    var ignoredCount: Int
    var sentCount: Int
    var lastSeenUID: UInt64?
    var error: String?
    var messages: [MailroomMailboxMessageResult]
}

struct MailroomMailboxSyncRunReport: Codable, Hashable, Sendable {
    var startedAt: Date
    var completedAt: Date
    var accountReports: [MailroomMailboxSyncReport]
}

enum MailroomEmailHTML {
    static let contentMarker = "<!--MAILROOM-CONTENT-START-->"

    static func preheader(_ preview: String?) -> String {
        preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func preheader(statusLabel: String? = nil, title: String, summary: String? = nil) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedStatus = statusLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !trimmedTitle.isEmpty && !trimmedSummary.isEmpty {
            return trimmedSummary.caseInsensitiveCompare(trimmedTitle) == .orderedSame
                ? trimmedTitle
                : "\(trimmedTitle) — \(trimmedSummary)"
        }
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        if !trimmedSummary.isEmpty {
            return trimmedSummary
        }
        return trimmedStatus
    }

    static func document(preheader: String, bodyHTML: String) -> String {
        let trimmedPreheader = preheader.trimmingCharacters(in: .whitespacesAndNewlines)
        let previewPad = Array(repeating: "&nbsp;&zwnj;", count: 24).joined()
        let preheaderHTML = trimmedPreheader.isEmpty ? "" : """
        <div style="display:none; max-height:0; max-width:0; overflow:hidden; opacity:0; mso-hide:all; color:transparent; font-size:1px; line-height:1px;">
          \(trimmedPreheader.htmlEscaped)
        </div>
        <div style="display:none; max-height:0; max-width:0; overflow:hidden; opacity:0; mso-hide:all; color:transparent; font-size:1px; line-height:1px;">
          \(previewPad)
        </div>
        """

        return """
        <!doctype html>
        <html>
        <head>
          <meta http-equiv="Content-Type" content="text/html; charset=utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <meta name="color-scheme" content="light">
          <meta name="supported-color-schemes" content="light">
        </head>
        <body style="margin:0; padding:0; background-color:#F4F1EA; color:#18212D; font-family:-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; -webkit-text-size-adjust:100%; -ms-text-size-adjust:100%; color-scheme:light;">
          \(preheaderHTML)
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%; border-collapse:collapse; background-color:#F4F1EA;">
            <tr>
              <td align="center" style="padding:24px 12px;">
                \(bodyHTML)
              </td>
            </tr>
          </table>
        </body>
        </html>
        """
    }
}

private enum MailEnvelopeTone {
    case neutral
    case info
    case success
    case warning
    case danger

    var accentHex: String {
        switch self {
        case .neutral:
            return "#5B6574"
        case .info:
            return "#2D6CDF"
        case .success:
            return "#1F8F63"
        case .warning:
            return "#B87316"
        case .danger:
            return "#C44949"
        }
    }

    var surfaceHex: String {
        switch self {
        case .neutral:
            return "#EEF1F5"
        case .info:
            return "#EAF2FF"
        case .success:
            return "#EAF8F1"
        case .warning:
            return "#FFF3E2"
        case .danger:
            return "#FDECEC"
        }
    }
}

private let mailBlockSpacingHTML = """
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%; border-collapse:collapse;">
  <tr>
    <td style="height:16px; line-height:16px; font-size:16px;">&nbsp;</td>
  </tr>
</table>
"""

private enum MailSubjectState {
    case received
    case actionNeeded
    case recorded
    case completed
    case failed
    case rejected

    var prefix: String {
        switch self {
        case .received:
            return "Patch Courier Update"
        case .actionNeeded:
            return "Patch Courier Reply Needed"
        case .recorded:
            return "Patch Courier Saved"
        case .completed:
            return "Patch Courier Done"
        case .failed:
            return "Patch Courier Failed"
        case .rejected:
            return "Patch Courier Rejected"
        }
    }
}

private struct MailEnvelopeField {
    var label: String
    var value: String
    var monospace: Bool = false
}

private struct MailEnvelopeSection {
    var title: String
    var body: String
    var monospace: Bool = false
}

private struct MailQuickAction {
    var title: String
    var detail: String
    var link: String
    var accentHex: String
    var surfaceHex: String
}

private enum MailroomMailLoopError: LocalizedError {
    case missingMailboxPassword(String)

    var errorDescription: String? {
        switch self {
        case .missingMailboxPassword(let message):
            return message
        }
    }
}

extension MailroomDaemon {
    func resolveThreadDecisionControl(_ params: MailroomDaemonResolveThreadDecisionParams) async throws -> MailroomDaemonStateSnapshot {
        try await resolvePendingThreadDecision(
            threadToken: params.threadToken,
            decision: params.decision,
            customPrompt: params.task
        )
        return try await makeControlSnapshot()
    }

    func syncMailboxes(accountIDs: [String]? = nil) async throws -> MailroomMailboxSyncRunReport {
        let startedAt = Date()
        let selectedIDs = accountIDs.map(Set.init)
        let senderPolicies = try await senderPolicyStore.allSenderPolicies().filter(\.isEnabled)
        let accounts = try await loadMailboxAccounts(filteredTo: selectedIDs)

        var reports: [MailroomMailboxSyncReport] = []
        reports.reserveCapacity(accounts.count)
        for account in accounts {
            reports.append(try await syncMailbox(account: account, senderPolicies: senderPolicies))
        }

        return MailroomMailboxSyncRunReport(
            startedAt: startedAt,
            completedAt: Date(),
            accountReports: reports
        )
    }

    func runMailLoop(accountIDs: [String]? = nil) async throws {
        _ = try await boot()
        try await startPersistentRecoveryIfNeeded()
        let controlFile = try await startControlServerIfNeeded()
        let selectedIDs = accountIDs.map(Set.init)

        print("mailroomd mail loop ready")
        print("- control endpoint: \(controlFile.host):\(controlFile.port)")
        print("- control file: \(try MailroomPaths.daemonControlFileURL(supportRootPath: configuration.supportRoot).path)")

        while !Task.isCancelled {
            let accounts = try await loadMailboxAccounts(filteredTo: selectedIDs)
            syncMailboxPollingRegistrations(accounts: accounts)
            guard !accounts.isEmpty else {
                try await Task.sleep(for: .seconds(60))
                continue
            }

            let now = Date()
            let dueAccounts = accounts.filter { account in
                (nextPollAtByAccount[account.id] ?? .distantPast) <= now
            }

            if !dueAccounts.isEmpty {
                for account in dueAccounts {
                    do {
                        try await pollMailboxForConcurrentLoop(account: account)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        print("mailroomd mailbox poll error [\(account.id)]: \(error.localizedDescription)")
                    }
                    setNextPollDate(
                        Date().addingTimeInterval(TimeInterval(max(account.pollingIntervalSeconds, 15))),
                        for: account
                    )
                }
            }

            let nextWake = accounts.compactMap { nextPollAtByAccount[$0.id] }.min() ?? Date().addingTimeInterval(60)
            let sleepSeconds = max(1, nextWake.timeIntervalSinceNow)
            try await Task.sleep(for: .seconds(sleepSeconds))
        }
    }

    func recoverPendingMailTurns() async throws {
        let candidateTurns = try await turnStore
            .allTurns()
            .filter { turn in
                turn.origin.isMailDriven && (
                    turn.status == .active ||
                    turn.status.notificationOutcomeState != turn.lastNotifiedState
                )
            }
            .sorted { $0.updatedAt < $1.updatedAt }

        for turn in candidateTurns {
            try await recoverPendingMailTurn(turn)
        }
    }

    private func loadMailboxAccounts(filteredTo selectedIDs: Set<String>?) async throws -> [MailboxAccount] {
        let accounts = try await accountStore.allMailboxAccounts()
        let filtered = accounts.filter { account in
            selectedIDs?.contains(account.id) ?? true
        }
        return filtered.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private func mailboxPassword(for account: MailboxAccount) throws -> String? {
        guard let password = try secretStore.password(for: account.id) else {
            return nil
        }
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPassword.isEmpty ? nil : trimmedPassword
    }

    private func mailboxPasswordMissingMessage() -> String {
        LT(
            "Mailbox password is missing in Keychain.",
            "Keychain 中缺少邮箱密码。",
            "Keychain にメールボックスのパスワードがない。"
        )
    }

    private func resolvePendingThreadDecision(
        threadToken: String,
        decision: MailroomDaemonThreadDecision,
        customPrompt: String?
    ) async throws {
        guard var thread = try await threadStore.thread(token: threadToken) else {
            throw MailroomDaemonError.missingThread(threadToken)
        }

        guard thread.status == .waitingOnUser else {
            return
        }

        let pendingStage = thread.pendingStage ?? .firstDecision
        guard pendingStage == .firstDecision else {
            return
        }

        guard let account = try await accountStore.allMailboxAccounts().first(where: { $0.id == thread.mailboxID }) else {
            throw MailroomDaemonError.missingThread(threadToken)
        }
        guard let password = try mailboxPassword(for: account) else {
            throw MailroomMailLoopError.missingMailboxPassword(mailboxPasswordMissingMessage())
        }

        switch decision {
        case .recordOnly:
            let outboundMessageID = try await sendEnvelope(
                addressEnvelope(
                    composeRecordedOnlyEnvelope(
                        subject: thread.subject,
                        threadToken: thread.id,
                        senderAddress: thread.normalizedSender,
                        accountEmailAddress: account.emailAddress,
                        originalRequestBody: thread.pendingPromptBody
                    ),
                    recipient: thread.normalizedSender
                ),
                account: account,
                password: password,
                replyTo: nil
            )

            thread.status = .archived
            thread.pendingStage = nil
            thread.lastOutboundMessageID = outboundMessageID
            thread.updatedAt = Date()
            try await threadStore.save(thread: thread)

        case .startTask:
            let prompt = customPrompt?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfBlank
                ?? thread.pendingPromptBody?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfBlank
            guard let prompt else {
                throw MailroomDaemonError.blankPrompt
            }

            thread = try await activatePendingMailThread(token: thread.id)
            let turn = try await continueMailThread(token: thread.id, prompt: prompt, origin: .reply)
            if let turnRecord = try await turnStore.turn(id: turn.id) {
                try await recoverPendingMailTurn(turnRecord)
            }
        }
    }

    private func recoverPendingMailTurn(_ turn: MailroomTurnRecord) async throws {
        if let outcome = try await currentTurnOutcome(
            codexThreadID: turn.codexThreadID,
            turnID: turn.id,
            mailThreadToken: turn.mailThreadToken
        ) {
            try await persistOutcome(outcome)
            let refreshedTurn = try await turnStore.turn(id: turn.id) ?? turn
            try await dispatchRecoveredOutcomeIfNeeded(turn: refreshedTurn, outcome: outcome)
            return
        }

        guard turn.status == .active else {
            return
        }

        startRecoveryTurnTask(turnID: turn.id) { [self, turn] in
            await monitorRecoveredMailTurn(turn)
        }
    }

    private func monitorRecoveredMailTurn(_ turn: MailroomTurnRecord) async {
        do {
            let outcome = try await waitForTurnOutcome(
                codexThreadID: turn.codexThreadID,
                turnID: turn.id,
                mailThreadToken: turn.mailThreadToken
            )
            let refreshedTurn = try await turnStore.turn(id: turn.id) ?? turn
            try await dispatchRecoveredOutcomeIfNeeded(turn: refreshedTurn, outcome: outcome)
        } catch is CancellationError {
            return
        } catch {
            print("mailroomd turn recovery error [\(turn.id)]: \(error.localizedDescription)")
        }
    }

    private func dispatchRecoveredOutcomeIfNeeded(turn: MailroomTurnRecord, outcome: MailroomTurnOutcome) async throws {
        guard turn.origin.isMailDriven else {
            return
        }
        guard turn.lastNotifiedState != outcome.state else {
            return
        }

        let thread: MailroomThreadRecord?
        if let token = turn.mailThreadToken {
            thread = try await threadStore.thread(token: token)
        } else {
            thread = try await threadStore.thread(codexThreadID: turn.codexThreadID)
        }

        guard let thread else {
            print("mailroomd turn recovery skipped [\(turn.id)]: missing mail thread record")
            return
        }

        guard let account = try await accountStore.allMailboxAccounts().first(where: { $0.id == thread.mailboxID }) else {
            print("mailroomd turn recovery skipped [\(turn.id)]: mailbox account \(thread.mailboxID) not found")
            return
        }

        guard let password = try mailboxPassword(for: account) else {
            print("mailroomd turn recovery skipped [\(turn.id)]: \(mailboxPasswordMissingMessage())")
            return
        }

        let outboundMessageID = try await sendOutcomeMail(
            outcome,
            account: account,
            password: password,
            threadToken: thread.id,
            threadSubject: thread.subject,
            recipient: thread.normalizedSender,
            replyTo: nil
        )
        try await updateThreadMailState(
            token: thread.id,
            lastInboundMessageID: nil,
            lastOutboundMessageID: outboundMessageID
        )
        print("mailroomd turn recovery notified [\(turn.id)] state=\(outcome.state.rawValue)")
    }

    private func pollMailboxForConcurrentLoop(account: MailboxAccount) async throws {
        guard let password = try mailboxPassword(for: account) else {
            noteMailboxPaused(account: account)
            print("mailroomd mailbox poll skipped [\(account.id)]: \(mailboxPasswordMissingMessage())")
            return
        }

        noteMailboxPollStarted(account: account)

        do {
            do {
                try await backfillMailboxHistoryIfNeeded(account: account, password: password)
            } catch {
                print("mailroomd mailbox backfill skipped [\(account.id)]: \(error.localizedDescription)")
            }
            let lastUID = try await syncStore.syncCursor(accountID: account.id)?.lastSeenUID
            let fetchResult = try await fetchMessagesViaTransport(
                account: account,
                password: password,
                lastUID: lastUID
            )
            let processedAt = Date()
            var queuedCount = 0

            if fetchResult.didBootstrap {
                for message in fetchResult.messages.sorted(by: { $0.uid < $1.uid }) {
                    let result = try await historicalMessageResult(for: message, account: account)
                    try await persistMailboxMessage(account: account, message: message, result: result)
                    noteRecentMailActivity(account: account, message: message, result: result)
                }
            } else {
                for message in fetchResult.messages.sorted(by: { $0.uid < $1.uid }) {
                    try await persistMailboxMessage(
                        account: account,
                        message: message,
                        result: queuedMessageResult(for: message)
                    )
                    let workerKey = try await mailWorkerKey(for: message, account: account)
                    enqueueMailWork(.init(workerKey: workerKey, account: account, message: message))
                    queuedCount += 1
                }
            }

            try await syncStore.save(syncCursor: MailroomMailboxSyncCursor(
                accountID: account.id,
                lastSeenUID: fetchResult.lastUID,
                lastProcessedAt: processedAt
            ))

            noteMailboxPollSucceeded(
                account: account,
                fetchedCount: fetchResult.messages.count,
                queuedCount: queuedCount,
                didBootstrap: fetchResult.didBootstrap
            )
        } catch {
            noteMailboxPollFailed(account: account, error: error.localizedDescription)
            throw error
        }
    }

    private func mailWorkerKey(for message: InboundMailMessage, account: MailboxAccount) async throws -> String {
        if let threadToken = MailroomMailParser.extractReplyToken(subject: message.subject, body: message.plainBody) {
            return "thread:\(threadToken)"
        }

        if let parsedApproval = ApprovalReplyParser.parse(message.plainBody),
           let approval = try await approvalStore.approval(id: parsedApproval.requestID) {
            if let threadToken = approval.mailThreadToken, !threadToken.isEmpty {
                return "thread:\(threadToken)"
            }
            return "codex:\(approval.codexThreadID)"
        }

        return "message:\(account.id):\(message.messageID)"
    }

    private func enqueueMailWork(_ workItem: QueuedMailWorkItem) {
        queuedMailWorkByWorkerKey[workItem.workerKey, default: []].append(workItem)
        noteQueuedMailWork(workItem)
        startMailWorkerIfNeeded(workerKey: workItem.workerKey)
    }

    private func startMailWorkerIfNeeded(workerKey: String) {
        guard activeMailWorkerTasks[workerKey] == nil else {
            return
        }

        noteWorkerBecameActive(workerKey: workerKey)
        activeMailWorkerTasks[workerKey] = Task { [self] in
            await runMailWorker(workerKey: workerKey)
        }
    }

    private func runMailWorker(workerKey: String) async {
        defer { finishMailWorker(workerKey: workerKey) }

        while !Task.isCancelled {
            guard let workItem = dequeueMailWork(workerKey: workerKey) else {
                return
            }

            noteWorkerStartedItem(workItem)

            do {
                let result = try await processQueuedMailWork(workItem)
                try await persistMailboxMessage(account: workItem.account, message: workItem.message, result: result)
                noteRecentMailActivity(account: workItem.account, message: workItem.message, result: result)
                noteWorkerFinishedItem(workerKey: workerKey)
                let threadFragment = result.threadToken ?? "-"
                print(
                    "mailroomd mailbox worker processed [\(workerKey)] message=\(result.messageID) action=\(result.action.rawValue) thread=\(threadFragment)"
                )
            } catch is CancellationError {
                noteWorkerFinishedItem(workerKey: workerKey)
                return
            } catch {
                let failedResult = MailroomMailboxMessageResult(
                    uid: workItem.message.uid,
                    messageID: workItem.message.messageID,
                    sender: workItem.message.fromAddress,
                    subject: workItem.message.subject,
                    action: .failed,
                    threadToken: MailroomMailParser.extractReplyToken(subject: workItem.message.subject, body: workItem.message.plainBody),
                    outboundMessageID: nil,
                    note: error.localizedDescription
                )
                try? await persistMailboxMessage(account: workItem.account, message: workItem.message, result: failedResult)
                noteRecentMailActivity(account: workItem.account, message: workItem.message, result: failedResult)
                noteWorkerError(workerKey: workerKey, message: error.localizedDescription)
                noteWorkerFinishedItem(workerKey: workerKey)
                print(
                    "mailroomd mailbox worker error [\(workerKey)] message=\(workItem.message.messageID): \(error.localizedDescription)"
                )
            }
        }
    }

    private func dequeueMailWork(workerKey: String) -> QueuedMailWorkItem? {
        guard var queue = queuedMailWorkByWorkerKey[workerKey], !queue.isEmpty else {
            queuedMailWorkByWorkerKey.removeValue(forKey: workerKey)
            return nil
        }

        let nextItem = queue.removeFirst()
        if queue.isEmpty {
            queuedMailWorkByWorkerKey.removeValue(forKey: workerKey)
        } else {
            queuedMailWorkByWorkerKey[workerKey] = queue
        }
        return nextItem
    }

    private func finishMailWorker(workerKey: String) {
        activeMailWorkerTasks.removeValue(forKey: workerKey)
        noteWorkerExited(workerKey: workerKey)
        if let queue = queuedMailWorkByWorkerKey[workerKey], !queue.isEmpty {
            startMailWorkerIfNeeded(workerKey: workerKey)
        }
    }

    private func processQueuedMailWork(_ workItem: QueuedMailWorkItem) async throws -> MailroomMailboxMessageResult {
        guard let password = try mailboxPassword(for: workItem.account) else {
            throw MailroomMailLoopError.missingMailboxPassword(mailboxPasswordMissingMessage())
        }

        let senderPolicies = try await senderPolicyStore.allSenderPolicies().filter(\.isEnabled)
        return try await processMessage(
            workItem.message,
            account: workItem.account,
            password: password,
            senderPolicies: senderPolicies
        )
    }

    private func syncMailbox(account: MailboxAccount, senderPolicies: [SenderPolicy]) async throws -> MailroomMailboxSyncReport {
        guard let password = try mailboxPassword(for: account) else {
            noteMailboxPaused(account: account)
            return MailroomMailboxSyncReport(
                accountID: account.id,
                emailAddress: account.emailAddress,
                didBootstrap: false,
                fetchedCount: 0,
                processedCount: 0,
                ignoredCount: 0,
                sentCount: 0,
                lastSeenUID: nil,
                error: mailboxPasswordMissingMessage(),
                messages: []
            )
        }

        noteMailboxPollStarted(account: account)

        do {
            do {
                try await backfillMailboxHistoryIfNeeded(account: account, password: password)
            } catch {
                print("mailroomd mailbox backfill skipped [\(account.id)]: \(error.localizedDescription)")
            }
            let lastUID = try await syncStore.syncCursor(accountID: account.id)?.lastSeenUID
            let fetchResult = try await fetchMessagesViaTransport(
                account: account,
                password: password,
                lastUID: lastUID
            )

            if fetchResult.didBootstrap {
                let historicalMessages = fetchResult.messages.sorted(by: { $0.uid < $1.uid })
                var historicalResults: [MailroomMailboxMessageResult] = []
                historicalResults.reserveCapacity(historicalMessages.count)
                for message in historicalMessages {
                    let result = try await historicalMessageResult(for: message, account: account)
                    historicalResults.append(result)
                    try await persistMailboxMessage(account: account, message: message, result: result)
                    noteRecentMailActivity(account: account, message: message, result: result)
                }
                try await syncStore.save(syncCursor: MailroomMailboxSyncCursor(
                    accountID: account.id,
                    lastSeenUID: fetchResult.lastUID,
                    lastProcessedAt: Date()
                ))
                noteMailboxPollSucceeded(
                    account: account,
                    fetchedCount: fetchResult.messages.count,
                    queuedCount: 0,
                    didBootstrap: true
                )
                return MailroomMailboxSyncReport(
                    accountID: account.id,
                    emailAddress: account.emailAddress,
                    didBootstrap: true,
                    fetchedCount: fetchResult.messages.count,
                    processedCount: 0,
                    ignoredCount: 0,
                    sentCount: 0,
                    lastSeenUID: fetchResult.lastUID,
                    error: nil,
                    messages: historicalResults
                )
            }

            var results: [MailroomMailboxMessageResult] = []
            var ignoredCount = 0
            var sentCount = 0

            for message in fetchResult.messages.sorted(by: { $0.uid < $1.uid }) {
                let result = try await processMessage(
                    message,
                    account: account,
                    password: password,
                    senderPolicies: senderPolicies
                )
                results.append(result)
                try await persistMailboxMessage(account: account, message: message, result: result)
                noteRecentMailActivity(account: account, message: message, result: result)
                if result.action == .ignored {
                    ignoredCount += 1
                }
                if result.outboundMessageID != nil {
                    sentCount += 1
                }
            }

            try await syncStore.save(syncCursor: MailroomMailboxSyncCursor(
                accountID: account.id,
                lastSeenUID: fetchResult.lastUID,
                lastProcessedAt: Date()
            ))
            noteMailboxPollSucceeded(
                account: account,
                fetchedCount: fetchResult.messages.count,
                queuedCount: results.count - ignoredCount,
                didBootstrap: false
            )

            return MailroomMailboxSyncReport(
                accountID: account.id,
                emailAddress: account.emailAddress,
                didBootstrap: false,
                fetchedCount: fetchResult.messages.count,
                processedCount: results.count - ignoredCount,
                ignoredCount: ignoredCount,
                sentCount: sentCount,
                lastSeenUID: fetchResult.lastUID,
                error: nil,
                messages: results
            )
        } catch {
            noteMailboxPollFailed(account: account, error: error.localizedDescription)
            throw error
        }
    }

    private func backfillMailboxHistoryIfNeeded(account: MailboxAccount, password: String) async throws {
        let existingMessages = try await mailboxMessageStore.recentMailboxMessages(limit: 1, mailboxID: account.id)
        guard existingMessages.isEmpty else {
            return
        }

        guard try await syncStore.syncCursor(accountID: account.id)?.lastSeenUID != nil else {
            return
        }

        let history = try await fetchRecentHistoryViaTransport(
            account: account,
            password: password,
            limit: 20
        )

        for message in history.messages.sorted(by: { $0.uid < $1.uid }) {
            let result = try await historicalMessageResult(for: message, account: account)
            try await persistMailboxMessage(account: account, message: message, result: result)
        }
    }

    private func queuedMessageResult(for message: InboundMailMessage) -> MailroomMailboxMessageResult {
        MailroomMailboxMessageResult(
            uid: message.uid,
            messageID: message.messageID,
            sender: message.fromAddress,
            subject: message.subject,
            action: .received,
            threadToken: MailroomMailParser.extractReplyToken(subject: message.subject, body: message.plainBody),
            outboundMessageID: nil,
            note: LT(
                "Received by the daemon and queued for processing.",
                "daemon 已接收到这封邮件，并已加入处理队列。",
                "daemon がこのメールを受信し、処理キューへ入れた。"
            )
        )
    }

    private func persistMailboxMessage(
        account: MailboxAccount,
        message: InboundMailMessage,
        result: MailroomMailboxMessageResult
    ) async throws {
        let now = Date()
        try await mailboxMessageStore.save(mailboxMessage: MailroomMailboxMessageRecord(
            id: MailroomMailboxMessageRecord.makeID(mailboxID: account.id, uid: message.uid),
            mailboxID: account.id,
            mailboxLabel: account.label,
            mailboxEmailAddress: account.emailAddress,
            uid: message.uid,
            messageID: message.messageID,
            fromAddress: message.fromAddress,
            fromDisplayName: message.fromDisplayName,
            subject: message.subject,
            plainBody: message.plainBody,
            receivedAt: message.receivedAt,
            inReplyTo: message.inReplyTo,
            references: message.references,
            threadToken: result.threadToken,
            action: result.action,
            outboundMessageID: result.outboundMessageID,
            note: result.note,
            processedAt: result.action == .received ? nil : now,
            updatedAt: now
        ))
    }

    private func processMessage(
        _ message: InboundMailMessage,
        account: MailboxAccount,
        password: String,
        senderPolicies: [SenderPolicy]
    ) async throws -> MailroomMailboxMessageResult {
        let normalizedSender = message.fromAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedMailbox = account.emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalizedSender == normalizedMailbox {
            return MailroomMailboxMessageResult(
                uid: message.uid,
                messageID: message.messageID,
                sender: normalizedSender,
                subject: message.subject,
                action: .ignored,
                threadToken: MailroomMailParser.extractReplyToken(subject: message.subject, body: message.plainBody),
                outboundMessageID: nil,
                note: LT("Ignored self-sent message.", "已忽略系统自己发出的邮件。", "自己送信メールを無視した。")
            )
        }

        if let parsedApproval = ApprovalReplyParser.parse(message.plainBody) {
            return try await processApprovalReply(
                parsedApproval,
                message: message,
                account: account,
                password: password
            )
        }

        guard let policy = senderPolicies.first(where: { $0.normalizedSenderAddress == normalizedSender }) else {
            return MailroomMailboxMessageResult(
                uid: message.uid,
                messageID: message.messageID,
                sender: normalizedSender,
                subject: message.subject,
                action: .ignored,
                threadToken: MailroomMailParser.extractReplyToken(subject: message.subject, body: message.plainBody),
                outboundMessageID: nil,
                note: LT("Ignored sender outside the allowlist.", "已忽略白名单外的发件人。", "許可リスト外の送信者を無視した。")
            )
        }

        let parsedCommand = MailroomMailParser.parseCommand(
            from: message,
            fallbackWorkspaceRoot: policy.allowedWorkspaceRoots.first ?? account.workspaceRoot
        )

        if let token = parsedCommand.detectedToken,
           let thread = try await threadStore.thread(token: token) {
            guard thread.mailboxID == account.id, thread.normalizedSender == normalizedSender else {
                return try await rejectMessage(
                    message,
                    account: account,
                    password: password,
                    threadToken: token,
                    note: LT(
                        "That thread token does not belong to this sender or mailbox.",
                        "这个 thread token 不属于当前发件人或邮箱。",
                        "その thread token は現在の送信者またはメールボックスに属していない。"
                    )
                )
            }

            if thread.codexThreadID == nil {
                return try await processPendingThreadConfirmation(
                    message: message,
                    account: account,
                    password: password,
                    thread: thread,
                    policy: policy,
                    parsedCommand: parsedCommand
                )
            }

            guard workspaceAllowed(parsedCommand.workspaceRoot, allowedRoots: policy.allowedWorkspaceRoots) else {
                return try await rejectMessage(
                    message,
                    account: account,
                    password: password,
                    threadToken: parsedCommand.detectedToken,
                    note: LT(
                        "The requested workspace is outside your allowed roots.",
                        "请求的工作区超出了你的允许目录。",
                        "要求されたワークスペースが許可されたルート外にある。"
                    )
                )
            }

            let pendingApprovals = try await pendingApprovals(for: thread)
            if let approval = pendingApprovals.first {
                let outboundMessageID = try await sendApprovalEnvelope(
                    approval,
                    account: account,
                    password: password,
                    threadToken: thread.id,
                    threadSubject: thread.subject,
                    recipient: normalizedSender,
                    replyTo: message,
                    prefixNote: LT(
                        "This thread is waiting for a structured approval reply. Please answer using the fields below.",
                        "这个线程正在等待结构化审批回复。请按下面的字段格式回答。",
                        "このスレッドは構造化された承認返信を待っている。以下のフィールド形式で回答してください。"
                    )
                )
                let notifiedState: MailroomTurnOutcomeState = approval.kind == .userInput ? .waitingOnUserInput : .waitingOnApproval
                try await markTurnNotification(turnID: approval.codexTurnID, state: notifiedState, messageID: outboundMessageID)
                try await updateThreadMailState(token: thread.id, lastInboundMessageID: message.messageID, lastOutboundMessageID: outboundMessageID)
                return MailroomMailboxMessageResult(
                    uid: message.uid,
                    messageID: message.messageID,
                    sender: normalizedSender,
                    subject: message.subject,
                    action: .approvalRequested,
                    threadToken: thread.id,
                    outboundMessageID: outboundMessageID,
                    note: approval.summary
                )
            }

            let turn = try await continueMailThread(token: thread.id, prompt: parsedCommand.promptBody, origin: .reply)
            let receiptMessageID = await sendReceiptEnvelope(
                account: account,
                password: password,
                replyTo: message,
                threadToken: thread.id,
                recipient: normalizedSender,
                title: LT("Update received, resuming work", "已收到补充，继续处理中", "追加入力を受信し、作業を再開しています"),
                summary: LT(
                    "Your latest reply has been attached to the current Codex task. Mailroom is processing it now.",
                    "你最新的回复已经接入当前 Codex 任务，Mailroom 正在继续处理。",
                    "最新の返信は現在の Codex タスクに反映され、Mailroom が処理を続けています。"
                ),
                workspaceRoot: thread.workspaceRoot,
                capability: thread.capability,
                requestPreview: parsedCommand.promptBody,
                nextSteps: [
                    LT("Apply the new context from your reply to the current Codex task.", "把你这次回复里的新上下文应用到当前 Codex 任务。", "返信で追加された文脈を現在の Codex タスクへ反映する。"),
                    LT("If approval or more information is needed, Mailroom will send a structured follow-up email.", "如果还需要审批或更多信息，Mailroom 会再发一封结构化跟进邮件。", "承認や追加情報が必要なら、Mailroom が構造化フォローアップメールを送ります。"),
                    LT("Otherwise, the updated result will be sent back in this same thread.", "否则，更新后的结果会继续在这个线程里发回给你。", "それ以外の場合は、更新後の結果をこの同じスレッドで返信します。")
                ]
            )
            try await updateThreadMailState(
                token: thread.id,
                lastInboundMessageID: message.messageID,
                lastOutboundMessageID: receiptMessageID
            )
            let outcome = try await waitForTurnOutcome(token: thread.id, turnID: turn.id)
            let outboundMessageID = try await sendOutcomeMail(
                outcome,
                account: account,
                password: password,
                threadToken: thread.id,
                threadSubject: thread.subject,
                recipient: normalizedSender,
                replyTo: message
            )
            try await updateThreadMailState(token: thread.id, lastInboundMessageID: message.messageID, lastOutboundMessageID: outboundMessageID)
            return MailroomMailboxMessageResult(
                uid: message.uid,
                messageID: message.messageID,
                sender: normalizedSender,
                subject: message.subject,
                action: action(for: outcome),
                threadToken: thread.id,
                outboundMessageID: outboundMessageID,
                note: outcomeNote(outcome)
            )
        }

        if shouldUseProjectProbe(for: policy) {
            let manageableProjects = try await manageableProjects(for: policy)
            if !manageableProjects.isEmpty {
                let token = makeMailThreadToken()
                let outboundMessageID = try await sendEnvelope(
                    composeManagedProjectProbeEnvelope(
                        subject: parsedCommand.cleanedSubject,
                        threadToken: token,
                        accountEmailAddress: account.emailAddress,
                        senderAddress: normalizedSender,
                        senderRole: policy.assignedRole,
                        originalRequestBody: parsedCommand.explicitPromptBody,
                        projects: manageableProjects
                    ),
                    account: account,
                    password: password,
                    replyTo: message
                )

                let timestamp = Date()
                try await threadStore.save(thread: MailroomThreadRecord(
                    id: token,
                    mailboxID: account.id,
                    normalizedSender: normalizedSender,
                    subject: parsedCommand.cleanedSubject,
                    codexThreadID: nil,
                    workspaceRoot: account.workspaceRoot,
                    capability: .writeWorkspace,
                    status: .waitingOnUser,
                    pendingStage: .projectSelection,
                    pendingPromptBody: parsedCommand.explicitPromptBody,
                    managedProjectID: nil,
                    lastInboundMessageID: message.messageID,
                    lastOutboundMessageID: outboundMessageID,
                    createdAt: timestamp,
                    updatedAt: timestamp
                ))

                return MailroomMailboxMessageResult(
                    uid: message.uid,
                    messageID: message.messageID,
                    sender: normalizedSender,
                    subject: message.subject,
                    action: .challenged,
                    threadToken: token,
                    outboundMessageID: outboundMessageID,
                    note: LT(
                        "Sent the managed project catalog and is waiting for a project + command reply.",
                        "已回信受管项目列表，正在等待对方继续回复“项目 + 命令”。",
                        "管理対象プロジェクト一覧を返信し、プロジェクト + コマンドの返信待ち。"
                    )
                )
            }
        }

        guard workspaceAllowed(parsedCommand.workspaceRoot, allowedRoots: policy.allowedWorkspaceRoots) else {
            return try await rejectMessage(
                message,
                account: account,
                password: password,
                threadToken: parsedCommand.detectedToken,
                note: LT(
                    "The requested workspace is outside your allowed roots.",
                    "请求的工作区超出了你的允许目录。",
                    "要求されたワークスペースが許可されたルート外にある。"
                )
            )
        }

        guard let requestedCapability = mapCapability(parsedCommand.capability) else {
            return try await rejectMessage(
                message,
                account: account,
                password: password,
                threadToken: parsedCommand.detectedToken,
                note: LT(
                    "This capability is not enabled for the daemon-backed mail loop yet.",
                    "这个能力当前还没有接入 daemon 邮件循环。",
                    "この権限カテゴリはまだ daemon ベースのメールループに接続されていない。"
                )
            )
        }

        if policy.requiresReplyToken {
            let token = makeMailThreadToken()
            let outboundMessageID = try await sendEnvelope(
                composeFirstContactEnvelope(
                    subject: parsedCommand.cleanedSubject,
                    accountEmailAddress: account.emailAddress,
                    threadToken: token,
                    senderAddress: normalizedSender,
                    workspaceRoot: parsedCommand.workspaceRoot,
                    capability: requestedCapability,
                    originalRequestBody: parsedCommand.promptBody
                ),
                account: account,
                password: password,
                replyTo: message
            )

            let timestamp = Date()
            try await threadStore.save(thread: MailroomThreadRecord(
                id: token,
                mailboxID: account.id,
                normalizedSender: normalizedSender,
                subject: parsedCommand.cleanedSubject,
                codexThreadID: nil,
                workspaceRoot: parsedCommand.workspaceRoot,
                capability: requestedCapability,
                status: .waitingOnUser,
                pendingStage: .firstDecision,
                pendingPromptBody: parsedCommand.promptBody,
                managedProjectID: nil,
                lastInboundMessageID: message.messageID,
                lastOutboundMessageID: outboundMessageID,
                createdAt: timestamp,
                updatedAt: timestamp
            ))

            return MailroomMailboxMessageResult(
                uid: message.uid,
                messageID: message.messageID,
                sender: normalizedSender,
                subject: message.subject,
                action: .challenged,
                threadToken: token,
                outboundMessageID: outboundMessageID,
                note: LT(
                    "Asked the sender to choose whether this first mail should start Codex work or stay recorded only.",
                    "已要求发件人为这封首封邮件选择：启动 Codex 任务，还是仅记录不执行。",
                    "最初のメールについて、Codex 作業を始めるか、記録だけにするかの確認を送った。"
                )
            )
        }

        let started = try await startMailWorkflow(
            seed: MailroomThreadSeed(
                mailboxID: account.id,
                normalizedSender: normalizedSender,
                subject: parsedCommand.cleanedSubject,
                workspaceRoot: parsedCommand.workspaceRoot,
                capability: requestedCapability
            ),
            prompt: parsedCommand.promptBody,
            origin: .newMail
        )

        guard let turn = started.turn else {
            return MailroomMailboxMessageResult(
                uid: message.uid,
                messageID: message.messageID,
                sender: normalizedSender,
                subject: message.subject,
                action: .failed,
                threadToken: started.thread.id,
                outboundMessageID: nil,
                note: LT("No turn was created for the inbound email.", "这封邮件没有创建出 turn。", "受信メールに対する turn が作成されなかった。")
            )
        }

        let receiptMessageID = await sendReceiptEnvelope(
            account: account,
            password: password,
            replyTo: message,
            threadToken: started.thread.id,
            recipient: normalizedSender,
            title: LT("Email received, task is starting", "已收到邮件，任务启动中", "メールを受信し、タスクを開始しています"),
            summary: LT(
                "Mailroom accepted your request and has started preparing the Codex task.",
                "Mailroom 已接收你的请求，正在启动对应的 Codex 任务。",
                "Mailroom は依頼を受け付け、Codex タスクの開始準備を進めています。"
            ),
            workspaceRoot: started.thread.workspaceRoot,
            capability: started.thread.capability,
            requestPreview: parsedCommand.promptBody,
            nextSteps: [
                LT("Run the requested Codex work in the selected workspace.", "在选定的工作区里开始执行你请求的 Codex 工作。", "選択されたワークスペースで依頼された Codex 作業を実行する。"),
                LT("If approval or more information is needed, Mailroom will send a structured follow-up email.", "如果需要审批或更多信息，Mailroom 会再发一封结构化跟进邮件。", "承認や追加情報が必要なら、Mailroom が構造化フォローアップメールを送ります。"),
                LT("Otherwise, the final result will be sent back in this same thread.", "否则，最终结果会继续在这个线程里发回给你。", "それ以外の場合は、最終結果をこの同じスレッドで返信します。")
            ],
            preheader: MailroomEmailHTML.preheader(
                LT(
                    "Task accepted. Codex is starting now and will email you here if it needs approval or more information.",
                    "任务已接收。Codex 正在启动；如果后续需要审批或更多信息，会继续发到这个线程。",
                    "タスクを受け付けました。Codex を開始しており、承認や追加情報が必要ならこのスレッドへ続報します。"
                )
            )
        )
        try await updateThreadMailState(
            token: started.thread.id,
            lastInboundMessageID: message.messageID,
            lastOutboundMessageID: receiptMessageID
        )
        let outcome = try await waitForTurnOutcome(token: started.thread.id, turnID: turn.id)
        let outboundMessageID = try await sendOutcomeMail(
            outcome,
            account: account,
            password: password,
            threadToken: started.thread.id,
            threadSubject: started.thread.subject,
            recipient: normalizedSender,
            replyTo: message
        )
        try await updateThreadMailState(token: started.thread.id, lastInboundMessageID: message.messageID, lastOutboundMessageID: outboundMessageID)
        return MailroomMailboxMessageResult(
            uid: message.uid,
            messageID: message.messageID,
            sender: normalizedSender,
            subject: message.subject,
            action: action(for: outcome),
            threadToken: started.thread.id,
            outboundMessageID: outboundMessageID,
            note: outcomeNote(outcome)
        )
    }

    private func processApprovalReply(
        _ parsedApproval: ParsedApprovalReply,
        message: InboundMailMessage,
        account: MailboxAccount,
        password: String
    ) async throws -> MailroomMailboxMessageResult {
        guard let storedApproval = try await approvalStore.approval(id: parsedApproval.requestID) else {
            let threadToken = MailroomMailParser.extractReplyToken(subject: message.subject, body: message.plainBody)
            let outboundMessageID = try await sendEnvelope(
                composeStatusEnvelope(
                    to: [message.fromAddress],
                    subject: composeOutboundSubject(
                        baseSubject: normalizeMailSubject(message.subject),
                        threadToken: MailroomMailParser.extractReplyToken(subject: message.subject, body: message.plainBody),
                        state: .failed
                    ),
                    tone: .danger,
                    statusLabel: LT("Failed", "失败", "失敗"),
                    title: LT("Approval reply received, but the request expired", "已收到审批回复，但原请求已失效", "承認返信を受け取りましたが、要求は期限切れです"),
                    summary: LT(
                        "We received your approval reply, but that approval request is no longer active in this daemon session.",
                        "我们已经收到你的审批回复，但这条审批请求在当前 daemon 会话里已经不再有效。",
                        "承認返信は受信しましたが、その承認要求は現在の daemon セッションではすでに無効です。"
                    ),
                    fields: [
                        MailEnvelopeField(label: LT("Request", "请求", "要求"), value: parsedApproval.requestID, monospace: true),
                        MailEnvelopeField(label: LT("Thread", "线程", "スレッド"), value: threadToken.map { "[patch-courier:\($0)]" } ?? LT("Unavailable", "不可用", "利用不可"), monospace: true)
                    ],
                    nextSteps: [
                        LT("If this task still matters, resend the original request email.", "如果这个任务仍然需要处理，请重新发送原始请求邮件。", "このタスクがまだ必要なら、元の依頼メールを再送してください。"),
                        LT("If Mailroom sends a fresh approval mail later, reply to that new request instead.", "如果稍后又收到新的审批邮件，请改为回复那一封新的请求。", "後で新しい承認メールが届いた場合は、その新しい要求に返信してください。")
                    ],
                    preheader: MailroomEmailHTML.preheader(
                        LT(
                            "Reply received, but that approval request already expired. Resend the original request if you still need this task.",
                            "已收到回复，但那条审批请求已经过期。如果你还需要这个任务，请重新发送原始请求。",
                            "返信は受信しましたが、その承認依頼はすでに期限切れです。このタスクがまだ必要なら元の依頼を再送してください。"
                        )
                    )
                ),
                account: account,
                password: password,
                replyTo: message
            )
            return MailroomMailboxMessageResult(
                uid: message.uid,
                messageID: message.messageID,
                sender: message.fromAddress,
                subject: message.subject,
                action: .failed,
                threadToken: MailroomMailParser.extractReplyToken(subject: message.subject, body: message.plainBody),
                outboundMessageID: outboundMessageID,
                note: LT("Approval request not found.", "没有找到对应的审批请求。", "対応する承認要求が見つからない。")
            )
        }

        let resolved = try await resolveApprovalReply(parsed: parsedApproval)
        let threadToken = resolved.mailThreadToken ?? MailroomMailParser.extractReplyToken(subject: message.subject, body: message.plainBody)
        let threadRecord: MailroomThreadRecord? = if let threadToken {
            try await threadStore.thread(token: threadToken)
        } else {
            nil
        }
        let threadSubject = threadRecord?.subject ?? normalizeMailSubject(message.subject)
        let receiptMessageID = await sendReceiptEnvelope(
            account: account,
            password: password,
            replyTo: message,
            threadToken: threadToken,
            recipient: message.fromAddress,
            title: LT("Approval received, resuming work", "已收到审批，继续处理中", "承認を受信し、作業を再開しています"),
            summary: LT(
                "Your reply has been accepted and is being applied to the paused Codex task now.",
                "你的回复已被接受，正在应用到暂停中的 Codex 任务。",
                "返信は受理され、一時停止中の Codex タスクへ適用されています。"
            ),
            workspaceRoot: threadRecord?.workspaceRoot,
            capability: threadRecord?.capability,
            projectName: nil,
            requestPreview: parsedApproval.note,
            nextSteps: [
                LT("Resume the blocked Codex turn with your approval decision.", "用你的审批决定恢复之前被阻塞的 Codex turn。", "あなたの承認判断で停止していた Codex turn を再開する。"),
                LT("If another approval or more information is needed, Mailroom will send a structured follow-up email.", "如果还需要新的审批或更多信息，Mailroom 会再发一封结构化跟进邮件。", "さらに承認や追加情報が必要なら、Mailroom が構造化フォローアップメールを送ります。"),
                LT("Otherwise, the updated result will be sent in this same thread.", "否则，更新后的结果会继续在这个线程里发给你。", "それ以外の場合は、更新後の結果をこの同じスレッドで返信します。")
            ],
            preheader: MailroomEmailHTML.preheader(
                LT(
                    "Reply accepted. Codex is resuming this paused task now and will send the next update in this thread.",
                    "回复已接受。Codex 正在恢复这个暂停中的任务，下一条更新会继续发到这个线程。",
                    "返信を受理しました。Codex はこの一時停止中タスクを再開しており、次の更新もこのスレッドへ送ります。"
                )
            )
        )
        if let threadToken {
            try await updateThreadMailState(
                token: threadToken,
                lastInboundMessageID: message.messageID,
                lastOutboundMessageID: receiptMessageID
            )
        }
        let outcome = try await waitForTurnOutcome(
            codexThreadID: resolved.codexThreadID,
            turnID: resolved.codexTurnID,
            mailThreadToken: resolved.mailThreadToken
        )
        let outboundMessageID = try await sendOutcomeMail(
            outcome,
            account: account,
            password: password,
            threadToken: threadToken,
            threadSubject: threadSubject,
            recipient: message.fromAddress,
            replyTo: message
        )
        if let threadToken {
            try await updateThreadMailState(token: threadToken, lastInboundMessageID: message.messageID, lastOutboundMessageID: outboundMessageID)
        }

        return MailroomMailboxMessageResult(
            uid: message.uid,
            messageID: message.messageID,
            sender: message.fromAddress,
            subject: message.subject,
            action: action(for: outcome),
            threadToken: threadToken,
            outboundMessageID: outboundMessageID,
            note: storedApproval.summary
        )
    }

    private func processPendingThreadConfirmation(
        message: InboundMailMessage,
        account: MailboxAccount,
        password: String,
        thread: MailroomThreadRecord,
        policy: SenderPolicy,
        parsedCommand: MailroomParsedCommand
    ) async throws -> MailroomMailboxMessageResult {
        switch thread.pendingStage ?? .firstDecision {
        case .firstDecision:
            if let confirmation = ThreadConfirmationReplyParser.parse(message.plainBody) {
                switch confirmation.decision {
                case .recordOnly:
                    let outboundMessageID = try await sendEnvelope(
                        composeRecordedOnlyEnvelope(
                            subject: thread.subject,
                            threadToken: thread.id,
                            senderAddress: thread.normalizedSender,
                            accountEmailAddress: account.emailAddress,
                            originalRequestBody: thread.pendingPromptBody
                        ),
                        account: account,
                        password: password,
                        replyTo: message
                    )

                    var archivedThread = thread
                    archivedThread.status = .archived
                    archivedThread.pendingStage = nil
                    archivedThread.lastInboundMessageID = message.messageID
                    archivedThread.lastOutboundMessageID = outboundMessageID
                    archivedThread.updatedAt = Date()
                    try await threadStore.save(thread: archivedThread)

                    return MailroomMailboxMessageResult(
                        uid: message.uid,
                        messageID: message.messageID,
                        sender: message.fromAddress,
                        subject: message.subject,
                        action: .recorded,
                        threadToken: thread.id,
                        outboundMessageID: outboundMessageID,
                        note: LT(
                            "Recorded this thread without starting Codex work.",
                            "这封邮件已被记录，但没有启动 Codex 任务。",
                            "このメールは記録のみ行い、Codex 作業は開始していない。"
                        )
                    )

                case .startTask:
                    let prompt = confirmation.customPrompt?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .nilIfBlank
                        ?? thread.pendingPromptBody?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .nilIfBlank

                    guard let prompt else {
                        return try await sendPendingThreadConfirmationReminder(
                            message: message,
                            account: account,
                            password: password,
                            thread: thread,
                            note: LT(
                                "Mailroom still needs a task body before it can start Codex for this thread.",
                                "Mailroom 还需要任务内容，才能为这个线程启动 Codex。",
                                "このスレッドで Codex を開始するには、まだタスク内容が必要です。"
                            )
                        )
                    }

                    _ = try await activatePendingMailThread(token: thread.id)
                    let turn = try await continueMailThread(token: thread.id, prompt: prompt, origin: .reply)
                    let receiptMessageID = await sendReceiptEnvelope(
                        account: account,
                        password: password,
                        replyTo: message,
                        threadToken: thread.id,
                        recipient: message.fromAddress,
                        title: LT("Confirmation received, starting work", "已确认，开始处理", "確認を受け取り、作業を開始しています"),
                        summary: LT(
                            "This first email is now confirmed and ready to start the Codex task.",
                            "这封首封邮件已经确认，可以启动 Codex 任务了。",
                            "この初回メールは確認が取れ、Codex タスクを開始できます。"
                        ),
                        workspaceRoot: thread.workspaceRoot,
                        capability: thread.capability,
                        requestPreview: prompt,
                        nextSteps: [
                            LT("Start the Codex task using the confirmed request body.", "用你确认过的任务内容正式启动 Codex。", "確認された依頼内容で Codex タスクを開始する。"),
                            LT("If approval or more information is needed, Mailroom will send a structured follow-up email.", "如果需要审批或更多信息，Mailroom 会再发一封结构化跟进邮件。", "承認や追加情報が必要なら、Mailroom が構造化フォローアップメールを送ります。"),
                            LT("Otherwise, the final result will be sent back in this thread.", "否则，最终结果会继续在这个线程里发回给你。", "それ以外の場合は、最終結果をこのスレッドで返信します。")
                        ],
                        preheader: MailroomEmailHTML.preheader(
                            LT(
                                "Confirmation received. Codex is starting this thread now and will keep replying here.",
                                "确认已收到。Codex 正在启动这个线程的任务，后续也会继续在这里回复。",
                                "確認を受信しました。Codex はこのスレッドのタスクを開始しており、今後の更新もここへ送ります。"
                            )
                        )
                    )
                    try await updateThreadMailState(
                        token: thread.id,
                        lastInboundMessageID: message.messageID,
                        lastOutboundMessageID: receiptMessageID
                    )
                    let outcome = try await waitForTurnOutcome(token: thread.id, turnID: turn.id)
                    let outboundMessageID = try await sendOutcomeMail(
                        outcome,
                        account: account,
                        password: password,
                        threadToken: thread.id,
                        threadSubject: thread.subject,
                        recipient: message.fromAddress,
                        replyTo: message
                    )
                    try await updateThreadMailState(
                        token: thread.id,
                        lastInboundMessageID: message.messageID,
                        lastOutboundMessageID: outboundMessageID
                    )

                    return MailroomMailboxMessageResult(
                        uid: message.uid,
                        messageID: message.messageID,
                        sender: message.fromAddress,
                        subject: message.subject,
                        action: action(for: outcome),
                        threadToken: thread.id,
                        outboundMessageID: outboundMessageID,
                        note: outcomeNote(outcome)
                    )
                }
            }

            return try await sendPendingThreadConfirmationReminder(
                message: message,
                account: account,
                password: password,
                thread: thread,
                note: LT(
                    "Still waiting for an explicit start-or-record decision for this first email.",
                    "这封首封邮件还在等待一个明确的选择：启动任务，还是只做记录。",
                    "この最初のメールは、開始するか記録だけにするかの明示的な選択をまだ待っている。"
                )
            )

        case .projectSelection:
            return try await processPendingProjectSelection(
                message: message,
                account: account,
                password: password,
                thread: thread,
                policy: policy,
                parsedCommand: parsedCommand
            )
        }
    }

    private func sendPendingThreadConfirmationReminder(
        message: InboundMailMessage,
        account: MailboxAccount,
        password: String,
        thread: MailroomThreadRecord,
        note: String
    ) async throws -> MailroomMailboxMessageResult {
        let outboundMessageID = try await sendEnvelope(
            composePendingDecisionReminderEnvelope(
                subject: thread.subject,
                accountEmailAddress: account.emailAddress,
                threadToken: thread.id,
                senderAddress: thread.normalizedSender,
                workspaceRoot: thread.workspaceRoot,
                capability: thread.capability,
                originalRequestBody: thread.pendingPromptBody
            ),
            account: account,
            password: password,
            replyTo: message
        )
        try await updateThreadMailState(
            token: thread.id,
            lastInboundMessageID: message.messageID,
            lastOutboundMessageID: outboundMessageID
        )
        return MailroomMailboxMessageResult(
            uid: message.uid,
            messageID: message.messageID,
            sender: message.fromAddress,
            subject: message.subject,
            action: .challenged,
            threadToken: thread.id,
            outboundMessageID: outboundMessageID,
            note: note
        )
    }

    private func processPendingProjectSelection(
        message: InboundMailMessage,
        account: MailboxAccount,
        password: String,
        thread: MailroomThreadRecord,
        policy: SenderPolicy,
        parsedCommand: MailroomParsedCommand
    ) async throws -> MailroomMailboxMessageResult {
        let availableProjects = try await manageableProjects(for: policy)
        guard !availableProjects.isEmpty else {
            return try await sendPendingProjectSelectionReminder(
                message: message,
                account: account,
                password: password,
                thread: thread,
                projects: [],
                selectedProject: nil,
                note: LT(
                    "No managed project is available for this sender right now. Add or re-enable a project in settings first.",
                    "当前没有可供这个发件人选择的受管项目。请先在设置里添加项目，或重新启用项目。",
                    "現在この送信者に対して選べる管理対象プロジェクトがない。先に設定で追加または再有効化してください。"
                )
            )
        }

        var updatedThread = thread

        let selectedProject = resolveManagedProject(
            reference: parsedCommand.projectReference,
            existingProjectID: updatedThread.managedProjectID,
            candidates: availableProjects
        )

        if parsedCommand.projectReference != nil, selectedProject == nil {
            return try await sendPendingProjectSelectionReminder(
                message: message,
                account: account,
                password: password,
                thread: updatedThread,
                projects: availableProjects,
                selectedProject: nil,
                note: LT(
                    "Mailroom could not match that project. Please choose one of the listed project slugs.",
                    "Mailroom 没有匹配到这个项目。请改用回信里列出的项目短名。",
                    "そのプロジェクトを特定できなかった。返信に載っている project slug を使ってください。"
                )
            )
        }

        if let selectedProject {
            guard let selectedCapability = mapCapability(selectedProject.defaultCapability) else {
                return try await sendPendingProjectSelectionReminder(
                    message: message,
                    account: account,
                    password: password,
                    thread: updatedThread,
                    projects: availableProjects,
                    selectedProject: nil,
                    note: LT(
                        "That project is configured with an unsupported capability.",
                        "这个项目当前配置了不支持的能力。",
                        "そのプロジェクトは未対応の権限で設定されている。"
                    )
                )
            }

            updatedThread.workspaceRoot = selectedProject.rootPath
            updatedThread.capability = selectedCapability
            updatedThread.managedProjectID = selectedProject.id
            updatedThread.updatedAt = Date()
            try await threadStore.save(thread: updatedThread)
        }

        guard let effectiveProject = selectedProject ?? resolveManagedProject(
            reference: nil,
            existingProjectID: updatedThread.managedProjectID,
            candidates: availableProjects
        ) else {
            return try await sendPendingProjectSelectionReminder(
                message: message,
                account: account,
                password: password,
                thread: updatedThread,
                projects: availableProjects,
                selectedProject: nil,
                note: LT(
                    "Choose a managed project first, then reply with the command you want Codex to run.",
                    "请先选一个受管项目，再回信写下希望 Codex 执行的命令。",
                    "先に管理対象プロジェクトを選び、その後 Codex に実行してほしいコマンドを返信してください。"
                )
            )
        }

        let prompt = parsedCommand.explicitPromptBody?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank

        guard let prompt else {
            return try await sendPendingProjectSelectionReminder(
                message: message,
                account: account,
                password: password,
                thread: updatedThread,
                projects: availableProjects,
                selectedProject: effectiveProject,
                note: LT(
                    "Project selected. Now reply with COMMAND: <what Codex should do>.",
                    "项目已经选好。现在请继续回信：COMMAND: <让 Codex 做什么>。",
                    "プロジェクトは選択済み。次に COMMAND: <Codex にしてほしいこと> を返信してください。"
                )
            )
        }

        updatedThread.pendingPromptBody = prompt
        updatedThread.updatedAt = Date()
        try await threadStore.save(thread: updatedThread)

        _ = try await activatePendingMailThread(token: updatedThread.id)
        let turn = try await continueMailThread(token: updatedThread.id, prompt: prompt, origin: .reply)
        let receiptMessageID = await sendReceiptEnvelope(
            account: account,
            password: password,
            replyTo: message,
            threadToken: updatedThread.id,
            recipient: message.fromAddress,
            title: LT("Project selected, task is starting", "项目已选定，任务启动中", "プロジェクトを確定し、タスクを開始しています"),
            summary: LT(
                "Mailroom has locked in the selected project and started the requested Codex work.",
                "Mailroom 已确认你选择的项目，正在开始对应的 Codex 工作。",
                "Mailroom は選択されたプロジェクトを確定し、依頼された Codex 作業を開始しています。"
            ),
            workspaceRoot: updatedThread.workspaceRoot,
            capability: updatedThread.capability,
            projectName: effectiveProject.displayName,
            requestPreview: prompt,
            nextSteps: [
                LT("Run your requested command in the selected managed project.", "在你选定的受管项目里执行你请求的命令。", "選択された管理対象プロジェクトで依頼されたコマンドを実行する。"),
                LT("If approval or more information is needed, Mailroom will send a structured follow-up email.", "如果需要审批或更多信息，Mailroom 会再发一封结构化跟进邮件。", "承認や追加情報が必要なら、Mailroom が構造化フォローアップメールを送ります。"),
                LT("Otherwise, the result will be sent back in this same thread.", "否则，结果会继续在这个线程里发回给你。", "それ以外の場合は、結果をこの同じスレッドで返信します。")
            ]
        )
        try await updateThreadMailState(
            token: updatedThread.id,
            lastInboundMessageID: message.messageID,
            lastOutboundMessageID: receiptMessageID
        )
        let outcome = try await waitForTurnOutcome(token: updatedThread.id, turnID: turn.id)
        let outboundMessageID = try await sendOutcomeMail(
            outcome,
            account: account,
            password: password,
            threadToken: updatedThread.id,
            threadSubject: updatedThread.subject,
            recipient: message.fromAddress,
            replyTo: message
        )
        try await updateThreadMailState(
            token: updatedThread.id,
            lastInboundMessageID: message.messageID,
            lastOutboundMessageID: outboundMessageID
        )

        return MailroomMailboxMessageResult(
            uid: message.uid,
            messageID: message.messageID,
            sender: message.fromAddress,
            subject: message.subject,
            action: action(for: outcome),
            threadToken: updatedThread.id,
            outboundMessageID: outboundMessageID,
            note: outcomeNote(outcome)
        )
    }

    private func sendPendingProjectSelectionReminder(
        message: InboundMailMessage,
        account: MailboxAccount,
        password: String,
        thread: MailroomThreadRecord,
        projects: [ManagedProject],
        selectedProject: ManagedProject?,
        note: String
    ) async throws -> MailroomMailboxMessageResult {
        let outboundMessageID = try await sendEnvelope(
            composeManagedProjectProbeEnvelope(
                subject: thread.subject,
                threadToken: thread.id,
                accountEmailAddress: account.emailAddress,
                senderAddress: thread.normalizedSender,
                senderRole: nil,
                originalRequestBody: thread.pendingPromptBody,
                projects: projects,
                selectedProject: selectedProject,
                note: note
            ),
            account: account,
            password: password,
            replyTo: message
        )
        try await updateThreadMailState(
            token: thread.id,
            lastInboundMessageID: message.messageID,
            lastOutboundMessageID: outboundMessageID
        )

        return MailroomMailboxMessageResult(
            uid: message.uid,
            messageID: message.messageID,
            sender: message.fromAddress,
            subject: message.subject,
            action: .challenged,
            threadToken: thread.id,
            outboundMessageID: outboundMessageID,
            note: note
        )
    }

    private func historicalMessageResult(
        for message: InboundMailMessage,
        account: MailboxAccount
    ) async throws -> MailroomMailboxMessageResult {
        let extractedToken = MailroomMailParser.extractReplyToken(subject: message.subject, body: message.plainBody)
        let threads = try await threadStore.allThreads().filter { $0.mailboxID == account.id }

        let matchingThread =
            threads.first(where: { $0.lastInboundMessageID == message.messageID }) ??
            extractedToken.flatMap { token in
                threads.first(where: { $0.id == token })
            }

        if let matchingThread {
            return MailroomMailboxMessageResult(
                uid: message.uid,
                messageID: message.messageID,
                sender: message.fromAddress,
                subject: message.subject,
                action: historicalAction(for: matchingThread.status),
                threadToken: matchingThread.id,
                outboundMessageID: matchingThread.lastOutboundMessageID,
                note: historicalNote(for: matchingThread)
            )
        }

        return MailroomMailboxMessageResult(
            uid: message.uid,
            messageID: message.messageID,
            sender: message.fromAddress,
            subject: message.subject,
            action: .historical,
            threadToken: extractedToken,
            outboundMessageID: nil,
            note: LT(
                "Synced from mailbox history. No Codex task was started.",
                "已从邮箱历史同步下来，没有触发 Codex 任务。",
                "メール履歴から同期した。Codex タスクは開始していない。"
            )
        )
    }

    private func historicalAction(for status: MailroomThreadStatus) -> MailroomMailboxMessageAction {
        switch status {
        case .waitingOnUser:
            return .challenged
        case .waitingOnApproval:
            return .approvalRequested
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .archived:
            return .recorded
        case .pending, .active:
            return .received
        }
    }

    private func historicalNote(for thread: MailroomThreadRecord) -> String {
        switch thread.status {
        case .waitingOnUser:
            if thread.pendingStage == .projectSelection {
                return LT(
                    "This thread is waiting for the sender to choose a managed project and reply with a command.",
                    "这个线程正在等待发件人选择一个受管项目，并继续回信给出命令。",
                    "このスレッドは、送信者が管理対象プロジェクトを選び、コマンドを返信するのを待っている。"
                )
            }
            return LT(
                "This first email already created a Mailroom thread and is waiting for your start-or-record decision.",
                "这封首封邮件已经创建了 Mailroom 线程，正在等待你选择“开始任务”还是“仅记录”。",
                "この最初のメールはすでに Mailroom スレッドを作成しており、開始するか記録だけにするかの選択待ち。"
            )
        case .waitingOnApproval:
            return LT(
                "This thread is waiting for an approval reply before Codex can continue.",
                "这个线程正在等待审批回复，Codex 之后才能继续。",
                "このスレッドは承認返信待ちのため、Codex はまだ続行できない。"
            )
        case .completed:
            return LT(
                "Codex already completed work for this email thread.",
                "Codex 已经为这个邮件线程完成处理。",
                "Codex はこのメールスレッドの処理をすでに完了した。"
            )
        case .failed:
            return LT(
                "This email thread previously failed and needs attention.",
                "这个邮件线程之前处理失败，需要注意。",
                "このメールスレッドは以前失敗しており、確認が必要。"
            )
        case .archived:
            return LT(
                "This email thread was recorded without starting Codex work.",
                "这个邮件线程已被记录，但没有启动 Codex 任务。",
                "このメールスレッドは記録のみで、Codex 作業は開始していない。"
            )
        case .pending, .active:
            return LT(
                "Mailroom already has this email thread and is still processing it.",
                "Mailroom 已经接管了这个邮件线程，目前仍在处理中。",
                "Mailroom はこのメールスレッドをすでに受け取り、まだ処理中。"
            )
        }
    }

    func sendOutcomeMail(
        _ outcome: MailroomTurnOutcome,
        account: MailboxAccount,
        password: String,
        threadToken: String?,
        threadSubject: String,
        recipient: String,
        replyTo: InboundMailMessage?
    ) async throws -> String? {
        switch outcome.state {
        case .waitingOnApproval, .waitingOnUserInput:
            guard let approvalID = outcome.approvalID,
                  let approval = try await approvalStore.approval(id: approvalID) else {
                let outboundMessageID = try await sendEnvelope(
                    addressEnvelope(
                        composeFailureEnvelope(
                            subject: threadSubject,
                            threadToken: threadToken,
                            body: LT(
                                "Codex reported that it needs input, but the pending approval record could not be loaded.",
                                "Codex 表示它需要额外输入，但未能加载待处理审批记录。",
                                "Codex は追加入力が必要だと報告したが、保留中の承認記録を読み込めなかった。"
                            )
                        ),
                        recipient: recipient
                    ),
                    account: account,
                    password: password,
                    replyTo: replyTo
                )
                try await markTurnNotification(turnID: outcome.turnID, state: .failed, messageID: outboundMessageID)
                return outboundMessageID
            }
            let outboundMessageID = try await sendApprovalEnvelope(
                approval,
                account: account,
                password: password,
                threadToken: threadToken,
                threadSubject: threadSubject,
                recipient: recipient,
                replyTo: replyTo,
                prefixNote: nil
            )
            try await markTurnNotification(turnID: outcome.turnID, state: outcome.state, messageID: outboundMessageID)
            return outboundMessageID

        case .completed:
            let workspaceRoot: String?
            let projectName: String?
            if let threadToken, let thread = try await threadStore.thread(token: threadToken) {
                workspaceRoot = thread.workspaceRoot
                if let managedProjectID = thread.managedProjectID {
                    projectName = try await managedProjectStore
                        .allManagedProjects()
                        .first(where: { $0.id == managedProjectID })?
                        .displayName
                } else {
                    projectName = nil
                }
            } else {
                workspaceRoot = nil
                projectName = nil
            }
            let outboundMessageID = try await sendEnvelope(
                addressEnvelope(
                    composeCompletionEnvelope(
                        subject: threadSubject,
                        threadToken: threadToken,
                        projectName: projectName,
                        workspaceRoot: workspaceRoot,
                        body: outcome.finalAnswer ?? LT(
                            "Codex completed the task but did not emit a final answer body.",
                            "Codex 完成了任务，但没有输出最终回答正文。",
                            "Codex はタスクを完了したが、最終回答本文を出力しなかった。"
                        )
                    ),
                    recipient: recipient
                ),
                account: account,
                password: password,
                replyTo: replyTo
            )
            try await markTurnNotification(turnID: outcome.turnID, state: .completed, messageID: outboundMessageID)
            return outboundMessageID

        case .failed, .systemError:
            let notifiedState: MailroomTurnOutcomeState = outcome.state == .systemError ? .systemError : .failed
            let outboundMessageID = try await sendEnvelope(
                addressEnvelope(
                    composeFailureEnvelope(
                        subject: threadSubject,
                        threadToken: threadToken,
                        body: [
                            outcome.finalAnswer,
                            outcome.turnError?.prettyPrinted(),
                            outcome.threadStatus?.prettyPrinted()
                        ]
                        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n\n")
                    ),
                    recipient: recipient
                ),
                account: account,
                password: password,
                replyTo: replyTo
            )
            try await markTurnNotification(turnID: outcome.turnID, state: notifiedState, messageID: outboundMessageID)
            return outboundMessageID
        }
    }

    func sendApprovalEnvelope(
        _ approval: MailroomApprovalRequest,
        account: MailboxAccount,
        password: String,
        threadToken: String?,
        threadSubject: String,
        recipient: String,
        replyTo: InboundMailMessage?,
        prefixNote: String?
    ) async throws -> String? {
        let envelope = ApprovalMailComposer.compose(
            request: approval,
            recipient: recipient,
            replyAddress: account.emailAddress,
            subject: composeOutboundSubject(baseSubject: threadSubject, threadToken: threadToken, state: .actionNeeded)
        )

        var body = envelope.plainBody
        var htmlBody = envelope.htmlBody
        if let prefixNote, !prefixNote.isEmpty {
            body = prefixNote + "\n\n" + body
            if let existingHTML = htmlBody {
                htmlBody = injectMailPrefixNoteHTML(prefixNote, into: existingHTML)
            }
        }

        return try await sendEnvelope(
            OutboundMailEnvelope(
                to: envelope.to,
                subject: envelope.subject,
                plainBody: body,
                htmlBody: htmlBody,
                inReplyTo: envelope.inReplyTo,
                references: envelope.references
            ),
            account: account,
            password: password,
            replyTo: replyTo
        )
    }

    private func sendReceiptEnvelope(
        account: MailboxAccount,
        password: String,
        replyTo: InboundMailMessage,
        threadToken: String?,
        recipient: String,
        title: String,
        summary: String,
        workspaceRoot: String?,
        capability: MailroomCapability?,
        projectName: String? = nil,
        requestPreview: String? = nil,
        nextSteps: [String],
        preheader: String? = nil
    ) async -> String? {
        let fields = makeReceiptFields(
            threadToken: threadToken,
            projectName: projectName,
            workspaceRoot: workspaceRoot,
            capability: capability,
            senderAddress: recipient
        )
        var sections: [MailEnvelopeSection] = []
        if let requestPreview = requestPreview?.trimmingCharacters(in: .whitespacesAndNewlines), !requestPreview.isEmpty {
            sections.append(
                MailEnvelopeSection(
                    title: LT("What we received", "已收到内容", "受信内容"),
                    body: requestPreview,
                    monospace: false
                )
            )
        }

        let envelope = composeStatusEnvelope(
            to: [recipient],
            subject: composeOutboundSubject(baseSubject: normalizeMailSubject(replyTo.subject), threadToken: threadToken, state: .received),
            tone: .info,
            statusLabel: LT("Received", "已接收", "受信済み"),
            title: title,
            summary: summary,
            fields: fields,
            sections: sections,
            nextSteps: nextSteps,
            footer: LT(
                "No need to resend the same email. If you want to add context, just reply here and keep the thread token.",
                "不需要重复发送同一封邮件。如果你想补充上下文，直接在这里回复并保留 thread token 即可。",
                "同じメールを再送する必要はありません。補足したい場合は、ここに返信して thread token を残してください。"
            ),
            preheader: preheader
        )

        do {
            return try await sendEnvelope(
                envelope,
                account: account,
                password: password,
                replyTo: replyTo
            )
        } catch {
            print("mailroomd receipt mail failed [\(threadToken ?? "no-thread")]: \(error.localizedDescription)")
            return nil
        }
    }

    private func makeReceiptFields(
        threadToken: String?,
        projectName: String?,
        workspaceRoot: String?,
        capability: MailroomCapability?,
        senderAddress: String
    ) -> [MailEnvelopeField] {
        var fields: [MailEnvelopeField] = [
            MailEnvelopeField(label: LT("Sender", "发件人", "送信者"), value: senderAddress, monospace: true)
        ]

        if let threadToken, !threadToken.isEmpty {
            fields.insert(
                MailEnvelopeField(label: LT("Thread", "线程", "スレッド"), value: "[patch-courier:\(threadToken)]", monospace: true),
                at: 0
            )
        }
        if let projectName, !projectName.isEmpty {
            fields.append(MailEnvelopeField(label: LT("Project", "项目", "プロジェクト"), value: projectName))
        }
        if let workspaceRoot, !workspaceRoot.isEmpty {
            fields.append(MailEnvelopeField(label: LT("Workspace", "工作区", "ワークスペース"), value: workspaceRoot, monospace: true))
        }
        if let capability {
            fields.append(MailEnvelopeField(label: LT("Capability", "能力", "権限"), value: capability.rawValue, monospace: true))
        }
        return fields
    }

    private func injectMailPrefixNoteHTML(_ note: String, into htmlDocument: String) -> String {
        let noteHTML = mailSectionHTML(
            title: LT("Latest status", "最新状态", "最新ステータス"),
            bodyHTML: mailParagraphHTML(note)
        )
        guard let range = htmlDocument.range(of: MailroomEmailHTML.contentMarker) else {
            return htmlDocument
        }
        return htmlDocument.replacingCharacters(
            in: range,
            with: MailroomEmailHTML.contentMarker + noteHTML
        )
    }

    private func rejectMessage(
        _ message: InboundMailMessage,
        account: MailboxAccount,
        password: String,
        threadToken: String?,
        note: String
    ) async throws -> MailroomMailboxMessageResult {
        let outboundMessageID = try await sendEnvelope(
            composeRejectedEnvelope(
                subject: normalizeMailSubject(message.subject),
                threadToken: threadToken,
                senderAddress: message.fromAddress,
                accountEmailAddress: account.emailAddress,
                originalRequestBody: message.plainBody,
                note: note
            ),
            account: account,
            password: password,
            replyTo: message
        )

        return MailroomMailboxMessageResult(
            uid: message.uid,
            messageID: message.messageID,
            sender: message.fromAddress,
            subject: message.subject,
            action: .rejected,
            threadToken: threadToken,
            outboundMessageID: outboundMessageID,
            note: note
        )
    }

    private func sendEnvelope(
        _ envelope: OutboundMailEnvelope,
        account: MailboxAccount,
        password: String,
        replyTo: InboundMailMessage?
    ) async throws -> String? {
        let message = OutboundMailMessage(
            to: envelope.to,
            subject: envelope.subject,
            plainBody: envelope.plainBody,
            htmlBody: envelope.htmlBody,
            inReplyTo: replyTo?.messageID ?? envelope.inReplyTo,
            references: replyTo.map { composeReferences(from: $0.references, inReplyTo: $0.inReplyTo, originalMessageID: $0.messageID) } ?? envelope.references
        )
        return try await sendMessageViaTransport(
            account: account,
            password: password,
            message: message
        ).messageID
    }

    private func fetchMessagesViaTransport(
        account: MailboxAccount,
        password: String,
        lastUID: UInt64?
    ) async throws -> MailFetchResult {
        let client = transportClient
        return try await Task.detached(priority: .utility) {
            try client.fetchMessages(account: account, password: password, lastUID: lastUID)
        }.value
    }

    private func fetchRecentHistoryViaTransport(
        account: MailboxAccount,
        password: String,
        limit: Int
    ) async throws -> MailHistoryResult {
        let client = transportClient
        return try await Task.detached(priority: .utility) {
            try client.fetchRecentHistory(account: account, password: password, limit: limit)
        }.value
    }

    private func sendMessageViaTransport(
        account: MailboxAccount,
        password: String,
        message: OutboundMailMessage
    ) async throws -> MailSendResult {
        let client = transportClient
        return try await Task.detached(priority: .utility) {
            try client.sendMessage(account: account, password: password, message: message)
        }.value
    }

    private func addressEnvelope(_ envelope: OutboundMailEnvelope, recipient: String) -> OutboundMailEnvelope {
        OutboundMailEnvelope(
            to: [recipient],
            subject: envelope.subject,
            plainBody: envelope.plainBody,
            htmlBody: envelope.htmlBody,
            inReplyTo: envelope.inReplyTo,
            references: envelope.references
        )
    }

    private func composeStatusEnvelope(
        to: [String],
        subject: String,
        tone: MailEnvelopeTone,
        statusLabel: String,
        title: String,
        summary: String,
        fields: [MailEnvelopeField] = [],
        sections: [MailEnvelopeSection] = [],
        plainSections: [MailEnvelopeSection]? = nil,
        extraSectionsHTML: [String] = [],
        nextSteps: [String] = [],
        footer: String? = nil,
        preheader: String? = nil
    ) -> OutboundMailEnvelope {
        let plainBody = composePlainMailBody(
            statusLabel: statusLabel,
            title: title,
            summary: summary,
            fields: fields,
            sections: plainSections ?? sections,
            nextSteps: nextSteps,
            footer: footer
        )
        let htmlBody = composeHTMLMailBody(
            tone: tone,
            statusLabel: statusLabel,
            title: title,
            summary: summary,
            fields: fields,
            sections: sections,
            extraSectionsHTML: extraSectionsHTML,
            nextSteps: nextSteps,
            footer: footer,
            preheader: preheader
        )

        return OutboundMailEnvelope(
            to: to,
            subject: subject,
            plainBody: plainBody,
            htmlBody: htmlBody,
            inReplyTo: nil,
            references: []
        )
    }

    private func composePlainMailBody(
        statusLabel: String,
        title: String,
        summary: String,
        fields: [MailEnvelopeField],
        sections: [MailEnvelopeSection],
        nextSteps: [String],
        footer: String?
    ) -> String {
        var lines: [String] = [title]

        if let summary = summary.nilIfBlank {
            lines.append("")
            lines.append(summary)
        }

        lines.append("")
        lines.append("STATUS: \(statusLabel)")

        for field in fields {
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                continue
            }
            lines.append("\(field.label.uppercased()): \(value)")
        }

        for section in sections {
            let body = section.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else {
                continue
            }
            lines.append("")
            lines.append("\(section.title):")
            lines.append(body)
        }

        let cleanedNextSteps = nextSteps
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleanedNextSteps.isEmpty {
            lines.append("")
            lines.append(LT("Next:", "接下来：", "次の流れ:"))
            for (index, step) in cleanedNextSteps.enumerated() {
                lines.append("\(index + 1). \(step)")
            }
        }

        if let footer = footer?.trimmingCharacters(in: .whitespacesAndNewlines), !footer.isEmpty {
            lines.append("")
            lines.append(footer)
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func composeHTMLMailBody(
        tone: MailEnvelopeTone,
        statusLabel: String,
        title: String,
        summary: String,
        fields: [MailEnvelopeField],
        sections: [MailEnvelopeSection],
        extraSectionsHTML: [String],
        nextSteps: [String],
        footer: String?,
        preheader: String?
    ) -> String {
        let summaryHTML = summary.nilIfBlank.map(mailParagraphHTML) ?? ""
        let metadataHTML = mailMetadataHTML(fields)
        let sectionBlocks = sections
            .map { section in
                let body = section.body.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else {
                    return ""
                }
                let contentHTML = section.monospace
                    ? mailPreformattedHTML(body)
                    : mailParagraphHTML(body)
                return mailSectionHTML(title: section.title, bodyHTML: contentHTML)
            }
            .filter { !$0.isEmpty }
        let contentBlocks = [metadataHTML] + sectionBlocks + extraSectionsHTML
        let stackedBlocksHTML = mailStackedBlocksHTML(contentBlocks)

        let cleanedNextSteps = nextSteps
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let nextStepsHTML = cleanedNextSteps.isEmpty ? "" : mailSectionHTML(
            title: LT("Next", "接下来", "次の流れ"),
            bodyHTML: """
            <ol style="margin:0; padding:0 0 0 22px; color:#18212D; font-size:15px; line-height:1.75;">
              \(cleanedNextSteps.map { "<li style=\"margin:0 0 8px;\">\(mailInlineHTML($0))</li>" }.joined())
            </ol>
            """
        )

        let footerHTML = footer?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank.map {
            mailFooterHTML(mailInlineHTML($0))
        } ?? ""

        return MailroomEmailHTML.document(
            preheader: preheader ?? MailroomEmailHTML.preheader(
                statusLabel: statusLabel,
                title: title,
                summary: summary.nilIfBlank
            ),
            bodyHTML: """
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%; max-width:600px; border-collapse:collapse;">
            <tr>
              <td style="padding:0 0 12px 0; color:#7C8696; font-size:12px; line-height:1.6; letter-spacing:0.08em; text-transform:uppercase; font-weight:700;">
                Patch Courier
              </td>
            </tr>
            <tr>
              <td style="background-color:#FFFFFF; border:1px solid #D8DDE6;">
                <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%; border-collapse:collapse;">
                  <tr>
                    <td style="padding:24px 24px 18px 24px; background-color:\(tone.surfaceHex); border-bottom:1px solid #D8DDE6;">
                      <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;">
                        <tr>
                          <td style="padding:6px 10px; background-color:\(tone.accentHex); color:#FFFFFF; font-size:12px; line-height:1; font-weight:700; letter-spacing:0.04em; text-transform:uppercase;">
                            \(statusLabel.htmlEscaped)
                          </td>
                        </tr>
                      </table>
                      <div style="padding-top:14px; font-size:26px; line-height:1.3; color:#18212D; font-weight:700; word-wrap:break-word; overflow-wrap:anywhere;">
                        \(title.htmlEscaped)
                      </div>
                      \(summaryHTML)
                    </td>
                  </tr>
                  <tr>
                    <td style="padding:24px 24px 28px 24px; background-color:#FCFBF8;">
                      \(MailroomEmailHTML.contentMarker)
                      \(stackedBlocksHTML)
                      \(nextStepsHTML.isEmpty ? "" : mailBlockSpacingHTML + nextStepsHTML)
                      \(footerHTML.isEmpty ? "" : mailBlockSpacingHTML + footerHTML)
                    </td>
                  </tr>
                </table>
              </td>
            </tr>
          </table>
        """
        )
    }

    private func mailMetadataHTML(_ fields: [MailEnvelopeField]) -> String {
        let rows = fields.compactMap { field -> String? in
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                return nil
            }
            let valueHTML: String
            if field.monospace || shouldUseMonospace(for: value) {
                valueHTML = "<span style=\"font-family:ui-monospace, SFMono-Regular, Menlo, monospace; font-size:13px; color:#0F172A; word-wrap:break-word; overflow-wrap:anywhere;\">\(value.htmlEscaped)</span>"
            } else {
                valueHTML = "<span style=\"color:#0F172A; word-wrap:break-word; overflow-wrap:anywhere;\">\(value.htmlEscaped)</span>"
            }
            return """
            <tr>
              <td style="padding:12px 16px; border-bottom:1px solid #EDF1F5;">
                <div style="padding-bottom:4px; font-size:12px; line-height:1.4; letter-spacing:0.04em; text-transform:uppercase; color:#6B7280; font-weight:700;">\(field.label.htmlEscaped)</div>
                <div style="font-size:15px; line-height:1.65;">\(valueHTML)</div>
              </td>
            </tr>
            """
        }

        guard !rows.isEmpty else {
            return ""
        }

        return """
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%; border-collapse:collapse; border:1px solid #D8DDE6; background-color:#FFFFFF;">
          \(rows.joined())
        </table>
        """
    }

    private func mailSections(
        from text: String,
        defaultTitle: String
    ) -> [MailEnvelopeSection] {
        let paragraphs = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !paragraphs.isEmpty else {
            return []
        }

        var sections: [MailEnvelopeSection] = []
        var unlabeledParagraphs: [String] = []

        func flushUnlabeledParagraphs() {
            guard !unlabeledParagraphs.isEmpty else {
                return
            }
            sections.append(
                MailEnvelopeSection(
                    title: defaultTitle,
                    body: unlabeledParagraphs.joined(separator: "\n\n"),
                    monospace: false
                )
            )
            unlabeledParagraphs.removeAll()
        }

        for paragraph in paragraphs {
            let lines = paragraph
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else {
                continue
            }

            let heading = lines[0]
            let hasSectionHeading = lines.count > 1 &&
                heading.count <= 72 &&
                (heading.hasSuffix(":") || heading.hasSuffix("："))

            if hasSectionHeading {
                flushUnlabeledParagraphs()
                let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else {
                    continue
                }
                let title = String(heading.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                sections.append(
                    MailEnvelopeSection(
                        title: title,
                        body: body,
                        monospace: false
                    )
                )
            } else {
                unlabeledParagraphs.append(paragraph)
            }
        }

        flushUnlabeledParagraphs()
        return sections
    }

    private func mailInlineHTML(_ text: String) -> String {
        var html = ""
        var buffer = ""
        var insideCode = false

        for character in text {
            if character == "`" {
                if insideCode {
                    html += """
                    <code style="padding:1px 4px; background-color:#F3F4F6; border:1px solid #E5E7EB; color:#18212D; font:13px/1.6 ui-monospace, SFMono-Regular, Menlo, monospace; word-wrap:break-word; overflow-wrap:anywhere;">\(buffer.htmlEscaped)</code>
                    """
                } else {
                    html += buffer.htmlEscaped
                }
                buffer.removeAll(keepingCapacity: true)
                insideCode.toggle()
            } else {
                buffer.append(character)
            }
        }

        if insideCode {
            html += "`" + buffer.htmlEscaped
        } else {
            html += buffer.htmlEscaped
        }

        return html
    }

    private func mailParagraphHTML(_ text: String) -> String {
        let paragraphs = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !paragraphs.isEmpty else {
            return ""
        }

        return paragraphs.map { paragraph in
            let lines = paragraph
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else {
                return ""
            }

            if lines.allSatisfy({ $0.hasPrefix("- ") || $0.hasPrefix("* ") }) {
                let items = lines.map { line in
                    let content = String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                    return "<li style=\"margin:0 0 8px;\">\(mailInlineHTML(content))</li>"
                }.joined()
                return "<ul style=\"margin:0 0 12px; padding-left:22px; color:#18212D; font-size:15px; line-height:1.78;\">\(items)</ul>"
            }

            let numberedItems = lines.compactMap { line -> (String, String)? in
                guard let match = line.firstMatch(of: /^(\d+)[\.\)]\s+(.*)$/) else {
                    return nil
                }
                return (String(match.1), String(match.2))
            }
            if numberedItems.count == lines.count {
                let items = numberedItems.map { _, content in
                    "<li style=\"margin:0 0 8px;\">\(mailInlineHTML(content.trimmingCharacters(in: .whitespacesAndNewlines)))</li>"
                }.joined()
                return "<ol style=\"margin:0 0 12px; padding-left:24px; color:#18212D; font-size:15px; line-height:1.78;\">\(items)</ol>"
            }

            let html = paragraph
                .components(separatedBy: "\n")
                .map { mailInlineHTML($0) }
                .joined(separator: "<br>")
            return "<p style=\"margin:0 0 12px; color:#18212D; font-size:15px; line-height:1.78;\">\(html)</p>"
        }.joined()
    }

    private func mailPreformattedHTML(_ text: String) -> String {
        let lines = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
            .map { $0.htmlEscaped }
            .joined(separator: "<br>")
        return """
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%; border-collapse:collapse; background-color:#F7F4EE; border:1px solid #D8DDE6;">
          <tr>
            <td style="padding:14px 16px; color:#18212D; font:13px/1.7 ui-monospace, SFMono-Regular, Menlo, monospace; word-wrap:break-word; overflow-wrap:anywhere;">
              \(lines)
            </td>
          </tr>
        </table>
        """
    }

    private func mailSectionHTML(title: String, bodyHTML: String) -> String {
        """
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%; border-collapse:collapse; border:1px solid #D8DDE6; background-color:#FFFFFF;">
          <tr>
            <td style="padding:14px 16px 0 16px; font-size:12px; line-height:1.4; letter-spacing:0.04em; text-transform:uppercase; color:#6B7280; font-weight:700;">
              \(title.htmlEscaped)
            </td>
          </tr>
          <tr>
            <td style="padding:12px 16px 16px 16px;">
              \(bodyHTML)
            </td>
          </tr>
        </table>
        """
    }

    private func mailStackedBlocksHTML(_ blocks: [String]) -> String {
        let cleaned = blocks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else {
            return ""
        }
        return cleaned.enumerated().map { index, block in
            (index == 0 ? "" : mailBlockSpacingHTML) + block
        }.joined()
    }

    private func mailFooterHTML(_ bodyHTML: String) -> String {
        """
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%; border-collapse:collapse;">
          <tr>
            <td style="font-size:13px; line-height:1.75; color:#667085;">
              \(bodyHTML)
            </td>
          </tr>
        </table>
        """
    }

    private func mailActionCardHTML(
        badge: String,
        title: String,
        detailHTML: String,
        accentHex: String,
        link: String,
        buttonLabel: String
    ) -> String {
        """
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%; border-collapse:collapse; border:1px solid #D8DDE6; background-color:#FFFFFF;">
          <tr>
            <td style="padding:16px;">
              <div style="font-size:11px; line-height:1.2; letter-spacing:0.08em; text-transform:uppercase; color:\(accentHex); font-weight:700;">\(badge.htmlEscaped)</div>
              <div style="padding-top:10px; font-size:18px; line-height:1.4; color:#18212D; font-weight:700; word-wrap:break-word; overflow-wrap:anywhere;">\(title.htmlEscaped)</div>
              <p style="margin:10px 0 0; color:#475467; font-size:14px; line-height:1.72;">\(detailHTML)</p>
              <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin-top:14px; border-collapse:collapse;">
                <tr>
                  <td style="background-color:\(accentHex); text-align:center;">
                    <a href="\(link.htmlEscaped)" style="display:inline-block; padding:12px 14px; color:#FFFFFF; text-decoration:none; font-size:14px; font-weight:700;">\(buttonLabel.htmlEscaped)</a>
                  </td>
                </tr>
              </table>
            </td>
          </tr>
        </table>
        """
    }

    private func shouldUseMonospace(for value: String) -> Bool {
        value.contains("/") || value.contains("@") || value.contains("[patch-courier:") || value.contains("MRM-")
    }

    private func pendingApprovals(for thread: MailroomThreadRecord) async throws -> [MailroomApprovalRequest] {
        try await approvalStore
            .allApprovals()
            .filter {
                $0.status == .pending && (
                    $0.mailThreadToken == thread.id ||
                    ($0.codexThreadID == thread.codexThreadID && thread.codexThreadID != nil)
                )
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func updateThreadMailState(token: String, lastInboundMessageID: String?, lastOutboundMessageID: String?) async throws {
        guard var thread = try await threadStore.thread(token: token) else {
            return
        }
        if let lastInboundMessageID {
            thread.lastInboundMessageID = lastInboundMessageID
        }
        if let lastOutboundMessageID {
            thread.lastOutboundMessageID = lastOutboundMessageID
        }
        thread.updatedAt = Date()
        try await threadStore.save(thread: thread)
    }

    private func mapCapability(_ capability: MailCapability) -> MailroomCapability? {
        switch capability {
        case .readOnly:
            return .readOnly
        case .writeWorkspace:
            return .writeWorkspace
        case .executeShell:
            return .executeShell
        case .networkedAccess:
            return .networkedAccess
        case .secretAndConfig, .destructiveChange:
            return nil
        }
    }

    private func shouldUseProjectProbe(for policy: SenderPolicy) -> Bool {
        switch policy.assignedRole {
        case .admin, .operator:
            return true
        case .observer:
            return false
        }
    }

    private func manageableProjects(for policy: SenderPolicy) async throws -> [ManagedProject] {
        try await managedProjectStore
            .allManagedProjects()
            .filter { project in
                project.isEnabled && workspaceAllowed(project.rootPath, allowedRoots: policy.allowedWorkspaceRoots)
            }
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    private func resolveManagedProject(
        reference: String?,
        existingProjectID: String?,
        candidates: [ManagedProject]
    ) -> ManagedProject? {
        if let reference = reference?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !reference.isEmpty {
            return candidates.first(where: { project in
                project.id.lowercased() == reference ||
                project.slug.lowercased() == reference ||
                project.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == reference
            })
        }

        guard let existingProjectID else {
            return nil
        }
        return candidates.first(where: { $0.id == existingProjectID })
    }

    private func workspaceAllowed(_ workspaceRoot: String, allowedRoots: [String]) -> Bool {
        let normalizedWorkspace = normalizePath(workspaceRoot)
        return allowedRoots.contains { root in
            let normalizedRoot = normalizePath(root)
            return normalizedWorkspace == normalizedRoot || normalizedWorkspace.hasPrefix(normalizedRoot + "/")
        }
    }

    private func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path.lowercased()
    }

    private func composeManagedProjectProbeEnvelope(
        subject: String,
        threadToken: String,
        accountEmailAddress: String,
        senderAddress: String,
        senderRole: MailboxRole?,
        originalRequestBody: String?,
        projects: [ManagedProject],
        selectedProject: ManagedProject? = nil,
        note: String? = nil
    ) -> OutboundMailEnvelope {
        let outgoingSubject = composeOutboundSubject(baseSubject: subject, threadToken: threadToken, state: .actionNeeded)
        let summary = note?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
            ?? LT(
                "This sender is trusted. Choose one managed local project first, then reply with the command you want Codex to run.",
                "这个发件人已被信任。请先选一个受管本地项目，再回信写下希望 Codex 执行的命令。",
                "この送信者は信頼済みです。まず管理対象ローカルプロジェクトを 1 つ選び、その後 Codex に実行してほしい内容を返信してください。"
            )

        var fields: [MailEnvelopeField] = [
            MailEnvelopeField(label: LT("Thread", "线程", "スレッド"), value: "[patch-courier:\(threadToken)]", monospace: true)
        ]
        if let senderRole {
            fields.append(MailEnvelopeField(label: LT("Role", "角色", "ロール"), value: senderRole.rawValue, monospace: true))
        }
        if let selectedProject {
            fields.append(MailEnvelopeField(label: LT("Selected project", "已选项目", "選択済みプロジェクト"), value: "\(selectedProject.displayName) [\(selectedProject.slug)]"))
            fields.append(MailEnvelopeField(label: LT("Project path", "项目路径", "プロジェクトパス"), value: selectedProject.rootPath, monospace: true))
        }

        var sections: [MailEnvelopeSection] = []
        if let originalRequest = originalRequestBody?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank {
            sections.append(
                MailEnvelopeSection(
                    title: LT("Original request", "原始请求", "元の依頼"),
                    body: originalRequest,
                    monospace: false
                )
            )
        }

        sections.append(
            MailEnvelopeSection(
                title: LT("Manual reply format", "手动回信格式", "手動返信フォーマット"),
                body: """
                PROJECT: \(selectedProject?.slug ?? "<project-slug>")
                COMMAND: <what Codex should do>
                """,
                monospace: true
            )
        )

        let plainProjectListSection: MailEnvelopeSection? = {
            guard !projects.isEmpty else {
                return nil
            }
            let projectListText = projects.enumerated().map { index, project in
                var lines = ["\(index + 1). \(project.displayName) [\(project.slug)]"]
                if !project.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append(project.summary)
                }
                lines.append("PATH: \(project.rootPath)")
                lines.append(LT("Reply with:", "请回复：", "返信内容:"))
                lines.append("PROJECT: \(project.slug)")
                lines.append("COMMAND: <what Codex should do>")
                return lines.joined(separator: "\n")
            }.joined(separator: "\n\n")

            return MailEnvelopeSection(
                title: LT("Available projects", "可选项目", "選べるプロジェクト"),
                body: projectListText,
                monospace: false
            )
        }()

        let projectCardsHTML = projects.enumerated().map { index, project in
            let replyLink = makeManagedProjectReplyLink(
                recipient: accountEmailAddress,
                subject: outgoingSubject,
                threadToken: threadToken,
                projectSlug: project.slug
            )
            let projectSummaryHTML = project.summary
                .htmlEscaped
                .replacingOccurrences(of: "\n", with: "<br>")
            let summaryHTML = project.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ""
                : "<p style=\"margin:10px 0 0; color:#18212D; font-size:14px; line-height:1.7;\">\(projectSummaryHTML)</p>"
            let selectedBadge = selectedProject?.id == project.id
                ? "<span style=\"display:inline-block; margin-left:8px; padding:4px 8px; border-radius:999px; background:#EAF8F1; color:#1F8F63; font-size:11px; font-weight:700; letter-spacing:0.04em; text-transform:uppercase;\">\(LT("Selected", "已选", "選択済み").htmlEscaped)</span>"
                : ""
            let replySnippetHTML = """
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin-top:14px; width:100%; border-collapse:collapse; background-color:#F7F4EE; border:1px solid #D8DDE6;">
              <tr>
                <td style="padding:12px 14px;">
                  <div style="padding-bottom:6px; font-size:11px; line-height:1.4; letter-spacing:0.08em; text-transform:uppercase; color:#667085; font-weight:700;">\(LT("Manual reply", "手动回复", "手動返信").htmlEscaped)</div>
                  <div style="font:13px/1.75 ui-monospace, SFMono-Regular, Menlo, monospace; color:#18212D;">PROJECT: \(project.slug.htmlEscaped)<br>COMMAND: \(LT("<what Codex should do>", "<让 Codex 做什么>", "<Codex にしてほしいこと>").htmlEscaped)</div>
                </td>
              </tr>
            </table>
            """
            let card = """
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%; border-collapse:collapse; border:1px solid #D8DDE6; background-color:#FFFFFF;">
              <tr>
                <td style="padding:16px;">
                  <div style="font-size:18px; line-height:1.4; color:#18212D; font-weight:700;">\(project.displayName.htmlEscaped) <span style="display:inline-block; margin-left:8px; padding:4px 8px; border-radius:999px; background:#EEF4FF; color:#2D6CDF; font-family:ui-monospace, SFMono-Regular, Menlo, monospace; font-size:11px; font-weight:700;">\(project.slug.htmlEscaped)</span>\(selectedBadge)</div>
                  \(summaryHTML)
                  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin-top:12px; width:100%; border-collapse:collapse; border:1px solid #D8DDE6; background-color:#F7F4EE;">
                    <tr>
                      <td style="padding:10px 12px; color:#475467; font-size:13px; line-height:1.7; font-family:ui-monospace, SFMono-Regular, Menlo, monospace; word-wrap:break-word; overflow-wrap:anywhere;">\(project.rootPath.htmlEscaped)</td>
                    </tr>
                  </table>
                  \(replySnippetHTML)
                  <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin-top:14px; border-collapse:collapse;">
                    <tr>
                      <td style="background-color:#2D6CDF; text-align:center;">
                        <a href="\(replyLink.htmlEscaped)" style="display:inline-block; padding:12px 14px; color:#FFFFFF; text-decoration:none; font-size:14px; font-weight:700;">\(LT("Use this project", "用这个项目继续", "このプロジェクトで続行").htmlEscaped)</a>
                      </td>
                    </tr>
                  </table>
                </td>
              </tr>
            </table>
            """
            return (index == 0 ? "" : mailBlockSpacingHTML) + card
        }.joined()

        let extraSectionsHTML = projectCardsHTML.isEmpty ? [] : [
            mailSectionHTML(
                title: LT("Choose one project", "请选择一个项目", "1 つプロジェクトを選んでください"),
                bodyHTML: """
                <p style="margin:0 0 12px; color:#475467; font-size:15px; line-height:1.78;">\(LT("Pick the workspace that matches this task. The button opens a reply draft with PROJECT already filled in.", "选一个最适合这个任务的工作区。按钮会打开一封已自动填好 PROJECT 的回信草稿。", "このタスクに合うワークスペースを選んでください。ボタンを押すと PROJECT 入力済みの返信草稿が開きます。").htmlEscaped)</p>
                \(projectCardsHTML)
                """
            )
        ]

        let plainSections = plainProjectListSection.map { sections + [$0] } ?? sections

        return composeStatusEnvelope(
            to: [senderAddress],
            subject: outgoingSubject,
            tone: .info,
            statusLabel: LT("Waiting for project", "等待项目选择", "プロジェクト選択待ち"),
            title: LT("Choose a project to continue", "先选一个项目再继续", "続行するプロジェクトを選択してください"),
            summary: summary,
            fields: fields,
            sections: sections,
            plainSections: plainSections,
            extraSectionsHTML: extraSectionsHTML,
            nextSteps: [
                LT("Choose one project from the list below.", "先从下面列表里选一个项目。", "まず下の一覧から 1 つプロジェクトを選んでください。"),
                LT("Reply in this thread with PROJECT + COMMAND, or use the quick-reply button in a mail client that supports it.", "直接在这个线程里回复 PROJECT + COMMAND，或者在支持的邮箱客户端里点快捷回信按钮。", "このスレッドに PROJECT + COMMAND で返信するか、対応クライアントならクイック返信ボタンを使ってください。"),
                LT("Keep the thread token so Mailroom can attach your next reply to the same task.", "保留 thread token，这样 Mailroom 才能把下一封回信接到同一个任务上。", "thread token を残すと、Mailroom が次の返信を同じタスクへ紐づけられます。")
            ],
            footer: LT(
                "If your mail client does not open the quick link, just keep the THREAD line and reply manually using PROJECT + COMMAND.",
                "如果你的邮箱客户端没有自动打开快捷链接，也可以保留 THREAD 行，手动回信填写 PROJECT + COMMAND。",
                "メールクライアントがクイックリンクを開かない場合は、THREAD 行を残して PROJECT + COMMAND を手動で返信してください。"
            ),
            preheader: MailroomEmailHTML.preheader(
                LT(
                    "Choose one project first, then reply with PROJECT and COMMAND so Mailroom can continue this task.",
                    "请先选一个项目，再用 PROJECT 和 COMMAND 回复，这样 Mailroom 才能继续这个任务。",
                    "まず 1 つプロジェクトを選び、その後 PROJECT と COMMAND で返信すると Mailroom がこのタスクを続行できます。"
                )
            )
        )
    }

    private func makeManagedProjectReplyLink(
        recipient: String,
        subject: String,
        threadToken: String,
        projectSlug: String
    ) -> String {
        makeMailReplyLink(
            recipient: recipient,
            subject: subject,
            body: """
            THREAD: [patch-courier:\(threadToken)]
            PROJECT: \(projectSlug)
            COMMAND: 
            """
        )
    }

    private func makeThreadDecisionReplyLink(
        recipient: String,
        subject: String,
        threadToken: String,
        decision: ThreadConfirmationDecision
    ) -> String {
        let body: String
        switch decision {
        case .startTask:
            body = """
            THREAD: [patch-courier:\(threadToken)]
            MODE: START_TASK
            TASK:
            """
        case .recordOnly:
            body = """
            THREAD: [patch-courier:\(threadToken)]
            MODE: RECORD_ONLY
            """
        }

        return makeMailReplyLink(
            recipient: recipient,
            subject: subject,
            body: body
        )
    }

    private func makeMailReplyLink(recipient: String, subject: String, body: String) -> String {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = recipient
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        return components.string ?? "mailto:\(recipient)"
    }

    private func quickActionsHTML(
        title: String,
        actions: [MailQuickAction]
    ) -> String? {
        let cards = actions.enumerated().map { index, action in
            let card = mailActionCardHTML(
                badge: LT("Quick action", "快捷操作", "クイック操作"),
                title: action.title,
                detailHTML: mailInlineHTML(action.detail),
                accentHex: action.accentHex,
                link: action.link,
                buttonLabel: action.title
            )
            return (index == 0 ? "" : mailBlockSpacingHTML) + card
        }.joined()

        guard !cards.isEmpty else {
            return nil
        }

        return mailSectionHTML(title: title, bodyHTML: cards)
    }

    private func decisionActionSectionHTML(
        title: String,
        intro: String,
        actions: [MailQuickAction]
    ) -> String? {
        guard !actions.isEmpty else {
            return nil
        }

        let introHTML = intro
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
            .map {
                "<p style=\"margin:0 0 12px; color:#475467; font-size:15px; line-height:1.78;\">\($0.htmlEscaped)</p>"
            } ?? ""
        let cards = actions.enumerated().map { index, action in
            let replyLabel = actions.count == 1
                ? LT("Quick action", "快捷操作", "クイック操作")
                : LT("Reply \(index + 1)", "回复 \(index + 1)", "\(index + 1) と返信")
            let card = mailActionCardHTML(
                badge: replyLabel,
                title: action.title,
                detailHTML: mailInlineHTML(action.detail),
                accentHex: action.accentHex,
                link: action.link,
                buttonLabel: action.title
            )
            return (index == 0 ? "" : mailBlockSpacingHTML) + card
        }.joined()

        return mailSectionHTML(title: title, bodyHTML: introHTML + cards)
    }

    private func manualReplySectionHTML(
        title: String,
        intro: String? = nil,
        body: String
    ) -> String {
        let introHTML = intro?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
            .map {
                "<p style=\"margin:0 0 12px; color:#475467; font-size:15px; line-height:1.78;\">\($0.htmlEscaped)</p>"
            } ?? ""
        return mailSectionHTML(title: title, bodyHTML: introHTML + mailPreformattedHTML(body))
    }

    private func composeFirstContactEnvelope(
        subject: String,
        accountEmailAddress: String,
        threadToken: String,
        senderAddress: String,
        workspaceRoot: String,
        capability: MailroomCapability,
        originalRequestBody: String
    ) -> OutboundMailEnvelope {
        let originalRequest = originalRequestBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoingSubject = composeOutboundSubject(baseSubject: subject, threadToken: threadToken, state: .actionNeeded)
        let quickActions = [
            MailQuickAction(
                title: LT("Start now", "立即开始", "今すぐ開始"),
                detail: LT(
                    "Mailroom will open a Codex task using the request above. Add TASK only if you want to rewrite it.",
                    "Mailroom 会直接用上面的请求启动一个 Codex 任务。只有想改写任务时，才需要填写 TASK。",
                    "上の依頼を使って Mailroom がすぐに Codex タスクを開始します。TASK は依頼を書き換えたい時だけ入力してください。"
                ),
                link: makeThreadDecisionReplyLink(
                    recipient: accountEmailAddress,
                    subject: outgoingSubject,
                    threadToken: threadToken,
                    decision: .startTask
                ),
                accentHex: "#B87316",
                surfaceHex: "#FFF3E2"
            ),
            MailQuickAction(
                title: LT("Save for later", "先记下来", "後で使えるよう保存"),
                detail: LT(
                    "Mailroom will keep this email on record and stop here until you reply again.",
                    "Mailroom 会先把这封邮件记下来，并停在这里，等你以后再回复。",
                    "Mailroom はこのメールを記録して、次の返信が来るまでここで待機します。"
                ),
                link: makeThreadDecisionReplyLink(
                    recipient: accountEmailAddress,
                    subject: outgoingSubject,
                    threadToken: threadToken,
                    decision: .recordOnly
                ),
                accentHex: "#5B6574",
                surfaceHex: "#EEF1F5"
            )
        ]
        let htmlSections = [
            MailEnvelopeSection(
                title: LT("Original request", "原始请求", "元の依頼"),
                body: originalRequest.isEmpty ? LT("(No request body was captured.)", "（没有捕获到正文请求。）", "（依頼本文は取得できなかった。）") : originalRequest,
                monospace: false
            )
        ]
        let plainSections = htmlSections + [
            MailEnvelopeSection(
                title: LT("Reply choices", "回复选项", "返信オプション"),
                body: """
                1. \(LT("Use the original request above to start a Codex task.", "用上面的原始请求直接启动 Codex 任务。", "上の元の依頼をそのまま使って Codex タスクを開始する。"))
                2. \(LT("Record this email only. Do not start Codex yet.", "只记录这封邮件，暂时不要启动 Codex。", "このメールは記録だけ行い、まだ Codex は開始しない。"))
                """,
                monospace: false
            ),
            MailEnvelopeSection(
                title: LT("Structured reply", "结构化回复", "構造化返信"),
                body: """
                MODE: START_TASK
                TASK: <optional replacement task>

                \(LT("or", "或者", "または"))

                MODE: RECORD_ONLY
                """,
                monospace: true
            )
        ]
        let manualReplyBody = """
        \(LT("Start now", "立即开始", "今すぐ開始")):
        1
        \(LT("or", "或者", "または"))
        MODE: START_TASK
        TASK: <optional replacement task>

        \(LT("Save for later", "先记下来", "後で使えるよう保存")):
        2
        \(LT("or", "或者", "または"))
        MODE: RECORD_ONLY
        """
        let extraSectionsHTML = [
            decisionActionSectionHTML(
                title: LT("Choose how Mailroom should continue", "选一下 Mailroom 接下来怎么继续", "Mailroom の進め方を選んでください"),
                intro: LT(
                    "The buttons below open a reply draft. If they do not work in your mail app, use the manual reply block right after them.",
                    "下面的按钮会打开一封回信草稿；如果你的邮箱客户端不支持，就直接使用后面的手动回复格式。",
                    "下のボタンは返信草稿を開きます。メールアプリで使えない場合は、その後ろの手動返信フォーマットを使ってください。"
                ),
                actions: quickActions
            ),
            manualReplySectionHTML(
                title: LT("Manual reply", "手动回复", "手動返信"),
                intro: LT(
                    "Reply in the same thread and keep the THREAD line if your mail app strips quoted text.",
                    "如果邮箱客户端会删掉引用内容，请在同一个线程里回复，并保留 THREAD 行。",
                    "メールアプリが引用部分を削る場合は、このスレッドに返信し、THREAD 行を残してください。"
                ),
                body: manualReplyBody
            )
        ].compactMap { $0 }

        return composeStatusEnvelope(
            to: [senderAddress],
            subject: outgoingSubject,
            tone: .warning,
            statusLabel: LT("Waiting for decision", "等待确认", "確認待ち"),
            title: LT("Message received - choose the next step", "已经收到，选一下接下来怎么处理", "受信済みです。次の進め方を選んでください"),
            summary: LT(
                "Mailroom has saved this request. Before Codex starts, choose whether to begin now or keep it on record for later.",
                "Mailroom 已经收到并保存了这条请求。在启动 Codex 之前，请先选一下：现在开始，还是先留作记录。",
                "Mailroom はこの依頼を受信して保存しました。Codex を始める前に、今すぐ開始するか、後で使えるよう記録だけ残すかを選んでください。"
            ),
            fields: [
                MailEnvelopeField(label: LT("Thread", "线程", "スレッド"), value: "[patch-courier:\(threadToken)]", monospace: true),
                MailEnvelopeField(label: LT("Workspace", "工作区", "ワークスペース"), value: workspaceRoot, monospace: true),
                MailEnvelopeField(label: LT("Capability", "能力", "権限"), value: capability.rawValue, monospace: true)
            ],
            sections: htmlSections,
            plainSections: plainSections,
            extraSectionsHTML: extraSectionsHTML,
            nextSteps: [
                LT("Choose Start now if Codex should begin from the request above.", "如果要按上面的请求直接开始，就选“立即开始”。", "上の依頼でそのまま始めるなら「今すぐ開始」を選んでください。"),
                LT("Choose Save for later if this email should stay recorded only.", "如果现在只需要留档，就选“先记下来”。", "今は記録だけでよいなら「後で使えるよう保存」を選んでください。"),
                LT("If you fill in TASK, Mailroom will use that text instead of the original request.", "如果你填写了 TASK，Mailroom 会用它替换原始请求。", "TASK を入力すると、Mailroom は元の依頼の代わりにその内容を使います。")
            ],
            footer: LT(
                "If the quick reply button does not open, reply manually in this thread and keep the THREAD line. Leaving TASK empty tells Mailroom to use the original request shown above.",
                "如果快捷回复按钮没有打开，就直接在这个线程里手动回复，并保留 THREAD 行。TASK 留空时，Mailroom 会直接使用上面的原始请求。",
                "クイック返信ボタンが開かない場合は、このスレッドで手動返信し、THREAD 行を残してください。TASK を空のままにすると、Mailroom は上に表示した元の依頼をそのまま使います。"
            ),
            preheader: MailroomEmailHTML.preheader(
                LT(
                    "Mailroom received this request and is waiting for one choice: start now or save it for later.",
                    "Mailroom 已经收到这条请求，现在只差你选一下：立即开始，还是先记下来。",
                    "Mailroom はこの依頼を受信しました。今は「今すぐ開始」か「後で使えるよう保存」かの 1 つの選択を待っています。"
                )
            )
        )
    }

    private func composePendingDecisionReminderEnvelope(
        subject: String,
        accountEmailAddress: String,
        threadToken: String,
        senderAddress: String,
        workspaceRoot: String,
        capability: MailroomCapability,
        originalRequestBody: String?
    ) -> OutboundMailEnvelope {
        let originalRequest = originalRequestBody?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
            ?? LT("(Please include the task you want to run in your reply.)", "（请在回复里补充要执行的任务。）", "（実行したいタスクを返信に書いてください。）")
        let outgoingSubject = composeOutboundSubject(baseSubject: subject, threadToken: threadToken, state: .actionNeeded)
        let quickActions = [
            MailQuickAction(
                title: LT("Start now", "立即开始", "今すぐ開始"),
                detail: LT(
                    "Mailroom will resume immediately and turn the request above into a Codex task.",
                    "Mailroom 会立刻继续处理，并把上面的请求变成一个 Codex 任务。",
                    "Mailroom はすぐに再開し、上の依頼を Codex タスクに変換します。"
                ),
                link: makeThreadDecisionReplyLink(
                    recipient: accountEmailAddress,
                    subject: outgoingSubject,
                    threadToken: threadToken,
                    decision: .startTask
                ),
                accentHex: "#B87316",
                surfaceHex: "#FFF3E2"
            ),
            MailQuickAction(
                title: LT("Save for later", "先记下来", "後で使えるよう保存"),
                detail: LT(
                    "Mailroom will stop waiting and keep this thread recorded without starting Codex.",
                    "Mailroom 会停止等待，并把这个线程保留下来，但不会启动 Codex。",
                    "Mailroom は待機を終了し、このスレッドを記録したまま Codex は開始しません。"
                ),
                link: makeThreadDecisionReplyLink(
                    recipient: accountEmailAddress,
                    subject: outgoingSubject,
                    threadToken: threadToken,
                    decision: .recordOnly
                ),
                accentHex: "#5B6574",
                surfaceHex: "#EEF1F5"
            )
        ]
        let htmlSections = [
            MailEnvelopeSection(
                title: LT("Original request", "原始请求", "元の依頼"),
                body: originalRequest,
                monospace: false
            )
        ]
        let plainSections = htmlSections + [
            MailEnvelopeSection(
                title: LT("Reply choices", "回复选项", "返信オプション"),
                body: """
                1. \(LT("Start Codex with the original request above.", "按上面的原始请求启动 Codex。", "上の元の依頼で Codex を開始する。"))
                2. \(LT("Record only. Do not start Codex.", "仅记录，不启动 Codex。", "記録のみで、Codex は開始しない。"))
                """,
                monospace: false
            ),
            MailEnvelopeSection(
                title: LT("Structured reply", "结构化回复", "構造化返信"),
                body: """
                MODE: START_TASK
                TASK: <optional replacement task>

                \(LT("or", "或者", "または"))

                MODE: RECORD_ONLY
                """,
                monospace: true
            )
        ]
        let manualReplyBody = """
        \(LT("Start now", "立即开始", "今すぐ開始")):
        1
        \(LT("or", "或者", "または"))
        MODE: START_TASK
        TASK: <optional replacement task>

        \(LT("Save for later", "先记下来", "後で使えるよう保存")):
        2
        \(LT("or", "或者", "または"))
        MODE: RECORD_ONLY
        """
        let extraSectionsHTML = [
            decisionActionSectionHTML(
                title: LT("Choose how Mailroom should continue", "选一下 Mailroom 接下来怎么继续", "Mailroom の進め方を選んでください"),
                intro: LT(
                    "As soon as one clear reply arrives, Mailroom will continue this thread in that direction.",
                    "只要收到一个明确回复，Mailroom 就会按对应方向继续处理这个线程。",
                    "1 つ明確な返信が届きしだい、Mailroom はその選択に沿ってこのスレッドを続行します。"
                ),
                actions: quickActions
            ),
            manualReplySectionHTML(
                title: LT("Manual reply", "手动回复", "手動返信"),
                intro: LT(
                    "If the quick reply button does not open, reply in this thread and keep the THREAD line.",
                    "如果快捷回复按钮没有打开，就直接在这个线程里回复，并保留 THREAD 行。",
                    "クイック返信ボタンが開かない場合は、このスレッドで返信し、THREAD 行を残してください。"
                ),
                body: manualReplyBody
            )
        ].compactMap { $0 }

        return composeStatusEnvelope(
            to: [senderAddress],
            subject: outgoingSubject,
            tone: .warning,
            statusLabel: LT("Waiting for decision", "等待确认", "確認待ち"),
            title: LT("Still waiting for your choice", "还在等你的选择", "まだ選択を待っています"),
            summary: LT(
                "Mailroom already received this request and is paused here until you choose whether to start now or save it for later.",
                "Mailroom 已经收到这条请求，现在暂停在这里，等你选择：立即开始，还是先记下来。",
                "Mailroom はこの依頼を受信済みで、今は「今すぐ開始」か「後で使えるよう保存」かの選択を待って一時停止しています。"
            ),
            fields: [
                MailEnvelopeField(label: LT("Thread", "线程", "スレッド"), value: "[patch-courier:\(threadToken)]", monospace: true),
                MailEnvelopeField(label: LT("Workspace", "工作区", "ワークスペース"), value: workspaceRoot, monospace: true),
                MailEnvelopeField(label: LT("Capability", "能力", "権限"), value: capability.rawValue, monospace: true)
            ],
            sections: htmlSections,
            plainSections: plainSections,
            extraSectionsHTML: extraSectionsHTML,
            nextSteps: [
                LT("Choose Start now to turn the request above into active Codex work.", "如果要把上面的请求转成实际执行，就选“立即开始”。", "上の依頼を実際の Codex 作業に進めるなら「今すぐ開始」を選んでください。"),
                LT("Choose Save for later if this thread should stay recorded only.", "如果这个线程现在只需要留档，就选“先记下来”。", "このスレッドを今は記録だけにするなら「後で使えるよう保存」を選んでください。"),
                LT("If you include TASK, Mailroom will use that text instead of the original request.", "如果你填写 TASK，Mailroom 会改用那段文字，而不是原始请求。", "TASK を書くと、Mailroom は元の依頼ではなくその内容を使います。")
            ],
            footer: LT(
                "If the quick reply button does not open, reply manually in this thread and keep the THREAD line so Mailroom can match your answer.",
                "如果快捷回复按钮没有打开，就在这个线程里手动回复，并保留 THREAD 行，这样 Mailroom 才能正确匹配你的答案。",
                "クイック返信ボタンが開かない場合は、このスレッドで手動返信し、THREAD 行を残してください。そうすると Mailroom が返信を正しく照合できます。"
            ),
            preheader: MailroomEmailHTML.preheader(
                LT(
                    "Mailroom is still waiting for one choice on this request: start now or save it for later.",
                    "Mailroom 还在等这条请求的一个选择：立即开始，还是先记下来。",
                    "Mailroom はこの依頼について、今すぐ開始するか後で使えるよう保存するかの選択をまだ待っています。"
                )
            )
        )
    }

    private func composeRecordedOnlyEnvelope(
        subject: String,
        threadToken: String,
        senderAddress: String,
        accountEmailAddress: String,
        originalRequestBody: String? = nil
    ) -> OutboundMailEnvelope {
        let outgoingSubject = composeOutboundSubject(baseSubject: subject, threadToken: threadToken, state: .recorded)
        let originalRequest = originalRequestBody?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
        let manualReplyBody = """
        1
        \(LT("or", "或者", "または"))
        MODE: START_TASK
        TASK: <optional replacement task>
        """
        var sections: [MailEnvelopeSection] = []
        if let originalRequest {
            sections.append(
                MailEnvelopeSection(
                    title: LT("Saved request", "已保存的请求", "保存された依頼"),
                    body: originalRequest,
                    monospace: false
                )
            )
        }
        let plainSections = sections + [
            MailEnvelopeSection(
                title: LT("Manual reply", "手动回复", "手動返信"),
                body: manualReplyBody,
                monospace: true
            )
        ]
        let extraSectionsHTML = [
            decisionActionSectionHTML(
                title: LT("Ready to start later?", "准备好再开始时，用这个", "後で開始する準備ができたらこちら"),
                intro: LT(
                    "This thread is saved. When you want Mailroom to resume it, use the button below or reply manually in the same thread.",
                    "这个线程已经保存好了。等你准备让 Mailroom 继续时，可以点下面按钮，或者直接在同一个线程里手动回复。",
                    "このスレッドは保存済みです。Mailroom に再開させたいタイミングで、下のボタンを使うか、同じスレッドで手動返信してください。"
                ),
                actions: [
                    MailQuickAction(
                        title: LT("Start this task", "开始这个任务", "このタスクを開始"),
                        detail: LT(
                            "Mailroom will reopen this saved thread and use the original request unless you replace it in TASK.",
                            "Mailroom 会重新打开这个已保存的线程；如果你没有改写 TASK，它会继续使用原始请求。",
                            "Mailroom はこの保存済みスレッドを再開します。TASK で書き換えない限り、元の依頼をそのまま使います。"
                        ),
                        link: makeThreadDecisionReplyLink(
                            recipient: accountEmailAddress,
                            subject: outgoingSubject,
                            threadToken: threadToken,
                            decision: .startTask
                        ),
                        accentHex: "#2D6CDF",
                        surfaceHex: "#EEF6FF"
                    )
                ]
            ),
            manualReplySectionHTML(
                title: LT("Manual reply", "手动回复", "手動返信"),
                intro: LT(
                    "If the quick reply button does not open, reply in this thread with `1` or the structured block below.",
                    "如果快捷回复按钮没有打开，就在这个线程里回复 `1`，或者直接用下面这个结构化回复块。",
                    "クイック返信ボタンが開かない場合は、このスレッドで `1` と返信するか、下の構造化返信ブロックを使ってください。"
                ),
                body: manualReplyBody
            )
        ].compactMap { $0 }

        return composeStatusEnvelope(
            to: [senderAddress],
            subject: outgoingSubject,
            tone: .neutral,
            statusLabel: LT("Recorded only", "仅记录", "記録のみ"),
            title: LT("Saved for later, not started", "已记录，尚未开始", "記録済み、まだ開始していません"),
            summary: LT(
                "Mailroom saved this email, but did not start Codex work.",
                "Mailroom 已保存这封邮件，但还没有启动 Codex。",
                "Mailroom はこのメールを保存しましたが、Codex 作業はまだ開始していません。"
            ),
            fields: [
                MailEnvelopeField(label: LT("Thread", "线程", "スレッド"), value: "[patch-courier:\(threadToken)]", monospace: true)
            ],
            sections: sections,
            plainSections: plainSections,
            extraSectionsHTML: extraSectionsHTML,
            nextSteps: [
                LT("When you want to resume, use Start this task or reply with MODE: START_TASK.", "等你想恢复执行时，点“开始这个任务”，或者回复 MODE: START_TASK。", "再開したいタイミングで「このタスクを開始」を使うか、MODE: START_TASK と返信してください。"),
                LT("If TASK is left empty, Mailroom will reuse the saved original request.", "如果 TASK 留空，Mailroom 会继续使用已经保存的原始请求。", "TASK を空のままにすると、Mailroom は保存済みの元の依頼をそのまま使います。")
            ],
            footer: LT(
                "This thread stays saved until you reply again.",
                "这个线程会一直保持“已保存”状态，直到你再次回复。",
                "このスレッドは、あなたが再度返信するまで保存されたままです。"
            ),
            preheader: MailroomEmailHTML.preheader(
                LT(
                    "Saved for later. Reply here with START_TASK when you want Mailroom to run this request.",
                    "已经先保存。等你准备好后，直接在这里回复 START_TASK 就能让 Mailroom 开始执行。",
                    "後で使えるよう保存しました。実行したくなったら、このスレッドで START_TASK と返信してください。"
                )
            )
        )
    }

    private func composeRejectedEnvelope(
        subject: String,
        threadToken: String?,
        senderAddress: String,
        accountEmailAddress: String,
        originalRequestBody: String? = nil,
        note: String
    ) -> OutboundMailEnvelope {
        let outgoingSubject = composeOutboundSubject(baseSubject: subject, threadToken: threadToken, state: .rejected)
        let originalRequest = originalRequestBody?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
        let retryTemplate: String = {
            if let threadToken {
                return """
                THREAD: [patch-courier:\(threadToken)]

                <corrected request>
                """
            }
            return "<corrected request>"
        }()
        let retryLink = makeMailReplyLink(
            recipient: accountEmailAddress,
            subject: outgoingSubject,
            body: retryTemplate
        )
        var sections: [MailEnvelopeSection] = []
        if let originalRequest {
            sections.append(
                MailEnvelopeSection(
                    title: LT("Original request", "原始请求", "元の依頼"),
                    body: originalRequest,
                    monospace: false
                )
            )
        }
        sections.append(
            MailEnvelopeSection(
                title: LT("Reason", "原因", "理由"),
                body: note,
                monospace: false
            )
        )
        let plainSections = sections + [
            MailEnvelopeSection(
                title: LT("Manual reply", "手动回复", "手動返信"),
                body: retryTemplate,
                monospace: true
            )
        ]

        return composeStatusEnvelope(
            to: [senderAddress],
            subject: outgoingSubject,
            tone: .danger,
            statusLabel: LT("Rejected", "已拒绝", "拒否"),
            title: LT("Mailroom could not accept this email", "Mailroom 无法接受这封邮件", "Mailroom はこのメールを受け付けられなかった"),
            summary: LT(
                "This request was stopped before Codex started. See the reason below, then retry with a corrected request if needed.",
                "这条请求在 Codex 启动前就被拦下了。先看下面的原因；如果需要，再回信发送修正后的请求。",
                "この依頼は Codex 開始前に止められました。まず以下の理由を確認し、必要なら修正した依頼で再試行してください。"
            ),
            fields: [
                MailEnvelopeField(label: LT("Thread", "线程", "スレッド"), value: threadToken.map { "[patch-courier:\($0)]" } ?? LT("Unavailable", "不可用", "利用不可"), monospace: true)
            ],
            sections: sections,
            plainSections: plainSections,
            extraSectionsHTML: [
                decisionActionSectionHTML(
                    title: LT("Try again with a corrected request", "修正后再试一次", "修正した依頼でもう一度試す"),
                    intro: LT(
                        "If you want to retry, send a corrected request in this same thread. The button below opens a draft back to the Mailroom inbox.",
                        "如果你想重试，就在同一个线程里发回修正后的请求。下面的按钮会打开一封发回 Mailroom 收件箱的草稿。",
                        "やり直したい場合は、この同じスレッドで修正した依頼を送ってください。下のボタンを押すと Mailroom 宛ての草稿が開きます。"
                    ),
                    actions: [
                        MailQuickAction(
                            title: LT("Send corrected request", "发送修正后的请求", "修正した依頼を送る"),
                            detail: LT(
                                "Open a draft and replace the placeholder with the corrected request you want Mailroom to process.",
                                "打开一封草稿，把里面的占位内容替换成你想让 Mailroom 处理的修正后请求。",
                                "草稿を開き、プレースホルダーを Mailroom に処理してほしい修正後の依頼へ置き換えてください。"
                            ),
                            link: retryLink,
                            accentHex: "#2D6CDF",
                            surfaceHex: "#EEF6FF"
                        )
                    ]
                ),
                manualReplySectionHTML(
                    title: LT("Manual reply", "手动回复", "手動返信"),
                    intro: LT(
                        "If the quick reply button does not open, copy this block into your reply and replace the placeholder with your corrected request.",
                        "如果快捷回复按钮没有打开，就把这段内容复制到你的回复里，再把占位内容替换成修正后的请求。",
                        "クイック返信ボタンが開かない場合は、このブロックを返信へコピーし、プレースホルダーを修正後の依頼へ置き換えてください。"
                    ),
                    body: retryTemplate
                )
            ].compactMap { $0 },
            nextSteps: [
                LT("Review the reason below to see why Mailroom stopped this request.", "先看下面的原因，确认 Mailroom 为什么拦下了这条请求。", "まず以下の理由を確認し、なぜ Mailroom がこの依頼を止めたかを見てください。"),
                LT("If you still want to proceed, reply in this same thread with a corrected request.", "如果还想继续，就在这个线程里回复修正后的请求。", "続けたい場合は、この同じスレッドに修正した依頼を返信してください。"),
                LT("Keep the THREAD line if your mail client strips quoted text.", "如果邮箱客户端会删掉引用内容，请保留 THREAD 行。", "メールアプリが引用部分を削る場合は、THREAD 行を残してください。")
            ],
            footer: LT(
                "After a corrected reply arrives, Mailroom can evaluate the request again in the same thread.",
                "修正后的回复到达后，Mailroom 会在同一个线程里重新评估这条请求。",
                "修正した返信が届くと、Mailroom は同じスレッドでこの依頼を再評価できます。"
            ),
            preheader: MailroomEmailHTML.preheader(
                LT(
                    "This request could not be accepted. Open the email for the reason and reply with a corrected request if needed.",
                    "这条请求无法被接受。打开邮件查看原因；如果需要，可以直接回复修正后的请求。",
                    "この依頼は受け付けられませんでした。理由はメールを開いて確認し、必要なら修正した依頼を返信してください。"
                )
            )
        )
    }

    private func composeCompletionEnvelope(
        subject: String,
        threadToken: String?,
        projectName: String?,
        workspaceRoot: String?,
        body: String
    ) -> OutboundMailEnvelope {
        let resultSections = mailSections(
            from: body,
            defaultTitle: LT("Overview", "概览", "概要")
        )
        var fields: [MailEnvelopeField] = []
        if let threadToken {
            fields.append(MailEnvelopeField(label: LT("Thread", "线程", "スレッド"), value: "[patch-courier:\(threadToken)]", monospace: true))
        }
        if let projectName, !projectName.isEmpty {
            fields.append(MailEnvelopeField(label: LT("Project", "项目", "プロジェクト"), value: projectName))
        }
        if let workspaceRoot, !workspaceRoot.isEmpty {
            fields.append(MailEnvelopeField(label: LT("Workspace", "工作区", "ワークスペース"), value: workspaceRoot, monospace: true))
        }

        return composeStatusEnvelope(
            to: [],
            subject: composeOutboundSubject(baseSubject: subject, threadToken: threadToken, state: .completed),
            tone: .success,
            statusLabel: LT("Completed", "已完成", "完了"),
            title: LT("Your Mailroom task is done", "你的 Mailroom 任务已完成", "Mailroom のタスクが完了しました"),
            summary: LT(
                "Mailroom finished the requested Codex work. The latest result is below.",
                "Mailroom 已完成你请求的 Codex 工作，最新结果见下方。",
                "Mailroom は依頼された Codex 作業を完了しました。最新結果は以下です。"
            ),
            fields: fields,
            sections: resultSections.isEmpty
                ? [MailEnvelopeSection(title: LT("Result", "结果", "結果"), body: body, monospace: false)]
                : resultSections,
            footer: LT(
                "Reply to this email and keep the thread token if you want Codex to continue the same task.",
                "如果你想让 Codex 继续同一个任务，请直接回复这封邮件并保留 thread token。",
                "同じタスクを Codex に続行させたい場合は、このメールに返信し thread token を残してください。"
            ),
            preheader: MailroomEmailHTML.preheader(
                LT(
                    "Task finished. Open this email for the result, then reply here if you want a follow-up.",
                    "任务已完成。打开这封邮件查看结果；如果还要继续，直接在这里回复即可。",
                    "タスクが完了しました。結果はこのメールを開いて確認し、続きがあればこのスレッドへ返信してください。"
                )
            )
        )
    }

    private func composeFailureEnvelope(subject: String, threadToken: String?, body: String) -> OutboundMailEnvelope {
        let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let detailSections = mailSections(
            from: detail,
            defaultTitle: LT("Summary", "摘要", "要約")
        )
        var fields: [MailEnvelopeField] = []
        if let threadToken {
            fields.append(MailEnvelopeField(label: LT("Thread", "线程", "スレッド"), value: "[patch-courier:\(threadToken)]", monospace: true))
        }

        var sections: [MailEnvelopeSection] = []
        if !detail.isEmpty {
            if detailSections.isEmpty {
                sections.append(MailEnvelopeSection(title: LT("Details", "详情", "詳細"), body: detail, monospace: false))
            } else {
                sections.append(contentsOf: detailSections)
            }
        }

        return composeStatusEnvelope(
            to: [],
            subject: composeOutboundSubject(baseSubject: subject, threadToken: threadToken, state: .failed),
            tone: .danger,
            statusLabel: LT("Failed", "失败", "失敗"),
            title: LT("Mailroom couldn't finish this task", "Mailroom 暂时没能完成这个任务", "Mailroom はこのタスクを完了できませんでした"),
            summary: LT(
                "This task did not complete successfully. See the details below.",
                "这次任务没有顺利完成，详情见下方。",
                "このタスクは正常完了しませんでした。詳細は以下です。"
            ),
            fields: fields,
            sections: sections,
            nextSteps: [
                LT("Reply in this thread if you want to clarify the request or try again.", "如果你想补充说明或重试，可以直接在这个线程里回复。", "依頼を補足したり再試行したい場合は、このスレッドに返信してください。")
            ],
            preheader: MailroomEmailHTML.preheader(
                LT(
                    "Task stopped before completion. Open the details, then reply here if you want to retry or clarify the request.",
                    "任务未能完成。打开邮件查看详情；如果你想重试或补充说明，直接在这里回复即可。",
                    "タスクは完了前に停止しました。詳細はメールを開いて確認し、再試行や補足があればこのスレッドへ返信してください。"
                )
            )
        )
    }

    func renderMailPreviewFixtures(outputDirectory: URL) throws -> MailPreviewFixtureManifest {
        let now = Date()
        let workspaceRoot = configuration.defaultWorkspaceRoot
        let account = MailboxAccount(
            id: "preview-account",
            label: "Tokyo Operator",
            emailAddress: "codex-tokyo@example.com",
            role: .operator,
            workspaceRoot: workspaceRoot,
            imap: MailServerEndpoint(host: "imap.example.com", port: 993, security: .sslTLS),
            smtp: MailServerEndpoint(host: "smtp.example.com", port: 465, security: .sslTLS),
            pollingIntervalSeconds: 60,
            createdAt: now,
            updatedAt: now
        )
        let senderAddress = "product-team@example.com"
        let baseSubject = "Investigate login timeout in dashboard"
        let requestBody = """
        Please investigate the login timeout regression in the dashboard.
        Check the most likely root cause, propose the safest fix, and call out any migration or rollout risk before changing code.
        """
        let managedProjects = [
            ManagedProject(
                id: "preview-dashboard",
                displayName: "Mailroom Dashboard",
                slug: "mailroom-dashboard",
                rootPath: "\(workspaceRoot)/patch-courier",
                summary: "Customer-facing mailbox operations UI plus daemon control console.",
                defaultCapability: .writeWorkspace,
                isEnabled: true,
                createdAt: now,
                updatedAt: now
            ),
            ManagedProject(
                id: "preview-docs",
                displayName: "Docs Site",
                slug: "docs-site",
                rootPath: "\(workspaceRoot)/docs-site",
                summary: "Marketing and support content site maintained by the same team.",
                defaultCapability: .readOnly,
                isEnabled: true,
                createdAt: now,
                updatedAt: now
            )
        ]

        let receivedToken = "MRM-PREVIEW-RECEIVED"
        let receivedEnvelope = composeStatusEnvelope(
            to: [senderAddress],
            subject: composeOutboundSubject(baseSubject: baseSubject, threadToken: receivedToken, state: .received),
            tone: .info,
            statusLabel: LT("Received", "已接收", "受信済み"),
            title: LT("Email received, task is starting", "已收到邮件，任务启动中", "メールを受信し、タスクを開始しています"),
            summary: LT(
                "Mailroom accepted your request and has started preparing the Codex task.",
                "Mailroom 已接收你的请求，正在启动对应的 Codex 任务。",
                "Mailroom は依頼を受け付け、Codex タスクの開始準備を進めています。"
            ),
            fields: makeReceiptFields(
                threadToken: receivedToken,
                projectName: "Mailroom Dashboard",
                workspaceRoot: workspaceRoot,
                capability: .writeWorkspace,
                senderAddress: senderAddress
            ),
            sections: [
                MailEnvelopeSection(
                    title: LT("What we received", "已收到内容", "受信内容"),
                    body: requestBody,
                    monospace: false
                )
            ],
            nextSteps: [
                LT("Run the requested Codex work in the selected workspace.", "在选定的工作区里开始执行你请求的 Codex 工作。", "選択されたワークスペースで依頼された Codex 作業を実行する。"),
                LT("If approval or more information is needed, Mailroom will send a structured follow-up email.", "如果需要审批或更多信息，Mailroom 会再发一封结构化跟进邮件。", "承認や追加情報が必要なら、Mailroom が構造化フォローアップメールを送ります。"),
                LT("Otherwise, the final result will be sent back in this same thread.", "否则，最终结果会继续在这个线程里发回给你。", "それ以外の場合は、最終結果をこの同じスレッドで返信します。")
            ],
            footer: LT(
                "No need to resend the same email. If you want to add context, just reply here and keep the thread token.",
                "不需要重复发送同一封邮件。如果你想补充上下文，直接在这里回复并保留 thread token 即可。",
                "同じメールを再送する必要はありません。補足したい場合は、ここに返信して thread token を残してください。"
            ),
            preheader: MailroomEmailHTML.preheader(
                LT(
                    "Task accepted. Codex is starting now and will email you here if it needs approval or more information.",
                    "任务已接收。Codex 正在启动；如果后续需要审批或更多信息，会继续发到这个线程。",
                    "タスクを受け付けました。Codex を開始しており、承認や追加情報が必要ならこのスレッドへ続報します。"
                )
            )
        )

        let firstContactEnvelope = composeFirstContactEnvelope(
            subject: "New analytics workspace request",
            accountEmailAddress: account.emailAddress,
            threadToken: "MRM-PREVIEW-FIRST",
            senderAddress: senderAddress,
            workspaceRoot: workspaceRoot,
            capability: .writeWorkspace,
            originalRequestBody: """
            Please inspect the analytics workspace, confirm whether the current migration is safe to apply, and tell me the next step before shipping.
            """
        )

        let managedProjectEnvelope = composeManagedProjectProbeEnvelope(
            subject: "Add a project status badge to the admin console",
            threadToken: "MRM-PREVIEW-PROJECT",
            accountEmailAddress: account.emailAddress,
            senderAddress: senderAddress,
            senderRole: .operator,
            originalRequestBody: """
            Pick the right local project first, then add a small project status badge to the admin console header and describe the safest rollout plan.
            """,
            projects: managedProjects
        )

        let approvalEnvelope = ApprovalMailComposer.compose(
            request: MailroomApprovalRequest(
                id: "APR-PREVIEW-001",
                rpcRequestID: .integer(101),
                kind: .commandExecution,
                mailThreadToken: "MRM-PREVIEW-APPROVAL",
                codexThreadID: "codex-thread-preview",
                codexTurnID: "turn-preview-approval",
                itemID: "shell-command-1",
                summary: LT("Approve a guarded shell command", "批准一个受保护的 shell 命令", "保護されたシェルコマンドを承認してください"),
                detail: LT(
                    "Codex wants to run `xcodebuild -project PatchCourier.xcodeproj -scheme PatchCourierMac build` inside the workspace before applying the fix.",
                    "Codex 想先在工作区里运行 `xcodebuild -project PatchCourier.xcodeproj -scheme PatchCourierMac build`，再继续修复。",
                    "Codex は修正を適用する前に、ワークスペース内で `xcodebuild -project PatchCourier.xcodeproj -scheme PatchCourierMac build` を実行したいと考えています。"
                ),
                availableDecisions: ["approve", "reject"],
                rawPayload: .object([:]),
                status: .pending,
                resolvedDecision: nil,
                resolutionNote: nil,
                createdAt: now,
                resolvedAt: nil
            ),
            recipient: senderAddress,
            replyAddress: account.emailAddress,
            subject: composeOutboundSubject(
                baseSubject: "Run guarded verification before patching the login timeout",
                threadToken: "MRM-PREVIEW-APPROVAL",
                state: .actionNeeded
            )
        )

        let completionEnvelope = addressEnvelope(
            composeCompletionEnvelope(
                subject: baseSubject,
                threadToken: "MRM-PREVIEW-DONE",
                projectName: "Mailroom Dashboard",
                workspaceRoot: workspaceRoot,
                body: """
                Root cause:
                The dashboard was still reading the legacy session cookie after the auth gateway switched to the new token name.

                What changed:
                - Updated the dashboard auth middleware to read the new cookie first.
                - Kept the legacy cookie as a temporary fallback during rollout.
                - Added a focused regression test for the timeout path.

                Risk notes:
                Rollout is low risk because the old cookie path remains supported while sessions refresh.
                """
            ),
            recipient: senderAddress
        )

        let failureEnvelope = addressEnvelope(
            composeFailureEnvelope(
                subject: baseSubject,
                threadToken: "MRM-PREVIEW-FAILED",
                body: """
                Codex could not finish because the workspace build failed before the verification step completed.

                Blocking detail:
                `xcodebuild` stopped on a missing signing setting in the local environment.

                Suggested recovery:
                Reply in this thread if you want Mailroom to retry with a different build command or skip the local build step.
                """
            ),
            recipient: senderAddress
        )

        let recordedEnvelope = composeRecordedOnlyEnvelope(
            subject: "New analytics workspace request",
            threadToken: "MRM-PREVIEW-RECORDED",
            senderAddress: senderAddress,
            accountEmailAddress: account.emailAddress,
            originalRequestBody: """
            Please prepare a new analytics workspace, confirm the safest initial setup, and hold the task until I explicitly tell Mailroom to start.
            """
        )

        let rejectedEnvelope = composeRejectedEnvelope(
            subject: "Unsupported destructive request",
            threadToken: "MRM-PREVIEW-REJECTED",
            senderAddress: senderAddress,
            accountEmailAddress: account.emailAddress,
            originalRequestBody: """
            Delete the production workspace history outside the approved project roots and clean up every leftover build artifact you can find.
            """,
            note: LT(
                "The request asked Mailroom to run a destructive shell command outside the allowed workspace roots.",
                "这条请求要求 Mailroom 在允许的工作区根目录之外执行一个破坏性 shell 命令。",
                "この依頼は、許可されたワークスペースルート外で破壊的なシェルコマンドを実行するよう Mailroom に求めていました。"
            )
        )

        let runtimeChallengeToken = "MRM-PREVIEW-RUNTIME-CHALLENGE"
        let runtimeChallengeTitle = LT(
            "Message received - reply once to confirm",
            "已经收到，请回复一次确认",
            "受信済みです。1 回返信して確認してください"
        )
        let runtimeChallengeSummary = LT(
            "Mailroom received this request. One reply from the same sender with the thread token below will confirm the thread and unlock the next step.",
            "Mailroom 已经收到这条请求。只要同一位发件人带着下面的 thread token 回复一次，这个线程就完成确认，后续就能继续处理。",
            "Mailroom はこの依頼を受信しました。同じ送信者から下の thread token を付けて 1 回返信すれば、このスレッドの確認が完了し、次の処理へ進めます。"
        )
        let runtimeChallengeReplyTemplate = """
        THREAD: [patch-courier:\(runtimeChallengeToken)]

        \(LT("Any short reply is fine.", "写一句简短回复即可。", "短い返信なら何でも構いません。"))
        """
        let runtimeChallengeEnvelope = composeStatusEnvelope(
            to: [senderAddress],
            subject: composeOutboundSubject(
                baseSubject: LT("Patch Courier reply token", "Patch Courier 回复 token", "Patch Courier 返信トークン"),
                threadToken: runtimeChallengeToken,
                state: .actionNeeded
            ),
            tone: .warning,
            statusLabel: LT("Action needed", "需要回复", "返信が必要"),
            title: runtimeChallengeTitle,
            summary: runtimeChallengeSummary,
            fields: [
                MailEnvelopeField(label: LT("Thread", "线程", "スレッド"), value: "[patch-courier:\(runtimeChallengeToken)]", monospace: true),
                MailEnvelopeField(label: LT("Sender", "发件人", "送信者"), value: senderAddress, monospace: true)
            ],
            sections: [
                MailEnvelopeSection(
                    title: LT("Original request", "原始请求", "元の依頼"),
                    body: """
                    Please take this request as the first item from this sender, confirm the mailbox thread, and continue after a one-line acknowledgment reply arrives.
                    """,
                    monospace: false
                )
            ],
            plainSections: [
                MailEnvelopeSection(
                    title: LT("Original request", "原始请求", "元の依頼"),
                    body: """
                    Please take this request as the first item from this sender, confirm the mailbox thread, and continue after a one-line acknowledgment reply arrives.
                    """,
                    monospace: false
                ),
                MailEnvelopeSection(
                    title: LT("Reply once in this thread", "在这个线程里回复一次", "このスレッドで 1 回返信"),
                    body: runtimeChallengeReplyTemplate,
                    monospace: true
                )
            ],
            extraSectionsHTML: [
                mailSectionHTML(
                    title: LT("Next step", "接下来怎么做", "次にすること"),
                    bodyHTML: """
                    <p style="margin:0 0 12px; color:#475467; font-size:15px; line-height:1.78;">\(LT("This first reply is just a quick sender check. You do not need to rewrite the full request yet.", "这第一封回复只是一个快速确认发件人的动作，现在还不需要重写整条请求。", "この最初の返信は送信者確認のための簡単なチェックです。まだ依頼全文を書き直す必要はありません。").htmlEscaped)</p>
                    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin-top:12px; width:100%; border-collapse:collapse; border:1px solid #D8DDE6; background-color:#FFFFFF;">
                      <tr>
                        <td style="padding:16px;">
                          <div style="font-size:11px; line-height:1.2; letter-spacing:0.08em; text-transform:uppercase; color:#B87316; font-weight:700;">\(LT("Step 1", "第 1 步", "ステップ 1").htmlEscaped)</div>
                          <div style="padding-top:10px; font-size:19px; line-height:1.4; color:#18212D; font-weight:700;">\(LT("Reply once in this thread", "在这个线程里回复一次", "このスレッドで 1 回返信").htmlEscaped)</div>
                          <p style="margin:10px 0 0; color:#475467; font-size:14px; line-height:1.72;">\(LT("A short “got it” reply is enough. The important part is keeping the THREAD line so Mailroom can match your message.", "哪怕只回一句“收到”也可以，关键是保留 THREAD 行，这样 Mailroom 才能正确匹配你的回信。", "「了解しました」のような短い返信で十分です。大事なのは THREAD 行を残して、Mailroom が返信を照合できるようにすることです。").htmlEscaped)</p>
                          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin-top:14px; width:100%; border-collapse:collapse; background-color:#F7F4EE; border:1px solid #D8DDE6;">
                            <tr>
                              <td style="padding:12px 14px; color:#18212D; font:13px/1.75 ui-monospace, SFMono-Regular, Menlo, monospace; word-wrap:break-word; overflow-wrap:anywhere;">THREAD: [patch-courier:\(runtimeChallengeToken.htmlEscaped)]</td>
                            </tr>
                          </table>
                        </td>
                      </tr>
                    </table>
                    """
                ),
                mailSectionHTML(
                    title: LT("Manual reply", "手动回复", "手動返信"),
                    bodyHTML: """
                    <p style="margin:0 0 12px; color:#475467; font-size:15px; line-height:1.78;">\(LT("If your mail app removes quoted text, copy this block into your reply before sending.", "如果邮箱客户端会删掉引用内容，请把这段内容复制到你的回复里再发送。", "メールアプリが引用部分を削る場合は、このブロックを返信へコピーしてから送信してください。").htmlEscaped)</p>
                    \(mailPreformattedHTML(runtimeChallengeReplyTemplate))
                    """
                )
            ],
            nextSteps: [
                LT("Reply once in this same thread from the same sender address.", "请用同一个发件地址，在这个线程里回复一次。", "同じ送信者アドレスで、このスレッドに 1 回返信してください。"),
                LT("Keep the THREAD line unchanged; a short acknowledgment is enough.", "请保留 THREAD 行不变；哪怕只回一句简短确认也可以。", "THREAD 行はそのまま残してください。短い確認返信で十分です。"),
                LT("After that confirmation arrives, Mailroom will trust the next step from this sender in the same thread.", "这封确认回复到达后，Mailroom 就会信任同一发件人在这个线程里的后续请求。", "この確認返信が届くと、Mailroom は同じ送信者からこのスレッドで届く次の依頼を信頼します。")
            ],
            footer: LT(
                "If your mail app removes quoted text, copy the reply block back into your message before sending.",
                "如果邮箱客户端删掉了引用内容，请在发送前把上面的回复块重新贴回邮件里。",
                "メールアプリが引用部分を削る場合は、送信前に上の返信ブロックをメールへ貼り戻してください。"
            ),
            preheader: MailroomEmailHTML.preheader(
                LT(
                    "Mailroom received this request. Reply once with the thread token below to confirm the sender and unlock the next step.",
                    "Mailroom 已经收到这条请求。请带着下面的 thread token 回复一次，确认发件人后就能进入下一步。",
                    "Mailroom はこの依頼を受信しました。下の thread token を付けて 1 回返信すると、送信者確認が完了し、次の処理へ進めます。"
                )
            )
        )

        let fixtures = [
            makeMailPreviewFixture(
                id: "daemon-received-task-starting",
                title: "Daemon receipt",
                summary: "Immediate acknowledgement sent as soon as Mailroom accepts a new inbound request and starts the task.",
                envelope: receivedEnvelope
            ),
            makeMailPreviewFixture(
                id: "daemon-first-contact-decision",
                title: "First-contact decision",
                summary: "Sent to a new sender when Mailroom still needs an explicit start-vs-record-only choice before Codex runs.",
                envelope: firstContactEnvelope
            ),
            makeMailPreviewFixture(
                id: "daemon-managed-project-selection",
                title: "Managed project selection",
                summary: "Asks a trusted sender to choose one managed local project before Mailroom continues with the command.",
                envelope: managedProjectEnvelope
            ),
            makeMailPreviewFixture(
                id: "daemon-approval-request",
                title: "Approval request",
                summary: "Paused task requesting a single decision reply, including quick-reply mailto actions and the styled HTML envelope.",
                envelope: approvalEnvelope
            ),
            makeMailPreviewFixture(
                id: "daemon-completed-result",
                title: "Completion",
                summary: "Successful final result email showing the mailbox-friendly completion template and follow-up guidance.",
                envelope: completionEnvelope
            ),
            makeMailPreviewFixture(
                id: "daemon-failed-result",
                title: "Failure",
                summary: "Terminal failure email with clear retry guidance and a plain-text fallback body for mailbox clients.",
                envelope: failureEnvelope
            ),
            makeMailPreviewFixture(
                id: "daemon-recorded-only",
                title: "Recorded only",
                summary: "Confirmation that Mailroom saved the request without starting Codex yet, plus a clean resume path for later.",
                envelope: recordedEnvelope
            ),
            makeMailPreviewFixture(
                id: "daemon-rejected-request",
                title: "Rejected request",
                summary: "Rejected request email with a visible reason and a mailbox-friendly retry path back into the same thread.",
                envelope: rejectedEnvelope
            ),
            makeMailPreviewFixture(
                id: "runtime-first-confirmation",
                title: "Runtime sender confirmation",
                summary: "Legacy runtime confirmation email shown before Mailroom trusts a first-time sender in the same thread.",
                envelope: runtimeChallengeEnvelope
            )
        ]

        return try MailPreviewFixtureWriter.write(fixtures, to: outputDirectory)
    }

    private func makeMailPreviewFixture(
        id: String,
        title: String,
        summary: String,
        envelope: OutboundMailEnvelope
    ) -> MailPreviewFixture {
        let preview = mailPreviewText(from: envelope)
        return MailPreviewFixture(
            id: id,
            title: title,
            summary: summary,
            recipients: envelope.to,
            subject: envelope.subject,
            preview: preview.isEmpty ? envelope.subject : preview,
            plainBody: envelope.plainBody,
            htmlBody: envelope.htmlBody
        )
    }

    private func mailPreviewText(from envelope: OutboundMailEnvelope) -> String {
        guard let htmlDocument = envelope.htmlBody else {
            return ""
        }
        let pattern = #"<div style="display:none;[^"]*">\s*(.*?)\s*</div>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return ""
        }
        let range = NSRange(htmlDocument.startIndex..<htmlDocument.endIndex, in: htmlDocument)
        guard let match = regex.firstMatch(in: htmlDocument, options: [], range: range),
              let previewRange = Range(match.range(at: 1), in: htmlDocument) else {
            return ""
        }

        let rawPreview = String(htmlDocument[previewRange])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .htmlUnescaped
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rawPreview
    }

    private func composeOutboundSubject(baseSubject: String, threadToken: String?, state: MailSubjectState? = nil) -> String {
        let normalizedSubject = normalizeMailSubject(baseSubject)
        var decoratedSubject = normalizedSubject
        if let state {
            decoratedSubject = "[\(state.prefix)]" + (decoratedSubject.isEmpty ? "" : " " + decoratedSubject)
        }
        if let threadToken, !threadToken.isEmpty {
            decoratedSubject = decoratedSubject.isEmpty
                ? "[patch-courier:\(threadToken)]"
                : decoratedSubject + " [patch-courier:\(threadToken)]"
        } else if decoratedSubject.isEmpty {
            decoratedSubject = LT("Patch Courier", "Patch Courier", "Patch Courier")
        }
        return decoratedSubject.lowercased().hasPrefix("re:") ? decoratedSubject : "Re: \(decoratedSubject)"
    }

    private func normalizeMailSubject(_ subject: String) -> String {
        MailroomMailParser.normalizeSubject(subject)
    }

    private func composeReferences(from existing: [String], inReplyTo: String?, originalMessageID: String) -> [String] {
        var references = existing
        if let inReplyTo, !references.contains(inReplyTo) {
            references.append(inReplyTo)
        }
        if !references.contains(originalMessageID) {
            references.append(originalMessageID)
        }
        return references
    }

    private func outcomeNote(_ outcome: MailroomTurnOutcome) -> String {
        switch outcome.state {
        case .completed:
            return LT("Completed and replied by email.", "已完成并通过邮件回复。", "完了しメールで返信した。")
        case .waitingOnApproval:
            return outcome.approvalSummary ?? LT("Sent an approval request email.", "已发送审批请求邮件。", "承認依頼メールを送信した。")
        case .waitingOnUserInput:
            return outcome.approvalSummary ?? LT("Sent a user-input request email.", "已发送用户输入请求邮件。", "追加入力依頼メールを送信した。")
        case .failed:
            return LT("Codex failed and a failure email was sent.", "Codex 失败，并已发送失败邮件。", "Codex が失敗し、失敗通知メールを送信した。")
        case .systemError:
            return LT("Codex hit a system error and a failure email was sent.", "Codex 遇到系统错误，并已发送失败邮件。", "Codex がシステムエラーに遭遇し、失敗通知メールを送信した。")
        }
    }

    private func action(for outcome: MailroomTurnOutcome) -> MailroomMailboxMessageAction {
        switch outcome.state {
        case .completed:
            return .completed
        case .waitingOnApproval, .waitingOnUserInput:
            return .approvalRequested
        case .failed, .systemError:
            return .failed
        }
    }

    private func makeMailThreadToken() -> String {
        "MRM-\(UUID().uuidString.prefix(8).uppercased())"
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var htmlEscaped: String {
        self
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    var htmlUnescaped: String {
        self
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&zwnj;", with: "")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
