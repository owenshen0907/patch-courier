import Foundation

private enum MailroomRuntimeSubjectState {
    case received
    case actionNeeded
    case completed
    case failed
    case rejected

    var prefix: String {
        switch self {
        case .received:
            return "Patch Courier Update"
        case .actionNeeded:
            return "Patch Courier Reply Needed"
        case .completed:
            return "Patch Courier Done"
        case .failed:
            return "Patch Courier Failed"
        case .rejected:
            return "Patch Courier Rejected"
        }
    }

    var statusLabel: String {
        switch self {
        case .received:
            return LT("Received", "已接收", "受信済み")
        case .actionNeeded:
            return LT("Action needed", "需要回复", "返信が必要")
        case .completed:
            return LT("Completed", "已完成", "完了")
        case .failed:
            return LT("Failed", "失败", "失敗")
        case .rejected:
            return LT("Rejected", "已拒绝", "拒否")
        }
    }
}

private enum MailroomRuntimeEnvelopeTone {
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

private let runtimeMailBlockSpacingHTML = """
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%; border-collapse:collapse;">
  <tr>
    <td style="height:16px; line-height:16px; font-size:16px;">&nbsp;</td>
  </tr>
</table>
"""

private struct MailroomRuntimeEnvelopeField {
    var label: String
    var value: String
    var monospace: Bool = false
}

private struct MailroomRuntimeEnvelopeSection {
    var title: String
    var body: String
    var monospace: Bool = false
}

private struct MailroomRuntimeRenderedMessage {
    var subjectState: MailroomRuntimeSubjectState
    var plainBody: String
    var htmlBody: String?
}

private enum MailroomRuntimeEmailHTML {
    static func preheader(_ preview: String?) -> String {
        preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func preheader(statusLabel: String, title: String, summary: String? = nil) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedStatus = statusLabel.trimmingCharacters(in: .whitespacesAndNewlines)

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

actor MailroomRuntime {
    private let accountStore: MailboxAccountStore
    private let senderPolicyStore: SenderPolicyStore
    private let jobStore: SQLiteJobStore
    private let secretStore: KeychainSecretStore
    private let stateStore: MailRuntimeStateStore
    private let transportClient: MailTransportClient
    private let skillInstaller: MailroomSkillInstaller
    private let policyEngine = MailPolicyEngine()

    init(
        accountStore: MailboxAccountStore,
        senderPolicyStore: SenderPolicyStore,
        jobStore: SQLiteJobStore,
        secretStore: KeychainSecretStore,
        stateStore: MailRuntimeStateStore,
        transportClient: MailTransportClient,
        skillInstaller: MailroomSkillInstaller = MailroomSkillInstaller()
    ) {
        self.accountStore = accountStore
        self.senderPolicyStore = senderPolicyStore
        self.jobStore = jobStore
        self.secretStore = secretStore
        self.stateStore = stateStore
        self.transportClient = transportClient
        self.skillInstaller = skillInstaller
    }

    func syncMailbox(accountID: String) throws -> MailroomSyncOutcome {
        let accounts = try accountStore.load()
        guard let account = accounts.first(where: { $0.id == accountID }) else {
            return MailroomSyncOutcome(
                processedJobs: [],
                ignoredCount: 0,
                needsReload: false,
                statusMessage: nil
            )
        }

        guard let password = try secretStore.password(for: accountID), !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return MailroomSyncOutcome(
                processedJobs: [],
                ignoredCount: 0,
                needsReload: false,
                statusMessage: LT(
                    "Mailbox \(account.emailAddress) is missing its saved password, so polling is paused.",
                    "邮箱 \(account.emailAddress) 缺少已保存密码，因此轮询已暂停。",
                    "メールボックス \(account.emailAddress) は保存済みパスワードがないため、ポーリングを一時停止した。"
                )
            )
        }

        let policies = try senderPolicyStore.load().filter(\.isEnabled)
        var runtimeState = try stateStore.load()
        let lastUID = runtimeState.syncStates.first(where: { $0.accountID == accountID })?.lastSeenUID
        let fetchResult = try transportClient.fetchMessages(account: account, password: password, lastUID: lastUID)

        upsertSyncState(
            in: &runtimeState,
            accountID: accountID,
            lastUID: fetchResult.lastUID,
            processedAt: Date()
        )

        if fetchResult.didBootstrap {
            try stateStore.save(runtimeState)
            return MailroomSyncOutcome(
                processedJobs: [],
                ignoredCount: 0,
                needsReload: false,
                statusMessage: LT(
                    "Mailbox \(account.emailAddress) is now watching new mail from this point forward.",
                    "邮箱 \(account.emailAddress) 已开始监听从现在起的新邮件。",
                    "メールボックス \(account.emailAddress) はこの時点以降の新着メールを監視する。"
                )
            )
        }

        let skillURL = try skillInstaller.ensureInstalled()
        let bridge = CodexBridge(jobStore: jobStore, mailroomSkillURL: skillURL)

        var processedJobs: [ExecutionJobRecord] = []
        var ignoredCount = 0

        for message in fetchResult.messages.sorted(by: { $0.uid < $1.uid }) {
            if message.fromAddress.lowercased() == account.emailAddress.lowercased() {
                ignoredCount += 1
                continue
            }

            guard let policy = policies.first(where: { $0.normalizedSenderAddress == message.fromAddress.lowercased() }) else {
                ignoredCount += 1
                continue
            }

            let parsedCommand = MailroomMailParser.parseCommand(
                from: message,
                fallbackWorkspaceRoot: policy.allowedWorkspaceRoots.first ?? account.workspaceRoot
            )

            let matchingConversationIndex = parsedCommand.detectedToken.flatMap { token in
                runtimeState.conversations.firstIndex(where: {
                    $0.id == token &&
                    $0.mailboxAccountID == accountID &&
                    $0.senderAddress == policy.normalizedSenderAddress
                })
            }

            let processedJob: ExecutionJobRecord
            if let conversationIndex = matchingConversationIndex {
                processedJob = try handleConversationReply(
                    account: account,
                    password: password,
                    policy: policy,
                    message: message,
                    parsedCommand: parsedCommand,
                    conversationIndex: conversationIndex,
                    runtimeState: &runtimeState,
                    bridge: bridge
                )
            } else if policy.requiresReplyToken {
                processedJob = try issueReplyTokenChallenge(
                    account: account,
                    password: password,
                    policy: policy,
                    message: message,
                    parsedCommand: parsedCommand,
                    runtimeState: &runtimeState
                )
            } else {
                processedJob = try handleFreshRequest(
                    account: account,
                    password: password,
                    policy: policy,
                    message: message,
                    parsedCommand: parsedCommand,
                    runtimeState: &runtimeState,
                    bridge: bridge
                )
            }

            processedJobs.append(processedJob)
        }

        try stateStore.save(runtimeState)

        let statusMessage: String?
        if !processedJobs.isEmpty {
            statusMessage = LT(
                "Processed \(processedJobs.count) email task(s) for \(account.emailAddress).",
                "已为 \(account.emailAddress) 处理 \(processedJobs.count) 封邮件任务。",
                "\(account.emailAddress) のメールタスク \(processedJobs.count) 件を処理した。"
            )
        } else if ignoredCount > 0 {
            statusMessage = LT(
                "Ignored \(ignoredCount) message(s) for \(account.emailAddress) because they were not on the allowlist or were self-sent.",
                "已忽略 \(ignoredCount) 封 \(account.emailAddress) 的邮件，因为它们不在白名单中或是系统自己发出的。",
                "許可リスト外または自己送信だったため、\(account.emailAddress) のメッセージ \(ignoredCount) 件を無視した。"
            )
        } else {
            statusMessage = nil
        }

        return MailroomSyncOutcome(
            processedJobs: processedJobs,
            ignoredCount: ignoredCount,
            needsReload: !processedJobs.isEmpty,
            statusMessage: statusMessage
        )
    }

    private func handleFreshRequest(
        account: MailboxAccount,
        password: String,
        policy: SenderPolicy,
        message: InboundMailMessage,
        parsedCommand: MailroomParsedCommand,
        runtimeState: inout MailroomRuntimeState,
        bridge: CodexBridge
    ) throws -> ExecutionJobRecord {
        let token = makeThreadToken()
        let preview = MailPolicyRequestPreview(
            senderAddress: policy.normalizedSenderAddress,
            capability: parsedCommand.capability,
            workspaceRoot: parsedCommand.workspaceRoot,
            replyTokenPresent: false,
            actionSummary: parsedCommand.actionSummary
        )
        let decision = policyEngine.evaluate(request: preview, senderPolicies: [policy])

        let request = CodexMailRequest(
            id: UUID().uuidString,
            mailboxAccountID: account.id,
            senderAddress: policy.normalizedSenderAddress,
            subject: parsedCommand.cleanedSubject,
            capability: parsedCommand.capability,
            workspaceRoot: parsedCommand.workspaceRoot,
            actionSummary: parsedCommand.actionSummary,
            promptBody: parsedCommand.promptBody,
            replyToken: token,
            receivedAt: message.receivedAt
        )

        let job = try bridge.handle(
            request: request,
            decision: decision,
            fallbackRole: policy.assignedRole,
            assumeReviewApproved: false
        )

        return try finalizeProcessedJob(
            initialJob: job,
            account: account,
            password: password,
            threadToken: token,
            originalMessage: message,
            originalRequestBody: parsedCommand.promptBody,
            runtimeState: &runtimeState,
            existingConversationIndex: nil
        )
    }

    private func handleConversationReply(
        account: MailboxAccount,
        password: String,
        policy: SenderPolicy,
        message: InboundMailMessage,
        parsedCommand: MailroomParsedCommand,
        conversationIndex: Int,
        runtimeState: inout MailroomRuntimeState,
        bridge: CodexBridge
    ) throws -> ExecutionJobRecord {
        let conversation = runtimeState.conversations[conversationIndex]
        let continuationBody = buildContinuationPrompt(
            conversation: conversation,
            latestUserReply: parsedCommand.promptBody,
            subject: parsedCommand.cleanedSubject
        )

        let preview = MailPolicyRequestPreview(
            senderAddress: policy.normalizedSenderAddress,
            capability: conversation.capability,
            workspaceRoot: conversation.workspaceRoot,
            replyTokenPresent: true,
            actionSummary: parsedCommand.actionSummary
        )
        let decision = policyEngine.evaluate(request: preview, senderPolicies: [policy])

        let request = CodexMailRequest(
            id: UUID().uuidString,
            mailboxAccountID: account.id,
            senderAddress: policy.normalizedSenderAddress,
            subject: conversation.subject,
            capability: conversation.capability,
            workspaceRoot: conversation.workspaceRoot,
            actionSummary: parsedCommand.actionSummary,
            promptBody: continuationBody,
            replyToken: conversation.id,
            receivedAt: message.receivedAt
        )

        let job = try bridge.handle(
            request: request,
            decision: decision,
            fallbackRole: policy.assignedRole,
            assumeReviewApproved: false
        )

        return try finalizeProcessedJob(
            initialJob: job,
            account: account,
            password: password,
            threadToken: conversation.id,
            originalMessage: message,
            originalRequestBody: conversation.originalRequestBody,
            runtimeState: &runtimeState,
            existingConversationIndex: conversationIndex
        )
    }

    private func issueReplyTokenChallenge(
        account: MailboxAccount,
        password: String,
        policy: SenderPolicy,
        message: InboundMailMessage,
        parsedCommand: MailroomParsedCommand,
        runtimeState: inout MailroomRuntimeState
    ) throws -> ExecutionJobRecord {
        let token = makeThreadToken()
        let timestamp = Date()
        let subject = parsedCommand.cleanedSubject.isEmpty ? LT("Patch Courier reply token", "Patch Courier 回复 token", "Patch Courier 返信トークン") : parsedCommand.cleanedSubject
        let challengeMessage = composeChallengeMessage(
            threadToken: token,
            senderAddress: policy.senderAddress,
            originalRequestBody: parsedCommand.promptBody
        )
        let replyBody = challengeMessage.plainBody

        var job = ExecutionJobRecord(
            id: UUID().uuidString,
            accountID: account.id,
            senderAddress: policy.normalizedSenderAddress,
            requestedRole: policy.assignedRole,
            capability: parsedCommand.capability,
            approvalRequirement: .denied,
            action: parsedCommand.actionSummary,
            subject: subject,
            status: .waiting,
            workspaceRoot: parsedCommand.workspaceRoot,
            summary: LT(
                "Waiting for the sender to reply with the issued mailroom token.",
                "等待发件人携带刚刚发出的 mailroom token 进行回复。",
                "発行済みの mailroom トークンを付けた返信を送信者が返すのを待っている。"
            ),
            promptBody: parsedCommand.promptBody,
            replyBody: replyBody,
            errorDetails: nil,
            codexCommand: nil,
            exitCode: nil,
            receivedAt: message.receivedAt,
            startedAt: nil,
            completedAt: timestamp,
            updatedAt: timestamp
        )

        let outboundMessage = OutboundMailMessage(
            to: [policy.senderAddress],
            subject: composeOutboundSubject(baseSubject: subject, threadToken: token, state: challengeMessage.subjectState),
            plainBody: challengeMessage.plainBody,
            htmlBody: challengeMessage.htmlBody,
            inReplyTo: message.messageID,
            references: composeReferences(from: message.references, inReplyTo: message.inReplyTo, originalMessageID: message.messageID)
        )

        do {
            let sendResult = try transportClient.sendMessage(account: account, password: password, message: outboundMessage)
            let record = MailConversationRecord(
                id: token,
                mailboxAccountID: account.id,
                senderAddress: policy.normalizedSenderAddress,
                subject: subject,
                workspaceRoot: parsedCommand.workspaceRoot,
                capability: parsedCommand.capability,
                latestJobID: job.id,
                originalRequestBody: parsedCommand.promptBody,
                latestAssistantSummary: job.summary,
                latestAssistantBody: replyBody,
                latestQuestionBody: replyBody,
                lastInboundMessageID: message.messageID,
                lastOutboundMessageID: sendResult.messageID,
                status: .waitingForToken,
                createdAt: timestamp,
                updatedAt: timestamp
            )
            upsertConversation(record, in: &runtimeState)
        } catch {
            job.status = .failed
            job.summary = LT(
                "Reply token challenge could not be sent by email.",
                "无法通过邮件发出 reply token 挑战。",
                "返信トークン案内をメール送信できなかった。"
            )
            job.errorDetails = error.localizedDescription
        }

        try jobStore.insert(job)
        return job
    }

    private func finalizeProcessedJob(
        initialJob: ExecutionJobRecord,
        account: MailboxAccount,
        password: String,
        threadToken: String,
        originalMessage: InboundMailMessage,
        originalRequestBody: String,
        runtimeState: inout MailroomRuntimeState,
        existingConversationIndex: Int?
    ) throws -> ExecutionJobRecord {
        let agentResponse = responseForJob(initialJob)
        let conversationStatus = conversationStatus(for: initialJob)
        let renderedReply = composeRenderedReplyMessage(
            job: initialJob,
            threadToken: threadToken,
            agentResponse: agentResponse,
            status: conversationStatus
        )
        let replyBody = renderedReply.plainBody

        var finalJob = initialJob
        var finalConversationStatus = conversationStatus
        finalJob.replyBody = replyBody
        try jobStore.insert(finalJob)

        let outboundMessage = OutboundMailMessage(
            to: [initialJob.senderAddress],
            subject: composeOutboundSubject(
                baseSubject: agentResponse.subject.nilIfBlank ?? finalJob.subject,
                threadToken: threadToken,
                state: renderedReply.subjectState
            ),
            plainBody: replyBody,
            htmlBody: renderedReply.htmlBody,
            inReplyTo: originalMessage.messageID,
            references: composeReferences(from: originalMessage.references, inReplyTo: originalMessage.inReplyTo, originalMessageID: originalMessage.messageID)
        )

        var outboundMessageID: String?
        do {
            outboundMessageID = try transportClient.sendMessage(account: account, password: password, message: outboundMessage).messageID
        } catch {
            finalJob.status = .failed
            finalConversationStatus = .completed
            finalJob.summary = LT(
                "The mail reply could not be delivered after local processing finished.",
                "本地处理已经结束，但回复邮件发送失败。",
                "ローカル処理は完了したが、返信メールを配信できなかった。"
            )
            finalJob.errorDetails = [finalJob.errorDetails, error.localizedDescription]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            try jobStore.insert(finalJob)
        }

        let timestamp = Date()
        let record = MailConversationRecord(
            id: threadToken,
            mailboxAccountID: account.id,
            senderAddress: finalJob.senderAddress,
            subject: finalJob.subject,
            workspaceRoot: finalJob.workspaceRoot,
            capability: finalJob.capability,
            latestJobID: finalJob.id,
            originalRequestBody: originalRequestBody,
            latestAssistantSummary: finalJob.summary,
            latestAssistantBody: replyBody,
            latestQuestionBody: finalConversationStatus == .waitingForUser ? replyBody : nil,
            lastInboundMessageID: originalMessage.messageID,
            lastOutboundMessageID: outboundMessageID,
            status: finalConversationStatus,
            createdAt: existingConversationIndex.flatMap { runtimeState.conversations[safe: $0]?.createdAt } ?? timestamp,
            updatedAt: timestamp
        )
        upsertConversation(record, in: &runtimeState)

        return finalJob
    }

    private func responseForJob(_ job: ExecutionJobRecord) -> MailroomAgentResponse {
        if let responseKind = job.codexCommand, !responseKind.isEmpty {
            // placeholder to keep job.codexCommand visible in the detail pane; parsing happens from reply body when available
            _ = responseKind
        }

        switch job.status {
        case .waiting where job.codexCommand != nil:
            return MailroomAgentResponse(
                kind: .needInput,
                subject: job.subject,
                summary: job.summary,
                body: job.replyBody ?? job.errorDetails ?? job.summary,
                rawText: job.replyBody ?? job.errorDetails ?? job.summary
            )
        case .rejected, .failed, .waiting:
            return MailroomAgentResponse(
                kind: .final,
                subject: job.subject,
                summary: job.summary,
                body: [job.summary, job.errorDetails].compactMap { $0?.nilIfBlank }.joined(separator: "\n\n"),
                rawText: [job.summary, job.errorDetails].compactMap { $0?.nilIfBlank }.joined(separator: "\n\n")
            )
        default:
            return MailroomAgentResponse(
                kind: .final,
                subject: job.subject,
                summary: job.summary,
                body: job.replyBody ?? job.summary,
                rawText: job.replyBody ?? job.summary
            )
        }
    }

    private func conversationStatus(for job: ExecutionJobRecord) -> MailConversationStatus {
        switch job.status {
        case .waiting where job.codexCommand != nil:
            return .waitingForUser
        case .waiting:
            return .queuedReview
        case .rejected:
            return .rejected
        case .received, .accepted, .running, .succeeded, .failed:
            return .completed
        }
    }

    private func composeRuntimePlainBody(
        statusLabel: String,
        title: String,
        summary: String,
        fields: [MailroomRuntimeEnvelopeField],
        sections: [MailroomRuntimeEnvelopeSection],
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

    private func composeRenderedReplyMessage(
        job: ExecutionJobRecord,
        threadToken: String,
        agentResponse: MailroomAgentResponse,
        status: MailConversationStatus
    ) -> MailroomRuntimeRenderedMessage {
        let subjectState = runtimeSubjectState(for: job, status: status)
        let mainBody = agentResponse.body.nilIfBlank ?? agentResponse.summary.nilIfBlank ?? job.summary
        let isStructuredNeedInput = status == .waitingForUser && runtimeLooksLikeStructuredReply(mainBody)
        let fields: [MailroomRuntimeEnvelopeField] = [
            MailroomRuntimeEnvelopeField(label: LT("Thread", "线程", "スレッド"), value: "[patch-courier:\(threadToken)]", monospace: true),
            MailroomRuntimeEnvelopeField(label: LT("Job", "任务", "ジョブ"), value: job.id, monospace: true),
            MailroomRuntimeEnvelopeField(label: LT("Status", "状态", "ステータス"), value: job.status.title),
            MailroomRuntimeEnvelopeField(label: LT("Workspace", "工作区", "ワークスペース"), value: job.workspaceRoot, monospace: true),
            MailroomRuntimeEnvelopeField(label: LT("Sender", "发件人", "送信者"), value: job.senderAddress, monospace: true)
        ]

        let title: String
        let summary: String
        let sectionTitle: String
        let nextSteps: [String]
        let footer: String?
        let previewText: String

        switch subjectState {
        case .actionNeeded:
            if status == .waitingForUser, isStructuredNeedInput {
                title = LT("More info needed to continue", "还需要补充信息才能继续", "続行には追加情報が必要です")
                summary = LT(
                    "Mailroom paused this task and needs a structured reply using the template below.",
                    "Mailroom 已暂停当前任务，需要你按下面的模板结构化回复后才能继续。",
                    "Mailroom はこのタスクを一時停止しており、続行には下のテンプレートでの構造化返信が必要です。"
                )
                sectionTitle = LT("Reply format", "回复格式", "返信フォーマット")
                nextSteps = [
                    LT("Fill in the requested fields in the template below.", "把下面模板里要求填写的字段补齐。", "下のテンプレートで求められている項目を埋めてください。"),
                    LT("Keep the THREAD line unchanged so Mailroom can match the reply correctly.", "请保留 THREAD 行不变，这样 Mailroom 才能正确匹配这封回复。", "THREAD 行をそのまま残すと、Mailroom が返信を正しく照合できます。"),
                    LT("Send the reply in this same thread, and Mailroom will resume the same Codex task here.", "直接在这个线程里发回去，Mailroom 就会继续同一个 Codex 任务。", "この同じスレッドで返信すると、Mailroom が同じ Codex タスクをここで再開します。")
                ]
                footer = LT(
                    "If your mail app strips the template, paste the THREAD line and the requested fields back into your reply before sending.",
                    "如果邮箱客户端把模板内容删掉了，请在发送前把 THREAD 行和需要填写的字段重新贴回回复里。",
                    "メールアプリがテンプレートを削る場合は、送信前に THREAD 行と必要項目を返信へ貼り戻してください。"
                )
                previewText = LT(
                    "Fill in the requested fields in the reply template below so Mailroom can resume this paused task.",
                    "请填好下面模板里要求的字段，这样 Mailroom 才能恢复当前暂停的任务。",
                    "下の返信テンプレートに必要項目を入れると、Mailroom がこの一時停止中タスクを再開できます。"
                )
            } else {
                title = LT("More info needed to continue", "还需要补充信息才能继续", "続行には追加情報が必要です")
                summary = LT(
                    "Mailroom paused this task and is waiting for one more reply with the missing information below.",
                    "Mailroom 已暂停当前任务，正在等待你补充下面缺少的信息后再继续。",
                    "Mailroom はこのタスクを一時停止しており、以下の不足情報を含む返信を待っています。"
                )
                sectionTitle = LT("What we need from you", "需要你回复的内容", "返信してほしい内容")
                nextSteps = [
                    LT("Reply in this same thread with the missing information described below.", "请直接在这个线程里回复下面缺少的信息。", "この同じスレッドに、以下で求められている不足情報を返信してください。"),
                    LT("Keep the THREAD line unchanged so Mailroom can match the reply correctly.", "请保留 THREAD 行不变，这样 Mailroom 才能正确匹配这封回复。", "THREAD 行をそのまま残すと、Mailroom が返信を正しく照合できます。"),
                    LT("After your reply arrives, Mailroom will resume the same Codex task and send the next update here.", "你的回复到达后，Mailroom 会恢复同一个 Codex 任务，并继续在这里发回下一条更新。", "返信が届くと、Mailroom は同じ Codex タスクを再開し、次の更新をここへ返します。")
                ]
                footer = LT(
                    "If your mail app trims quoted text, paste the THREAD line back into your reply before sending.",
                    "如果邮箱客户端删掉了引用内容，请在发送前把 THREAD 行重新贴回回复里。",
                    "メールアプリが引用部分を削る場合は、送信前に THREAD 行を返信へ貼り戻してください。"
                )
                previewText = LT(
                    "Reply with the missing information below and Mailroom will continue this paused task in the same thread.",
                    "请回复下面缺少的信息，Mailroom 就会在同一个线程里继续这个暂停中的任务。",
                    "以下の不足情報を返信すると、Mailroom が同じスレッドでこの一時停止中タスクを続行します。"
                )
            }
        case .received:
            title = LT("Request received and queued locally", "已收到请求，正在本地排队", "要求を受信し、ローカルでキュー待ちにしました")
            summary = LT(
                "Mailroom saved this request in the local review queue. It has not run yet.",
                "Mailroom 已把这条请求放进本地审核队列，但还没有开始执行。",
                "Mailroom はこの要求をローカルレビューキューへ保存しましたが、まだ実行していません。"
            )
            sectionTitle = LT("Current status", "当前状态", "現在の状態")
            nextSteps = [
                LT("Mailroom keeps this request in the local queue until it is reviewed.", "Mailroom 会先把这条请求保留在本地队列里，等待审核。", "Mailroom はこの要求をレビューされるまでローカルキューに保持します。"),
                LT("If you need to add context, reply in this same thread and keep the THREAD line.", "如果你要补充上下文，继续在这个线程里回复，并保留 THREAD 行即可。", "補足が必要なら、この同じスレッドに返信し、THREAD 行を残してください。")
            ]
            footer = LT(
                "If you want to add context later, reply in this thread and keep the thread token.",
                "如果你之后想补充上下文，继续在这个线程里回复并保留 thread token 即可。",
                "後から文脈を補足したい場合は、このスレッドに返信して thread token を残してください。"
            )
            previewText = LT(
                "Queued locally for review. Reply in this thread if you want to add more context before it runs.",
                "请求已进入本地审核队列。若想在运行前补充上下文，直接在这个线程里回复即可。",
                "ローカルレビュー待ちに入りました。実行前に補足したい場合は、このスレッドで返信してください。"
            )
        case .completed:
            title = LT("Your Mailroom task is done", "你的 Mailroom 任务已完成", "Mailroom のタスクが完了しました")
            summary = LT(
                "Mailroom finished the requested Codex work. The latest result is below.",
                "Mailroom 已完成你请求的 Codex 工作，最新结果见下方。",
                "Mailroom は依頼された Codex 作業を完了しました。最新結果は以下です。"
            )
            sectionTitle = LT("Result", "结果", "結果")
            nextSteps = [
                LT("Review the result below.", "先查看下面的结果。", "まず以下の結果を確認してください。"),
                LT("Reply in this same thread if you want Mailroom to continue with a follow-up request.", "如果你想继续追加后续需求，直接在这个线程里回复即可。", "続きの依頼があれば、この同じスレッドに返信してください。")
            ]
            footer = LT(
                "Reply to this email and keep the thread token if you want Mailroom to continue the same task.",
                "如果你想让 Mailroom 继续同一个任务，请直接回复这封邮件并保留 thread token。",
                "Mailroom に同じタスクを続けさせたい場合は、このメールに返信し thread token を残してください。"
            )
            previewText = LT(
                "Task finished. Open this email for the result, then reply here if you want a follow-up.",
                "任务已完成。打开这封邮件查看结果；如果还要继续，直接在这里回复即可。",
                "タスクが完了しました。結果はこのメールを開いて確認し、続きがあればこのスレッドへ返信してください。"
            )
        case .failed:
            title = LT("Mailroom couldn't finish this task", "Mailroom 暂时没能完成这个任务", "Mailroom はこのタスクを完了できませんでした")
            summary = LT(
                "This task did not complete successfully. See the details below.",
                "这次任务没有顺利完成，详情见下方。",
                "このタスクは正常完了しませんでした。詳細は以下です。"
            )
            sectionTitle = LT("Details", "详情", "詳細")
            nextSteps = [
                LT("Review the details below to see what blocked the task.", "先查看下面的详情，确认是什么阻塞了任务。", "まず以下の詳細を見て、何がタスクを止めたか確認してください。"),
                LT("Reply in this same thread if you want to clarify the request or try again.", "如果你想补充说明或重试，直接在这个线程里回复。", "依頼を補足したり再試行したい場合は、この同じスレッドに返信してください。")
            ]
            footer = LT(
                "Reply in this thread if you want to clarify the request or try again.",
                "如果你想补充说明或重试，可以直接在这个线程里回复。",
                "依頼を補足したり再試行したい場合は、このスレッドに返信してください。"
            )
            previewText = LT(
                "Task stopped before completion. Open the details, then reply here if you want to retry or clarify the request.",
                "任务未能完成。打开邮件查看详情；如果你想重试或补充说明，直接在这里回复即可。",
                "タスクは完了前に停止しました。詳細はメールを開いて確認し、再試行や補足があればこのスレッドへ返信してください。"
            )
        case .rejected:
            title = LT("Mailroom rejected this task", "Mailroom 已拒绝这个任务", "Mailroom はこのタスクを拒否しました")
            summary = LT(
                "Mailroom could not accept or continue this request.",
                "Mailroom 无法接受或继续处理这条请求。",
                "Mailroom はこの要求を受け付けることも継続することもできませんでした。"
            )
            sectionTitle = LT("Details", "详情", "詳細")
            nextSteps = [
                LT("Review the explanation below.", "先看下面的说明。", "まず以下の説明を確認してください。"),
                LT("Reply in this same thread with a corrected request if you want to try again.", "如果你想重试，请在这个线程里回复修正后的请求。", "やり直したい場合は、この同じスレッドに修正した依頼を返信してください。")
            ]
            footer = LT(
                "Reply in this thread with a corrected request if you want to try again.",
                "如果你想重试，请在这个线程里回复修正后的请求。",
                "やり直したい場合は、このスレッドに修正した依頼を返信してください。"
            )
            previewText = LT(
                "This request could not be accepted. Open the explanation, then reply here with a corrected request if needed.",
                "这条请求无法被接受。打开邮件查看说明；如果需要，可以直接在这里回复修正后的请求。",
                "この依頼は受け付けられませんでした。説明はメールを開いて確認し、必要なら修正した依頼をこのスレッドへ返信してください。"
            )
        }

        let sections = mainBody.nilIfBlank.map {
            [MailroomRuntimeEnvelopeSection(title: sectionTitle, body: $0, monospace: isStructuredNeedInput)]
        } ?? []
        let plainBody = composeRuntimePlainBody(
            statusLabel: subjectState.statusLabel,
            title: title,
            summary: summary,
            fields: fields,
            sections: sections,
            nextSteps: nextSteps,
            footer: footer
        )

        return MailroomRuntimeRenderedMessage(
            subjectState: subjectState,
            plainBody: plainBody,
            htmlBody: composeRuntimeHTMLBody(
                state: subjectState,
                title: title,
                summary: summary,
                fields: fields,
                sections: sections,
                nextSteps: nextSteps,
                footer: footer,
                preheader: MailroomRuntimeEmailHTML.preheader(previewText)
            )
        )
    }

    private func composeChallengeMessage(
        threadToken: String,
        senderAddress: String,
        originalRequestBody: String
    ) -> MailroomRuntimeRenderedMessage {
        let originalRequest = originalRequestBody
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
            ?? LT("(No request body was captured.)", "（没有捕获到正文请求。）", "（依頼本文は取得できなかった。）")
        let title = LT(
            "Message received - reply once to confirm",
            "已经收到，请回复一次确认",
            "受信済みです。1 回返信して確認してください"
        )
        let summary = LT(
            "Mailroom received this request. One reply from the same sender with the thread token below will confirm the thread and unlock the next step.",
            "Mailroom 已经收到这条请求。只要同一位发件人带着下面的 thread token 回复一次，这个线程就完成确认，后续就能继续处理。",
            "Mailroom はこの依頼を受信しました。同じ送信者から下の thread token を付けて 1 回返信すれば、このスレッドの確認が完了し、次の処理へ進めます。"
        )
        let replyTemplate = """
        THREAD: [patch-courier:\(threadToken)]

        \(LT("Any short reply is fine.", "写一句简短回复即可。", "短い返信なら何でも構いません。"))
        """
        let fields = [
            MailroomRuntimeEnvelopeField(label: LT("Thread", "线程", "スレッド"), value: "[patch-courier:\(threadToken)]", monospace: true),
            MailroomRuntimeEnvelopeField(label: LT("Sender", "发件人", "送信者"), value: senderAddress, monospace: true)
        ]
        let plainSections = [
            MailroomRuntimeEnvelopeSection(
                title: LT("Original request", "原始请求", "元の依頼"),
                body: originalRequest,
                monospace: false
            ),
            MailroomRuntimeEnvelopeSection(
                title: LT("Reply once in this thread", "在这个线程里回复一次", "このスレッドで 1 回返信"),
                body: replyTemplate,
                monospace: true
            )
        ]
        let htmlSections = [
            MailroomRuntimeEnvelopeSection(
                title: LT("Original request", "原始请求", "元の依頼"),
                body: originalRequest,
                monospace: false
            )
        ]
        let nextSteps = [
            LT("Reply once in this same thread from the same sender address.", "请用同一个发件地址，在这个线程里回复一次。", "同じ送信者アドレスで、このスレッドに 1 回返信してください。"),
            LT("Keep the THREAD line unchanged; a short acknowledgment is enough.", "请保留 THREAD 行不变；哪怕只回一句简短确认也可以。", "THREAD 行はそのまま残してください。短い確認返信で十分です。"),
            LT("After that confirmation arrives, Mailroom will trust the next step from this sender in the same thread.", "这封确认回复到达后，Mailroom 就会信任同一发件人在这个线程里的后续请求。", "この確認返信が届くと、Mailroom は同じ送信者からこのスレッドで届く次の依頼を信頼します。")
        ]
        let footer = LT(
            "If your mail app removes quoted text, copy the reply block back into your message before sending.",
            "如果邮箱客户端删掉了引用内容，请在发送前把上面的回复块重新贴回邮件里。",
            "メールアプリが引用部分を削る場合は、送信前に上の返信ブロックをメールへ貼り戻してください。"
        )
        let previewText = LT(
            "Mailroom received this request. Reply once with the thread token below to confirm the sender and unlock the next step.",
            "Mailroom 已经收到这条请求。请带着下面的 thread token 回复一次，确认发件人后就能进入下一步。",
            "Mailroom はこの依頼を受信しました。下の thread token を付けて 1 回返信すると、送信者確認が完了し、次の処理へ進めます。"
        )
        let extraSectionsHTML = [
            runtimeMailSectionHTML(
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
                          <td style="padding:12px 14px; color:#18212D; font:13px/1.75 ui-monospace, SFMono-Regular, Menlo, monospace; word-wrap:break-word; overflow-wrap:anywhere;">THREAD: [patch-courier:\(threadToken.htmlEscaped)]</td>
                        </tr>
                      </table>
                    </td>
                  </tr>
                </table>
                """
            ),
            runtimeMailSectionHTML(
                title: LT("Manual reply", "手动回复", "手動返信"),
                bodyHTML: """
                <p style="margin:0 0 12px; color:#475467; font-size:15px; line-height:1.78;">\(LT("If your mail app removes quoted text, copy this block into your reply before sending.", "如果邮箱客户端会删掉引用内容，请把这段内容复制到你的回复里再发送。", "メールアプリが引用部分を削る場合は、このブロックを返信へコピーしてから送信してください。").htmlEscaped)</p>
                \(runtimeMailPreformattedHTML(replyTemplate))
                """
            )
        ]
        let plainBody = composeRuntimePlainBody(
            statusLabel: MailroomRuntimeSubjectState.actionNeeded.statusLabel,
            title: title,
            summary: summary,
            fields: fields,
            sections: plainSections,
            nextSteps: nextSteps,
            footer: footer
        )

        return MailroomRuntimeRenderedMessage(
            subjectState: .actionNeeded,
            plainBody: plainBody,
            htmlBody: composeRuntimeHTMLBody(
                state: .actionNeeded,
                title: title,
                summary: summary,
                fields: fields,
                sections: htmlSections,
                extraSectionsHTML: extraSectionsHTML,
                nextSteps: nextSteps,
                footer: footer,
                preheader: MailroomRuntimeEmailHTML.preheader(previewText)
            )
        )
    }

    private func runtimeLooksLikeStructuredReply(_ text: String) -> Bool {
        let candidatePrefixes = [
            "THREAD:",
            "REQUEST:",
            "DECISION:",
            "MODE:",
            "TASK:",
            "PROJECT:",
            "COMMAND:",
            "NOTE:",
            "ANSWER_"
        ]

        let matches = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { line in
                !line.isEmpty && candidatePrefixes.contains(where: { line.hasPrefix($0) })
            }

        return matches.count >= 2
    }

    private func runtimeSubjectState(
        for job: ExecutionJobRecord,
        status: MailConversationStatus
    ) -> MailroomRuntimeSubjectState {
        switch status {
        case .waitingForUser, .waitingForToken:
            return .actionNeeded
        case .queuedReview:
            return .received
        case .rejected:
            return .rejected
        case .completed:
            return job.status == .failed ? .failed : .completed
        }
    }

    private func composeRuntimeHTMLBody(
        state: MailroomRuntimeSubjectState,
        title: String,
        summary: String,
        fields: [MailroomRuntimeEnvelopeField],
        sections: [MailroomRuntimeEnvelopeSection],
        extraSectionsHTML: [String] = [],
        nextSteps: [String],
        footer: String?,
        preheader: String? = nil
    ) -> String {
        let tone = runtimeEnvelopeTone(for: state)
        let summaryHTML = summary.nilIfBlank.map(runtimeMailParagraphHTML) ?? ""
        let metadataHTML = runtimeMailMetadataHTML(fields)
        let sectionBlocks = sections
            .map { section in
                let body = section.body.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else {
                    return ""
                }
                let contentHTML = section.monospace
                    ? runtimeMailPreformattedHTML(body)
                    : runtimeMailParagraphHTML(body)
                return runtimeMailSectionHTML(title: section.title, bodyHTML: contentHTML)
            }
            .filter { !$0.isEmpty }
        let contentBlocks = [metadataHTML] + sectionBlocks + extraSectionsHTML
        let stackedBlocksHTML = runtimeMailStackedBlocksHTML(contentBlocks)
        let cleanedNextSteps = nextSteps
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let nextStepsHTML = cleanedNextSteps.isEmpty ? "" : runtimeMailSectionHTML(
            title: LT("Next", "接下来", "次の流れ"),
            bodyHTML: """
            <ol style="margin:0; padding:0 0 0 22px; color:#18212D; font-size:15px; line-height:1.75;">
              \(cleanedNextSteps.map { "<li style=\"margin:0 0 8px;\">\(runtimeMailInlineHTML($0))</li>" }.joined())
            </ol>
            """
        )
        let footerHTML = footer?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank.map {
            runtimeMailFooterHTML(runtimeMailInlineHTML($0))
        } ?? ""

        return MailroomRuntimeEmailHTML.document(
            preheader: preheader ?? MailroomRuntimeEmailHTML.preheader(
                statusLabel: state.statusLabel,
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
                            \(state.statusLabel.htmlEscaped)
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
                      \(stackedBlocksHTML)
                      \(nextStepsHTML.isEmpty ? "" : runtimeMailBlockSpacingHTML + nextStepsHTML)
                      \(footerHTML.isEmpty ? "" : runtimeMailBlockSpacingHTML + footerHTML)
                    </td>
                  </tr>
                </table>
              </td>
            </tr>
          </table>
        """
        )
    }

    private func runtimeMailMetadataHTML(_ fields: [MailroomRuntimeEnvelopeField]) -> String {
        let rows = fields.compactMap { field -> String? in
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                return nil
            }
            let valueHTML: String
            if field.monospace || runtimeShouldUseMonospace(for: value) {
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

    private func runtimeMailParagraphHTML(_ text: String) -> String {
        let paragraphs = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !paragraphs.isEmpty else {
            return ""
        }

        return paragraphs.map { paragraph in
            let html = paragraph
                .components(separatedBy: "\n")
                .map { runtimeMailInlineHTML($0) }
                .joined(separator: "<br>")
            return "<p style=\"margin:0 0 12px; color:#18212D; font-size:15px; line-height:1.78;\">\(html)</p>"
        }.joined()
    }

    private func runtimeMailInlineHTML(_ text: String) -> String {
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

    private func runtimeMailPreformattedHTML(_ text: String) -> String {
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

    private func runtimeMailSectionHTML(title: String, bodyHTML: String) -> String {
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

    private func runtimeMailStackedBlocksHTML(_ blocks: [String]) -> String {
        let cleaned = blocks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else {
            return ""
        }
        return cleaned.enumerated().map { index, block in
            (index == 0 ? "" : runtimeMailBlockSpacingHTML) + block
        }.joined()
    }

    private func runtimeMailFooterHTML(_ bodyHTML: String) -> String {
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

    private func runtimeEnvelopeTone(for state: MailroomRuntimeSubjectState) -> MailroomRuntimeEnvelopeTone {
        switch state {
        case .received:
            return .info
        case .actionNeeded:
            return .warning
        case .completed:
            return .success
        case .failed, .rejected:
            return .danger
        }
    }

    private func runtimeShouldUseMonospace(for value: String) -> Bool {
        value.contains("/") || value.contains("@") || value.contains("[patch-courier:") || value.contains("MRM-")
    }

    private func composeOutboundSubject(
        baseSubject: String,
        threadToken: String,
        state: MailroomRuntimeSubjectState? = nil
    ) -> String {
        let normalizedSubject = MailroomMailParser.normalizeSubject(baseSubject)
        var decoratedSubject = normalizedSubject
        if let state {
            decoratedSubject = "[\(state.prefix)]" + (decoratedSubject.isEmpty ? "" : " " + decoratedSubject)
        }
        decoratedSubject = decoratedSubject.isEmpty
            ? "[patch-courier:\(threadToken)]"
            : decoratedSubject + " [patch-courier:\(threadToken)]"
        return decoratedSubject.lowercased().hasPrefix("re:") ? decoratedSubject : "Re: \(decoratedSubject)"
    }

    private func composeReferences(
        from existing: [String],
        inReplyTo: String?,
        originalMessageID: String
    ) -> [String] {
        var references = existing
        if let inReplyTo, !references.contains(inReplyTo) {
            references.append(inReplyTo)
        }
        if !references.contains(originalMessageID) {
            references.append(originalMessageID)
        }
        return references
    }

    private func buildContinuationPrompt(
        conversation: MailConversationRecord,
        latestUserReply: String,
        subject: String
    ) -> String {
        let userReply = latestUserReply.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Continue an existing Patch Courier email thread.

        Thread token: \(conversation.tokenLabel)
        Subject: \(subject.isEmpty ? conversation.subject : subject)
        Workspace: \(conversation.workspaceRoot)

        Original request:
        \(conversation.originalRequestBody)

        Previous mailroom reply:
        \(conversation.latestAssistantBody ?? LT("No previous assistant reply was recorded.", "没有记录到上一条助手回复。", "前回のアシスタント返信は記録されていない。"))

        Latest reply from the user:
        \(userReply.isEmpty ? LT("The user replied without extra body text. Use the thread context above.", "用户回复时没有补充正文，请结合上面的线程上下文继续。", "ユーザーは本文を補足せずに返信した。上のスレッド文脈を使って続行してください。") : userReply)
        """
    }

    private func makeThreadToken() -> String {
        "MRM-\(UUID().uuidString.prefix(8).uppercased())"
    }

    private func upsertSyncState(
        in runtimeState: inout MailroomRuntimeState,
        accountID: String,
        lastUID: UInt64?,
        processedAt: Date
    ) {
        let state = MailboxSyncState(accountID: accountID, lastSeenUID: lastUID, lastProcessedAt: processedAt)
        if let index = runtimeState.syncStates.firstIndex(where: { $0.accountID == accountID }) {
            runtimeState.syncStates[index] = state
        } else {
            runtimeState.syncStates.append(state)
        }
    }

    private func upsertConversation(_ record: MailConversationRecord, in runtimeState: inout MailroomRuntimeState) {
        if let index = runtimeState.conversations.firstIndex(where: { $0.id == record.id }) {
            runtimeState.conversations[index] = record
        } else {
            runtimeState.conversations.append(record)
        }
        runtimeState.conversations.sort { $0.updatedAt > $1.updatedAt }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
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
}
