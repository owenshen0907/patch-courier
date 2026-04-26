import Combine
import Foundation

@MainActor
final class MailroomWorkspaceModel: ObservableObject {
    @Published private(set) var accounts: [ConfiguredMailboxAccount] = []
    @Published private(set) var senderPolicies: [SenderPolicy] = []
    @Published private(set) var managedProjects: [ManagedProject] = []
    @Published private(set) var jobs: [ExecutionJobRecord] = []
    @Published private(set) var mailboxMessages: [MailroomMailboxMessageRecord] = []
    @Published private(set) var mailboxHistory: [InboundMailMessage] = []
    @Published private(set) var mailboxHistoryVisibleCount: Int = 0
    @Published private(set) var isLoadingMailboxHistory = false
    @Published private(set) var mailboxHistoryErrorMessage: String?
    @Published private(set) var mailboxHistoryLastLoadedAt: Date?
    @Published private(set) var daemonSnapshot: MailroomDaemonStateSnapshot?
    @Published private(set) var daemonConnectionState: MailroomDaemonConnectionState = .unknown
    @Published private(set) var daemonRuntimeStatus: MailroomDaemonRuntimeStatus = .placeholder
    @Published private(set) var resolvingApprovalIDs: Set<String> = []
    @Published private(set) var resolvingThreadDecisionTokens: Set<String> = []
    @Published private(set) var mutatingMailboxMessageIDs: Set<String> = []
    @Published private(set) var applicationSupportPath: String = ""
    @Published private(set) var accountsFilePath: String = ""
    @Published private(set) var policyFilePath: String = ""
    @Published private(set) var jobsDatabasePath: String = ""
    @Published private(set) var daemonDatabasePath: String = ""
    @Published private(set) var latestJobID: String?
    @Published private(set) var isRunningCodex = false
    @Published private(set) var isSavingAccount = false
    @Published private(set) var probeStates: [String: AccountProbeState] = [:]
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    private let secretStore: KeychainSecretStore
    private let policyEngine = MailPolicyEngine()
    private let notificationManager = MailroomNotificationManager()
    private var jobStore: SQLiteJobStore?
    private var daemonLocalStore: SQLiteMailroomLocalStore?
    private var transportClient: MailTransportClient?
    private var daemonSupervisor: MailroomDaemonSupervisor?
    private var hasLoaded = false
    private var daemonPollingTask: Task<Void, Never>?
    private var mailboxHistoryTask: Task<Void, Never>?
    private var mailboxHistoryAccountID: String?
    private var mailboxHistoryAnchorUID: UInt64?

    var roleProfiles: [RolePolicyProfile] {
        MailPolicyEngine.defaultProfiles
    }

    var identityAccount: ConfiguredMailboxAccount? {
        accounts.first
    }

    var latestJob: ExecutionJobRecord? {
        guard let latestJobID else {
            return jobs.first
        }
        return jobs.first(where: { $0.id == latestJobID }) ?? jobs.first
    }

    var canRunCodexLocally: Bool {
        CodexBridge.isLocalExecutionSupported
    }

    var pendingApprovals: [MailroomDaemonApprovalSummary] {
        (daemonSnapshot?.approvals ?? []).filter { $0.status == "pending" }
    }

    var daemonThreads: [MailroomDaemonThreadSummary] {
        daemonSnapshot?.threads ?? []
    }

    var daemonTurns: [MailroomDaemonTurnSummary] {
        daemonSnapshot?.turns ?? []
    }

    var daemonSyncCursors: [MailroomDaemonSyncCursorSummary] {
        daemonSnapshot?.syncCursors ?? []
    }

    var daemonMailboxHealth: [MailroomDaemonMailboxHealthSummary] {
        daemonSnapshot?.mailboxHealth ?? []
    }

    var daemonMailboxPollIncidents: [MailroomMailboxPollIncidentRecord] {
        daemonSnapshot?.mailboxPollIncidents ?? []
    }

    var daemonWorkers: [MailroomDaemonWorkerSummary] {
        daemonSnapshot?.workers ?? []
    }

    var daemonRecentMailActivity: [MailroomDaemonRecentMessageSummary] {
        daemonSnapshot?.recentMailActivity ?? []
    }

    var canStartDaemon: Bool {
        !daemonRuntimeStatus.isTransitioning
    }

    var isDaemonConnected: Bool {
        if case .connected = daemonConnectionState {
            return true
        }
        return false
    }

    init(secretStore: KeychainSecretStore = KeychainSecretStore()) {
        self.secretStore = secretStore
        bootstrapStores()
        Task { [weak self] in
            guard let self else {
                return
            }
            self.loadIfNeeded()
            await self.ensureBackgroundDaemonRunning()
            await self.refreshDaemonState()
        }
    }

    deinit {
        daemonPollingTask?.cancel()
        mailboxHistoryTask?.cancel()
    }

    func loadIfNeeded() {
        guard !hasLoaded else {
            return
        }
        reload()
    }

    func reload() {
        guard let jobStore else {
            return
        }

        do {
            jobs = try jobStore.loadRecentJobs(limit: 24)
            if latestJobID == nil {
                latestJobID = jobs.first?.id
            }
            if errorMessage == nil {
                if let identityAccount {
                    statusMessage = LT(
                        "Loaded daemon-backed relay mailbox \(identityAccount.account.emailAddress), \(senderPolicies.count) sender policies, and \(jobs.count) queued jobs.",
                        "已加载 daemon 托管的信使邮箱 \(identityAccount.account.emailAddress)、\(senderPolicies.count) 条发件人策略，以及 \(jobs.count) 个队列任务。",
                        "daemon 管理の中継メール \(identityAccount.account.emailAddress)、\(senderPolicies.count) 件の送信者ポリシー、\(jobs.count) 件のキュージョブを読み込んだ。"
                    )
                } else {
                    statusMessage = LT(
                        "No daemon-backed relay mailbox is visible yet. \(senderPolicies.count) sender policies and \(jobs.count) queued jobs are ready.",
                        "目前还没有可见的 daemon 托管信使邮箱。已准备好 \(senderPolicies.count) 条发件人策略和 \(jobs.count) 个队列任务。",
                        "表示できる daemon 管理の中継メールはまだない。\(senderPolicies.count) 件の送信者ポリシーと \(jobs.count) 件のキュージョブは利用可能。"
                    )
                }
            }
            hasLoaded = true
            loadOfflineDaemonDataIfNeeded()
            startDaemonMonitoringIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func saveAccount(
        draft: MailboxAccountDraft,
        password: String,
        existingAccount: ConfiguredMailboxAccount? = nil
    ) async -> Bool {
        guard let transportClient else {
            errorMessage = LT("Mail transport is not ready yet.", "邮件传输尚未就绪。", "メール転送の準備がまだできていない。")
            return false
        }
        guard !isSavingAccount else {
            return false
        }
        let currentIdentity = identityAccount
        if let currentIdentity {
            if let existingAccount {
                guard currentIdentity.id == existingAccount.id else {
                    statusMessage = nil
                    errorMessage = identityLockedMessage(for: currentIdentity.account)
                    return false
                }
            } else {
                statusMessage = nil
                errorMessage = identityLockedMessage(for: currentIdentity.account)
                return false
            }
        } else if existingAccount != nil {
            statusMessage = nil
            errorMessage = LT(
                "The current relay mailbox could not be reloaded. Close the sheet and try again.",
                "当前信使邮箱无法重新加载。请关闭弹窗后重试。",
                "現在の中継メールを再読み込みできません。シートを閉じて再試行してください。"
            )
            return false
        }

        do {
            let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
            let account = try draft.buildAccount(existingAccount: existingAccount?.account)

            let passwordForProbe: String
            let passwordForSave: String?
            if trimmedPassword.isEmpty {
                if let existingAccount,
                   let storedPassword = try secretStore.password(for: existingAccount.id)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !storedPassword.isEmpty {
                    passwordForProbe = storedPassword
                    passwordForSave = nil
                } else {
                    throw MailroomValidationError.emptyPassword
                }
            } else {
                passwordForProbe = trimmedPassword
                passwordForSave = trimmedPassword
            }

            isSavingAccount = true
            errorMessage = nil
            statusMessage = LT(
                "Testing \(account.emailAddress) before saving...",
                "正在测试 \(account.emailAddress)，通过后才会保存…",
                "\(account.emailAddress) を保存前に接続テスト中…"
            )

            let summary = try await runProbe(
                account: account,
                password: passwordForProbe,
                transportClient: transportClient
            )
            probeStates[account.id] = .finished(summary)
            guard summary.succeeded else {
                isSavingAccount = false
                statusMessage = nil
                errorMessage = saveBlockedMessage(for: account, summary: summary)
                return false
            }

            let client = try await makeDaemonClient(autoStartIfNeeded: true)
            let snapshot = try await client.upsertMailboxAccount(account, password: passwordForSave)
            applyDaemonState(controlFile: client.controlFile, snapshot: snapshot)
            isSavingAccount = false
            errorMessage = nil
            if existingAccount == nil {
                statusMessage = LT(
                    "Connectivity test passed and daemon-backed relay mailbox \(account.emailAddress) was saved.",
                    "信使邮箱 \(account.emailAddress) 连通性测试通过，已保存到 daemon 配置中。",
                    "メールボックス \(account.emailAddress) の接続テストに成功し、daemon 管理の中継メールとして保存した。"
                )
            } else {
                statusMessage = LT(
                    "Connectivity test passed and daemon-backed relay mailbox \(account.emailAddress) was updated.",
                    "信使邮箱 \(account.emailAddress) 连通性测试通过，daemon 配置已更新。",
                    "メールボックス \(account.emailAddress) の接続テストに成功し、daemon 管理の中継メールを更新した。"
                )
            }
            return true
        } catch {
            isSavingAccount = false
            statusMessage = nil
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteAccount(_ configuredAccount: ConfiguredMailboxAccount) async {
        do {
            probeStates.removeValue(forKey: configuredAccount.id)
            let client = try await makeDaemonClient(autoStartIfNeeded: true)
            let snapshot = try await client.deleteMailboxAccount(accountID: configuredAccount.account.id)
            applyDaemonState(controlFile: client.controlFile, snapshot: snapshot)
            errorMessage = nil
            statusMessage = LT(
                "Removed daemon-backed relay mailbox \(configuredAccount.account.emailAddress).",
                "已删除 daemon 托管的信使邮箱 \(configuredAccount.account.emailAddress)。",
                "daemon 管理の中継メール \(configuredAccount.account.emailAddress) を削除した。"
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func saveSenderPolicy(draft: SenderPolicyDraft, existingPolicy: SenderPolicy? = nil) async -> SenderPolicy? {
        do {
            let policy = try draft.buildPolicy(existingPolicy: existingPolicy)
            let client = try await makeDaemonClient(autoStartIfNeeded: true)
            let snapshot = try await client.upsertSenderPolicy(policy)
            applyDaemonState(controlFile: client.controlFile, snapshot: snapshot)
            errorMessage = nil
            if existingPolicy == nil {
                statusMessage = LT("Saved daemon sender policy for \(policy.senderAddress).", "已保存 \(policy.senderAddress) 的 daemon 发件人策略。", "\(policy.senderAddress) の daemon 送信者ポリシーを保存した。")
            } else {
                statusMessage = LT("Updated daemon sender policy for \(policy.senderAddress).", "已更新 \(policy.senderAddress) 的 daemon 发件人策略。", "\(policy.senderAddress) の daemon 送信者ポリシーを更新した。")
            }
            return snapshot.senderPolicies.first(where: { $0.id == policy.id }) ?? policy
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func deleteSenderPolicy(_ policy: SenderPolicy) async {
        do {
            let client = try await makeDaemonClient(autoStartIfNeeded: true)
            let snapshot = try await client.deleteSenderPolicy(policyID: policy.id)
            applyDaemonState(controlFile: client.controlFile, snapshot: snapshot)
            errorMessage = nil
            statusMessage = LT("Removed daemon sender policy for \(policy.senderAddress).", "已删除 \(policy.senderAddress) 的 daemon 发件人策略。", "\(policy.senderAddress) の daemon 送信者ポリシーを削除した。")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func saveManagedProject(
        draft: ManagedProjectDraft,
        existingProject: ManagedProject? = nil
    ) async -> ManagedProject? {
        do {
            let project = try draft.buildProject(existingProject: existingProject)

            let normalizedSlug = project.slug.lowercased()
            if managedProjects.contains(where: { $0.id != project.id && $0.slug.lowercased() == normalizedSlug }) {
                throw MailroomValidationError.duplicateProjectSlug(project.slug)
            }

            let normalizedRoot = normalizedProjectPath(project.rootPath)
            if managedProjects.contains(where: {
                $0.id != project.id && normalizedProjectPath($0.rootPath) == normalizedRoot
            }) {
                throw MailroomValidationError.duplicateProjectRoot(project.rootPath)
            }

            let client = try await makeDaemonClient(autoStartIfNeeded: true)
            let snapshot = try await client.upsertManagedProject(project)
            applyDaemonState(controlFile: client.controlFile, snapshot: snapshot)
            errorMessage = nil

            if existingProject == nil {
                statusMessage = LT(
                    "Saved managed project \(project.displayName).",
                    "已保存受管项目 \(project.displayName)。",
                    "管理対象プロジェクト \(project.displayName) を保存した。"
                )
            } else {
                statusMessage = LT(
                    "Updated managed project \(project.displayName).",
                    "已更新受管项目 \(project.displayName)。",
                    "管理対象プロジェクト \(project.displayName) を更新した。"
                )
            }
            return snapshot.managedProjects.first(where: { $0.id == project.id }) ?? project
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func deleteManagedProject(_ project: ManagedProject) async {
        do {
            let client = try await makeDaemonClient(autoStartIfNeeded: true)
            let snapshot = try await client.deleteManagedProject(projectID: project.id)
            applyDaemonState(controlFile: client.controlFile, snapshot: snapshot)
            errorMessage = nil
            statusMessage = LT(
                "Removed managed project \(project.displayName).",
                "已删除受管项目 \(project.displayName)。",
                "管理対象プロジェクト \(project.displayName) を削除した。"
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func evaluatePolicy(request: MailPolicyRequestPreview) -> MailPolicyDecision {
        policyEngine.evaluate(request: request, senderPolicies: senderPolicies)
    }

    func submitPreviewRequest(_ preview: MailPolicyRequestPreview, assumeReviewApproved: Bool) {
        guard let jobStore else {
            errorMessage = LT("The SQLite job store is not available.", "SQLite job 存储不可用。", "SQLite ジョブストアが利用できない。")
            return
        }
        guard !isRunningCodex else {
            errorMessage = LT("A Codex preview run is already in progress.", "已经有一个 Codex 预览执行正在进行。", "すでに Codex プレビュー実行が進行中。")
            return
        }

        let decision = evaluatePolicy(request: preview)
        let preferredAccount = preferredMailboxAccount(for: preview.workspaceRoot)
        let fallbackRole = decision.effectiveRole ?? preferredAccount?.account.role ?? .operator
        let request = CodexMailRequest.preview(
            from: preview,
            matchedPolicy: decision.matchedPolicy,
            mailboxAccountID: preferredAccount?.id
        )
        latestJobID = request.id
        errorMessage = nil

        let bridge = CodexBridge(jobStore: jobStore)
        let shouldExecute = decision.requirement == .automatic || assumeReviewApproved
        if shouldExecute {
            isRunningCodex = true
            statusMessage = LT("Sending the preview request into the local Codex bridge...", "正在把预览请求发送到本地 Codex 执行桥...", "プレビュー要求をローカル Codex ブリッジへ送信している...")
        }

        Task {
            do {
                let job = try await Task.detached(priority: .userInitiated) {
                    try bridge.handle(
                        request: request,
                        decision: decision,
                        fallbackRole: fallbackRole,
                        assumeReviewApproved: assumeReviewApproved
                    )
                }.value

                reload()
                latestJobID = job.id
                isRunningCodex = false
                errorMessage = nil
                statusMessage = statusMessage(for: job)
            } catch {
                isRunningCodex = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func insertSampleJob() {
        guard let jobStore else {
            errorMessage = LT("The SQLite job store is not available.", "SQLite job 存储不可用。", "SQLite ジョブストアが利用できない。")
            return
        }

        do {
            let referenceAccount = accounts.first?.account
            try jobStore.insert(.sample(account: referenceAccount))
            reload()
            errorMessage = nil
            statusMessage = LT("Inserted a demo job into the local SQLite queue.", "已向本地 SQLite 队列插入一个演示 job。", "ローカル SQLite キューへデモジョブを挿入した。")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func probeAccount(_ configured: ConfiguredMailboxAccount) {
        guard let transportClient else {
            errorMessage = LT("Mail transport is not ready yet.", "邮件传输尚未就绪。", "メール転送の準備がまだできていない。")
            return
        }
        guard configured.hasPasswordStored else {
            errorMessage = LT("Save the app password before testing connectivity.", "请先保存应用密码再测试连通性。", "接続テストの前にアプリ用パスワードを保存してください。")
            return
        }
        if case .running = probeStates[configured.id] {
            return
        }

        let accountID = configured.id
        let account = configured.account
        probeStates[accountID] = .running
        errorMessage = nil
        statusMessage = LT("Testing connectivity for \(account.emailAddress)...", "正在测试 \(account.emailAddress) 连通性…", "\(account.emailAddress) の接続をテスト中…")

        Task {
            do {
                guard let password = try secretStore.password(for: accountID), !password.isEmpty else {
                    throw MailroomValidationError.emptyPassword
                }

                let summary = try await runProbe(
                    account: account,
                    password: password,
                    transportClient: transportClient
                )
                probeStates[accountID] = .finished(summary)
                applyProbeFeedback(for: account, summary: summary)
            } catch {
                probeStates[accountID] = .finished(
                    AccountProbeSummary(
                        imapOK: false,
                        smtpOK: false,
                        imapDetail: error.localizedDescription,
                        smtpDetail: error.localizedDescription
                    )
                )
                statusMessage = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func runProbe(
        account: MailboxAccount,
        password: String,
        transportClient: MailTransportClient
    ) async throws -> AccountProbeSummary {
        let result = try await Task.detached(priority: .userInitiated) {
            try transportClient.probe(account: account, password: password)
        }.value

        return AccountProbeSummary(
            imapOK: result.imap.ok,
            smtpOK: result.smtp.ok,
            imapDetail: result.imap.detail,
            smtpDetail: result.smtp.detail
        )
    }

    private func applyProbeFeedback(for account: MailboxAccount, summary: AccountProbeSummary) {
        if summary.succeeded {
            errorMessage = nil
            statusMessage = probeStatusMessage(for: account)
            return
        }

        statusMessage = nil
        errorMessage = probeFailureMessage(for: account, summary: summary)
    }

    private func probeStatusMessage(for account: MailboxAccount) -> String {
        LT(
            "Connectivity test succeeded for \(account.emailAddress).",
            "邮箱 \(account.emailAddress) 连通性测试通过。",
            "メールボックス \(account.emailAddress) の接続テストに成功した。"
        )
    }

    private func probeStatusMessage(for account: MailboxAccount, summary: AccountProbeSummary) -> String {
        if !summary.imapOK && !summary.smtpOK {
            return LT(
                "Connectivity test failed for \(account.emailAddress).",
                "邮箱 \(account.emailAddress) 连通性测试失败。",
                "メールボックス \(account.emailAddress) の接続テストに失敗した。"
            )
        }
        return LT(
            "Connectivity test for \(account.emailAddress) partially succeeded.",
            "邮箱 \(account.emailAddress) 连通性测试部分通过。",
            "メールボックス \(account.emailAddress) の接続テストが一部成功した。"
        )
    }

    private func probeFailureMessage(for account: MailboxAccount, summary: AccountProbeSummary) -> String {
        let baseMessage = probeStatusMessage(for: account, summary: summary)
        let details = summary.failureDetails
        guard !details.isEmpty else {
            return baseMessage
        }
        return "\(baseMessage) \(details.joined(separator: " "))"
    }

    private func saveBlockedMessage(for account: MailboxAccount, summary: AccountProbeSummary) -> String {
        let baseMessage = LT(
            "Daemon-backed relay mailbox \(account.emailAddress) was not saved because the connectivity test failed.",
            "信使邮箱 \(account.emailAddress) 连通性测试未通过，因此没有写入 daemon 配置。",
            "daemon 管理の中継メール \(account.emailAddress) は接続テストに失敗したため保存していない。"
        )
        let details = summary.failureDetails
        guard !details.isEmpty else {
            return baseMessage
        }
        return "\(baseMessage) \(details.joined(separator: " "))"
    }

    private func identityLockedMessage(for account: MailboxAccount) -> String {
        LT(
            "This daemon already uses \(account.emailAddress) as its relay mailbox. Remove it before configuring a different one.",
            "当前 daemon 已经把 \(account.emailAddress) 用作信使邮箱。如需更换，请先删除当前信使邮箱。",
            "この daemon はすでに \(account.emailAddress) を中継メールとして使っている。別のメールボックスに変えるには、先に現在の中継メールを削除してください。"
        )
    }

    private func preferredMailboxAccount(for _: String) -> ConfiguredMailboxAccount? {
        identityAccount
    }

    private func statusMessage(for job: ExecutionJobRecord) -> String {
        switch job.status {
        case .waiting:
            return LT("Queued preview request \(job.id) for admin review.", "预览请求 \(job.id) 已进入管理员审批队列。", "プレビュー要求 \(job.id) を管理者レビュー待ちへ入れた。")
        case .rejected:
            return LT("Rejected preview request \(job.id) because it failed the local policy checks.", "预览请求 \(job.id) 未通过本地策略检查，因此已被拒绝。", "プレビュー要求 \(job.id) はローカルポリシー検査に失敗したため拒否された。")
        case .succeeded:
            return LT("Codex completed preview request \(job.id) and stored the reply draft in SQLite.", "Codex 已完成预览请求 \(job.id)，并将回复草稿写入 SQLite。", "Codex がプレビュー要求 \(job.id) を完了し、返信草稿を SQLite へ保存した。")
        case .failed:
            return LT("Codex preview request \(job.id) failed; inspect the job ledger for details.", "Codex 预览请求 \(job.id) 执行失败；请查看 job 账本了解详情。", "Codex プレビュー要求 \(job.id) は失敗した。詳細はジョブ台帳を確認してください。")
        case .received, .accepted, .running:
            return LT("Updated preview request \(job.id).", "已更新预览请求 \(job.id)。", "プレビュー要求 \(job.id) を更新した。")
        }
    }

    private func bootstrapStores() {
        do {
            let supportDirectory = try MailroomPaths.applicationSupportDirectory()
            let accountsURL = try MailroomPaths.accountsFileURL()
            let policyURL = try MailroomPaths.senderPoliciesFileURL()
            let jobsURL = try MailroomPaths.jobsDatabaseURL()
            let daemonDatabaseURL = try MailroomPaths.mailroomDatabaseURL()
            let transportScriptURL = try MailroomPaths.mailTransportScriptURL()

            applicationSupportPath = supportDirectory.path
            accountsFilePath = accountsURL.path
            policyFilePath = policyURL.path
            jobsDatabasePath = jobsURL.path
            daemonDatabasePath = daemonDatabaseURL.path
            let client = MailTransportClient(scriptURL: transportScriptURL)
            transportClient = client
            jobStore = try SQLiteJobStore(databaseURL: jobsURL)
            daemonLocalStore = SQLiteMailroomLocalStore(databaseURL: daemonDatabaseURL)
            daemonSupervisor = MailroomDaemonSupervisor(supportRootURL: supportDirectory)
            syncDaemonRuntimeStatus()
        } catch {
            errorMessage = LT("Failed to prepare local storage: \(error.localizedDescription)", "准备本地存储失败：\(error.localizedDescription)", "ローカル保存領域の準備に失敗した: \(error.localizedDescription)")
        }
    }

    func refreshDaemonState() async {
        do {
            let result = try await readDaemonState(autoStartIfNeeded: true)
            applyDaemonState(controlFile: result.0, snapshot: result.1)
        } catch {
            daemonConnectionState = .unavailable(error.localizedDescription)
            daemonSnapshot = nil
            loadOfflineDaemonDataIfNeeded()
            syncDaemonRuntimeStatus()
        }
    }

    func ensureBackgroundDaemonRunning() async {
        guard let daemonSupervisor else {
            return
        }

        if let controlFile = daemonSupervisor.currentControlFile(),
           daemonSupervisor.isProcessAlive(controlFile.pid) {
            syncDaemonRuntimeStatus(controlFile: controlFile)
            return
        }

        do {
            _ = try await daemonSupervisor.autoStartIfNeeded()
            syncDaemonRuntimeStatus(controlFile: daemonSupervisor.currentControlFile())
        } catch {
            daemonConnectionState = .unavailable(error.localizedDescription)
            syncDaemonRuntimeStatus()
        }
    }

    func startDaemon() async {
        guard let daemonSupervisor else {
            errorMessage = LT("Daemon supervisor is not ready yet.", "daemon 管理器还没有准备好。", "daemon スーパーバイザの準備がまだできていない。")
            return
        }

        errorMessage = nil

        do {
            let controlFile = try await daemonSupervisor.startDaemon()
            syncDaemonRuntimeStatus(controlFile: controlFile)
            let result = try await readDaemonState(autoStartIfNeeded: false)
            applyDaemonState(controlFile: result.0, snapshot: result.1)
            statusMessage = LT(
                "Mailroom daemon is running.",
                "Mailroom daemon 已启动。",
                "Mailroom daemon を起動した。"
            )
        } catch {
            daemonConnectionState = .unavailable(error.localizedDescription)
            daemonSnapshot = nil
            errorMessage = error.localizedDescription
            syncDaemonRuntimeStatus()
        }
    }

    func stopDaemon() async {
        guard let daemonSupervisor else {
            errorMessage = LT("Daemon supervisor is not ready yet.", "daemon 管理器还没有准备好。", "daemon スーパーバイザの準備がまだできていない。")
            return
        }

        errorMessage = nil

        do {
            let controlFile = daemonControlFile
            try await daemonSupervisor.stopDaemon(using: controlFile)
            daemonConnectionState = .unavailable(
                LT("Daemon stopped.", "daemon 已停止。", "daemon を停止した。")
            )
            daemonSnapshot = nil
            isLoadingMailboxHistory = false
            probeStates = [:]
            loadOfflineDaemonDataIfNeeded(forceRefreshMailboxHistory: true)
            syncDaemonRuntimeStatus()
            statusMessage = LT("Mailroom daemon stopped.", "Mailroom daemon 已停止。", "Mailroom daemon を停止した。")
        } catch {
            errorMessage = error.localizedDescription
            syncDaemonRuntimeStatus()
        }
    }

    func restartDaemon() async {
        guard let daemonSupervisor else {
            errorMessage = LT("Daemon supervisor is not ready yet.", "daemon 管理器还没有准备好。", "daemon スーパーバイザの準備がまだできていない。")
            return
        }

        errorMessage = nil

        do {
            let restartedControlFile = try await daemonSupervisor.restartDaemon(using: daemonControlFile)
            syncDaemonRuntimeStatus(controlFile: restartedControlFile)
            let result = try await readDaemonState(autoStartIfNeeded: false)
            applyDaemonState(controlFile: result.0, snapshot: result.1)
            statusMessage = LT(
                "Mailroom daemon restarted.",
                "Mailroom daemon 已重启。",
                "Mailroom daemon を再起動した。"
            )
        } catch {
            daemonConnectionState = .unavailable(error.localizedDescription)
            daemonSnapshot = nil
            errorMessage = error.localizedDescription
            syncDaemonRuntimeStatus()
        }
    }

    func resolveApproval(
        approvalID: String,
        decision: String?,
        answers: [String: [String]],
        note: String?
    ) async {
        guard !resolvingApprovalIDs.contains(approvalID) else {
            return
        }

        resolvingApprovalIDs.insert(approvalID)
        errorMessage = nil

        do {
            let trimmedNote = note?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let client = try await makeDaemonClient(autoStartIfNeeded: true)
            let snapshot = try await client.resolveApproval(
                approvalID: approvalID,
                decision: decision,
                answers: answers,
                note: trimmedNote?.isEmpty == true ? nil : trimmedNote
            )

            applyDaemonState(controlFile: client.controlFile, snapshot: snapshot)
            statusMessage = LT(
                "Submitted approval \(approvalID) to the running daemon.",
                "已把审批 \(approvalID) 提交给正在运行的 daemon。",
                "承認 \(approvalID) を実行中の daemon へ送信した。"
            )
        } catch {
            daemonConnectionState = .unavailable(error.localizedDescription)
            errorMessage = error.localizedDescription
        }

        resolvingApprovalIDs.remove(approvalID)
    }

    func isResolvingApproval(_ approvalID: String) -> Bool {
        resolvingApprovalIDs.contains(approvalID)
    }

    func resolveThreadDecision(
        threadToken: String,
        decision: MailroomDaemonThreadDecision,
        task: String? = nil
    ) async {
        guard !resolvingThreadDecisionTokens.contains(threadToken) else {
            return
        }

        resolvingThreadDecisionTokens.insert(threadToken)
        errorMessage = nil

        do {
            let trimmedTask = task?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let client = try await makeDaemonClient(autoStartIfNeeded: true)
            let snapshot = try await client.resolveThreadDecision(
                threadToken: threadToken,
                decision: decision,
                task: trimmedTask?.isEmpty == true ? nil : trimmedTask
            )

            applyDaemonState(controlFile: client.controlFile, snapshot: snapshot)
            statusMessage = {
                switch decision {
                case .startTask:
                    return LT(
                        "Started the selected mail thread in the daemon.",
                        "已在 daemon 中启动这个邮件线程。",
                        "選択したメールスレッドを daemon で開始した。"
                    )
                case .recordOnly:
                    return LT(
                        "Recorded the selected mail thread without starting Codex.",
                        "已把这个邮件线程记为仅记录，不启动 Codex。",
                        "このメールスレッドを記録のみとして扱い、Codex は起動しなかった。"
                    )
                }
            }()
        } catch {
            daemonConnectionState = .unavailable(error.localizedDescription)
            errorMessage = error.localizedDescription
        }

        resolvingThreadDecisionTokens.remove(threadToken)
    }

    func isResolvingThreadDecision(_ threadToken: String) -> Bool {
        resolvingThreadDecisionTokens.contains(threadToken)
    }

    func mutateMailboxMessages(
        targets: [MailroomMailboxMessageTarget],
        action: MailroomMailboxRemoteAction
    ) async {
        let normalizedTargets = Array(Set(targets)).filter { !$0.mailboxID.isEmpty && $0.uid > 0 }
        guard !normalizedTargets.isEmpty else {
            errorMessage = LT(
                "Choose at least one mailbox message first.",
                "请先选择至少一封邮箱邮件。",
                "まず少なくとも 1 件のメールを選択してください。"
            )
            return
        }

        let targetIDs = Set(normalizedTargets.map(\.id))
        guard mutatingMailboxMessageIDs.isDisjoint(with: targetIDs) else {
            return
        }

        mutatingMailboxMessageIDs.formUnion(targetIDs)
        errorMessage = nil

        do {
            let client = try await makeDaemonClient(autoStartIfNeeded: true)
            let snapshot = try await client.mutateMailboxMessages(
                targets: normalizedTargets,
                action: action
            )
            applyDaemonState(controlFile: client.controlFile, snapshot: snapshot)
            statusMessage = {
                switch action {
                case .archive:
                    return LT(
                        "Archived \(normalizedTargets.count) relay mailbox message(s).",
                        "已归档 \(normalizedTargets.count) 封信使邮箱邮件。",
                        "\(normalizedTargets.count) 件の中継メールをアーカイブした。"
                    )
                case .delete:
                    return LT(
                        "Deleted \(normalizedTargets.count) relay mailbox message(s).",
                        "已删除 \(normalizedTargets.count) 封信使邮箱邮件。",
                        "\(normalizedTargets.count) 件の中継メールを削除した。"
                    )
                }
            }()
        } catch {
            errorMessage = error.localizedDescription
        }

        mutatingMailboxMessageIDs.subtract(targetIDs)
    }

    func isMutatingMailboxMessages(targets: [MailroomMailboxMessageTarget]) -> Bool {
        !Set(targets.map(\.id)).isDisjoint(with: mutatingMailboxMessageIDs)
    }

    private var daemonControlFile: MailroomDaemonControlFile? {
        if case .connected(let controlFile) = daemonConnectionState {
            return controlFile
        }
        return daemonSupervisor?.currentControlFile()
    }

    private func syncDaemonRuntimeStatus(controlFile: MailroomDaemonControlFile? = nil) {
        guard let daemonSupervisor else {
            return
        }
        daemonRuntimeStatus = daemonSupervisor.currentRuntimeStatus(
            connectionState: daemonConnectionState,
            controlFile: controlFile
        )
    }

    private func makeDaemonClient(autoStartIfNeeded: Bool) async throws -> MailroomDaemonClient {
        if autoStartIfNeeded,
           let daemonSupervisor,
           let controlFile = daemonSupervisor.currentControlFile(),
           !daemonSupervisor.isProcessAlive(controlFile.pid) {
            _ = try await daemonSupervisor.autoStartIfNeeded()
            syncDaemonRuntimeStatus()
        }

        do {
            return try MailroomDaemonClient()
        } catch let error as MailroomDaemonClientError {
            guard autoStartIfNeeded,
                  case .controlFileMissing = error else {
                throw error
            }
            guard let daemonSupervisor else {
                throw error
            }
            _ = try await daemonSupervisor.autoStartIfNeeded()
            syncDaemonRuntimeStatus()
            return try MailroomDaemonClient()
        }
    }

    private func readDaemonState(
        autoStartIfNeeded: Bool
    ) async throws -> (MailroomDaemonControlFile, MailroomDaemonStateSnapshot) {
        do {
            let client = try await makeDaemonClient(autoStartIfNeeded: autoStartIfNeeded)
            do {
                let snapshot = try await client.readState()
                return (client.controlFile, snapshot)
            } catch {
                if autoStartIfNeeded,
                   let daemonSupervisor,
                   !daemonSupervisor.isProcessAlive(client.controlFile.pid) {
                    _ = try await daemonSupervisor.autoStartIfNeeded()
                    syncDaemonRuntimeStatus()
                    let retryClient = try MailroomDaemonClient()
                    let snapshot = try await retryClient.readState()
                    return (retryClient.controlFile, snapshot)
                }
                throw error
            }
        } catch {
            syncDaemonRuntimeStatus()
            throw error
        }
    }

    private func applyDaemonState(controlFile: MailroomDaemonControlFile, snapshot: MailroomDaemonStateSnapshot) {
        daemonConnectionState = .connected(controlFile)
        daemonSnapshot = snapshot
        accounts = snapshot.mailboxAccounts
            .map {
                ConfiguredMailboxAccount(
                    account: $0.account,
                    hasPasswordStored: $0.hasPasswordStored
                )
            }
            .sorted {
                $0.account.label.localizedCaseInsensitiveCompare($1.account.label) == .orderedAscending
            }
        primeLocalMailboxPasswordCache(for: accounts)
        senderPolicies = snapshot.senderPolicies
            .sorted {
                $0.senderAddress.localizedCaseInsensitiveCompare($1.senderAddress) == .orderedAscending
            }
        managedProjects = snapshot.managedProjects
            .sorted {
                if $0.isEnabled != $1.isEnabled {
                    return $0.isEnabled && !$1.isEnabled
                }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        mailboxMessages = snapshot.mailboxMessages
        mailboxHistoryVisibleCount = snapshot.mailboxMessages.count
        mailboxHistoryErrorMessage = nil
        mailboxHistoryLastLoadedAt = snapshot.generatedAt
        isLoadingMailboxHistory = false

        notificationManager.processRecentMailActivity(snapshot.recentMailActivity)

        let validAccountIDs = Set(accounts.map(\.id))
        probeStates = probeStates.filter { validAccountIDs.contains($0.key) }
        mailboxHistoryTask?.cancel()
        syncDaemonRuntimeStatus(controlFile: controlFile)
    }

    private func scheduleMailboxHistoryRefreshIfNeeded(snapshot: MailroomDaemonStateSnapshot) {
        guard let configuredAccount = identityAccount else {
            mailboxHistoryTask?.cancel()
            isLoadingMailboxHistory = false
            mailboxHistoryErrorMessage = nil
            return
        }

        let currentAnchorUID = snapshot.mailboxHealth.first(where: { $0.accountID == configuredAccount.id })?.lastSeenUID
        scheduleMailboxHistoryRefresh(
            configuredAccount: configuredAccount,
            anchorUID: currentAnchorUID,
            force: false
        )
    }

    private func scheduleMailboxHistoryRefresh(
        configuredAccount: ConfiguredMailboxAccount,
        anchorUID: UInt64?,
        force: Bool
    ) {
        let isSameRequest =
            mailboxHistoryAccountID == configuredAccount.id &&
            mailboxHistoryAnchorUID == anchorUID

        let shouldRefresh =
            force ||
            mailboxHistoryAccountID != configuredAccount.id ||
            mailboxHistoryAnchorUID != anchorUID ||
            (mailboxHistory.isEmpty && !isLoadingMailboxHistory)

        guard shouldRefresh else {
            return
        }

        if isSameRequest && isLoadingMailboxHistory && !force {
            return
        }

        mailboxHistoryTask?.cancel()
        mailboxHistoryAccountID = configuredAccount.id
        mailboxHistoryAnchorUID = anchorUID
        mailboxHistoryTask = Task { [weak self] in
            await self?.refreshMailboxHistory(
                configuredAccount: configuredAccount,
                anchorUID: anchorUID
            )
        }
    }

    func refreshMailDesk() async {
        await refreshDaemonState()

        if accounts.isEmpty {
            loadOfflineDaemonDataIfNeeded()
        }
    }

    private func refreshMailboxHistory(
        configuredAccount: ConfiguredMailboxAccount,
        anchorUID: UInt64?
    ) async {
        guard let transportClient else {
            return
        }

        do {
            guard let password = try secretStore.password(for: configuredAccount.id)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !password.isEmpty else {
                mailboxHistory = []
                mailboxHistoryVisibleCount = 0
                mailboxHistoryErrorMessage = LT(
                    "The app password for this relay mailbox is missing, so Mailroom cannot pull inbox history yet.",
                    "这个信使邮箱还没有可用的应用密码，因此暂时无法拉取收件箱历史。",
                    "この中継メールのアプリパスワードが見つからないため、受信トレイ履歴を取得できない。"
                )
                return
            }

            isLoadingMailboxHistory = true
            defer { isLoadingMailboxHistory = false }

            let result = try await Task.detached(priority: .utility) {
                try transportClient.fetchRecentHistory(
                    account: configuredAccount.account,
                    password: password,
                    limit: 20
                )
            }.value

            guard !Task.isCancelled else {
                return
            }

            mailboxHistory = result.messages
            mailboxHistoryVisibleCount = result.visibleCount
            mailboxHistoryAccountID = configuredAccount.id
            mailboxHistoryAnchorUID = anchorUID
            mailboxHistoryErrorMessage = nil
            mailboxHistoryLastLoadedAt = Date()
        } catch {
            if mailboxHistoryAccountID != configuredAccount.id {
                mailboxHistory = []
                mailboxHistoryVisibleCount = 0
            }
            mailboxHistoryErrorMessage = error.localizedDescription
        }
    }

    private func loadOfflineDaemonDataIfNeeded(forceRefreshMailboxHistory: Bool = false) {
        guard let daemonLocalStore else {
            return
        }

        do {
            let offlineAccounts = try daemonLocalStore.loadMailboxAccounts(secretStore: secretStore)
            if !offlineAccounts.isEmpty, accounts.isEmpty {
                accounts = offlineAccounts.sorted {
                    $0.account.label.localizedCaseInsensitiveCompare($1.account.label) == .orderedAscending
                }
                primeLocalMailboxPasswordCache(for: accounts)
            }

            let offlinePolicies = try daemonLocalStore.loadSenderPolicies()
            if !offlinePolicies.isEmpty, senderPolicies.isEmpty {
                senderPolicies = offlinePolicies.sorted {
                    $0.senderAddress.localizedCaseInsensitiveCompare($1.senderAddress) == .orderedAscending
                }
            }

            let offlineProjects = try daemonLocalStore.loadManagedProjects()
            if !offlineProjects.isEmpty, managedProjects.isEmpty {
                managedProjects = offlineProjects.sorted {
                    if $0.isEnabled != $1.isEnabled {
                        return $0.isEnabled && !$1.isEnabled
                    }
                    return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                }
            }

            let offlineMessages = try daemonLocalStore.loadRecentMailboxMessages(limit: 200)
            if !offlineMessages.isEmpty, (mailboxMessages.isEmpty || forceRefreshMailboxHistory) {
                mailboxMessages = offlineMessages
                mailboxHistoryVisibleCount = offlineMessages.count
                mailboxHistoryErrorMessage = nil
                mailboxHistoryLastLoadedAt = offlineMessages.first?.updatedAt
            }

            mailboxHistoryTask?.cancel()
            isLoadingMailboxHistory = false
        } catch {
            if mailboxHistoryErrorMessage == nil {
                mailboxHistoryErrorMessage = error.localizedDescription
            }
        }
    }

    private func startDaemonMonitoringIfNeeded() {
        guard daemonPollingTask == nil else {
            return
        }

        daemonPollingTask = Task { [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                await self.refreshDaemonState()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private func primeLocalMailboxPasswordCache(for accounts: [ConfiguredMailboxAccount]) {
        for account in accounts {
            secretStore.primeLocalCacheFromKeychain(for: account.id)
        }
    }

    private func normalizedProjectPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
            .path
            .lowercased()
    }
}

enum MailroomDaemonConnectionState: Equatable, Sendable {
    case unknown
    case unavailable(String)
    case connected(MailroomDaemonControlFile)

    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }
}

enum AccountProbeState: Equatable, Sendable {
    case running
    case finished(AccountProbeSummary)
}

struct AccountProbeSummary: Equatable, Sendable {
    var imapOK: Bool
    var smtpOK: Bool
    var imapDetail: String?
    var smtpDetail: String?

    var succeeded: Bool {
        imapOK && smtpOK
    }

    var failureDetails: [String] {
        var details: [String] = []
        if !imapOK {
            details.append(
                LT(
                    "IMAP: \(imapDetail ?? "Unknown error")",
                    "IMAP：\(imapDetail ?? "未知错误")",
                    "IMAP: \(imapDetail ?? "不明なエラー")"
                )
            )
        }
        if !smtpOK {
            details.append(
                LT(
                    "SMTP: \(smtpDetail ?? "Unknown error")",
                    "SMTP：\(smtpDetail ?? "未知错误")",
                    "SMTP: \(smtpDetail ?? "不明なエラー")"
                )
            )
        }
        return details
    }
}
