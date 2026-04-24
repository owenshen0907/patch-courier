import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

enum MailroomSetupContentMode {
    case all
    case mailboxes
    case projects
    case policies
    case dispatch
}

struct MailroomSetupView: View {
    @ObservedObject var workspaceModel: MailroomWorkspaceModel
    let contentMode: MailroomSetupContentMode

    @AppStorage("mailroom.lastPickedDirectory") private var lastPickedDirectory: String = ""
    @State private var draft = MailboxAccountDraft()
    @State private var password = ""
    @State private var senderPolicyDraft = SenderPolicyDraft()
    @State private var managedProjectDraft = ManagedProjectDraft()
    @State private var selectedPolicyID: String?
    @State private var policyPreview = MailPolicyRequestPreview.example
    @State private var isPresentingMailboxEditor = false
    @State private var isPresentingManagedProjectEditor = false
    @State private var isPresentingSenderPolicyEditor = false
    @State private var mailboxEditorAccountID: String?
    @State private var managedProjectEditorProjectID: String?
    @State private var pendingMailboxDeletionID: String?
    @State private var pendingManagedProjectDeletionID: String?
    @State private var pendingSenderPolicyDeletionID: String?

    private var selectedPolicy: SenderPolicy? {
        guard let selectedPolicyID else {
            return nil
        }
        return workspaceModel.senderPolicies.first(where: { $0.id == selectedPolicyID })
    }

    private var mailboxEditorAccount: ConfiguredMailboxAccount? {
        guard let mailboxEditorAccountID else {
            return nil
        }
        return workspaceModel.accounts.first(where: { $0.id == mailboxEditorAccountID })
    }

    private var managedProjectEditorProject: ManagedProject? {
        guard let managedProjectEditorProjectID else {
            return nil
        }
        return workspaceModel.managedProjects.first(where: { $0.id == managedProjectEditorProjectID })
    }

    private var pendingMailboxDeletion: ConfiguredMailboxAccount? {
        guard let pendingMailboxDeletionID else {
            return nil
        }
        return workspaceModel.accounts.first(where: { $0.id == pendingMailboxDeletionID })
    }

    private var pendingManagedProjectDeletion: ManagedProject? {
        guard let pendingManagedProjectDeletionID else {
            return nil
        }
        return workspaceModel.managedProjects.first(where: { $0.id == pendingManagedProjectDeletionID })
    }

    private var pendingSenderPolicyDeletion: SenderPolicy? {
        guard let pendingSenderPolicyDeletionID else {
            return nil
        }
        return workspaceModel.senderPolicies.first(where: { $0.id == pendingSenderPolicyDeletionID })
    }

    private var enabledSenderCount: Int {
        workspaceModel.senderPolicies.filter { $0.isEnabled }.count
    }

    private var enabledManagedProjectCount: Int {
        workspaceModel.managedProjects.filter { $0.isEnabled }.count
    }

    private var senderPolicyWorkspaceRoots: [String] {
        SenderPolicyDraft.normalizedWorkspaceRoots(from: senderPolicyDraft.workspaceRootsText)
    }

    init(
        workspaceModel: MailroomWorkspaceModel,
        contentMode: MailroomSetupContentMode = .all
    ) {
        self.workspaceModel = workspaceModel
        self.contentMode = contentMode
    }

    var body: some View {
        Group {
            switch contentMode {
            case .all:
                allContent
            case .mailboxes:
                mailboxesContent
            case .projects:
                projectsContent
            case .policies:
                policiesContent
            case .dispatch:
                dispatchContent
            }
        }
        .task {
            workspaceModel.loadIfNeeded()
            syncDraftFromIdentity(force: true)
            syncSenderPolicySelection()
        }
        .onChange(of: workspaceModel.accounts) {
            syncDraftFromIdentity(force: true)
        }
        .onChange(of: workspaceModel.senderPolicies) {
            syncSenderPolicySelection()
        }
        .sheet(isPresented: $isPresentingMailboxEditor) {
            mailboxEditorSheet
                .frame(minWidth: 620, minHeight: 620)
        }
        .sheet(isPresented: $isPresentingManagedProjectEditor) {
            managedProjectEditorSheet
                .frame(minWidth: 620, minHeight: 620)
        }
        .sheet(isPresented: $isPresentingSenderPolicyEditor) {
            senderPolicyEditorSheet
                .frame(minWidth: 620, minHeight: 560)
        }
        .alert(
            mailboxDeletionTitle,
            isPresented: Binding(
                get: { pendingMailboxDeletion != nil },
                set: { if !$0 { pendingMailboxDeletionID = nil } }
            ),
            presenting: pendingMailboxDeletion
        ) { account in
            Button(LT("Cancel", "取消", "キャンセル"), role: .cancel) {
                pendingMailboxDeletionID = nil
            }
            Button(LT("Remove", "删除", "削除"), role: .destructive) {
                pendingMailboxDeletionID = nil
                Task { @MainActor in
                    await workspaceModel.deleteAccount(account)
                }
            }
        } message: { account in
            Text(
                LT(
                    "Remove \(account.account.emailAddress) from this Mac? Mailroom will stop polling that mailbox until you add another relay mailbox.",
                    "确认从这台 Mac 删除 \(account.account.emailAddress) 吗？删除后 Mailroom 会停止轮询这个邮箱，直到你重新添加信使邮箱。",
                    "この Mac から \(account.account.emailAddress) を削除しますか？削除すると、別の中継メールを追加するまで Mailroom はこのメールボックスのポーリングを停止します。"
                )
            )
        }
        .alert(
            managedProjectDeletionTitle,
            isPresented: Binding(
                get: { pendingManagedProjectDeletion != nil },
                set: { if !$0 { pendingManagedProjectDeletionID = nil } }
            ),
            presenting: pendingManagedProjectDeletion
        ) { project in
            Button(LT("Cancel", "取消", "キャンセル"), role: .cancel) {
                pendingManagedProjectDeletionID = nil
            }
            Button(LT("Remove", "删除", "削除"), role: .destructive) {
                pendingManagedProjectDeletionID = nil
                Task { @MainActor in
                    await workspaceModel.deleteManagedProject(project)
                }
            }
        } message: { project in
            Text(
                LT(
                    "Remove managed project \(project.displayName)? It will disappear from probe replies immediately.",
                    "确认删除受管项目 \(project.displayName) 吗？删除后它会立刻从探针邮件回复里消失。",
                    "管理対象プロジェクト \(project.displayName) を削除しますか？削除するとプローブ返信からすぐ消える。"
                )
            )
        }
        .alert(
            senderDeletionTitle,
            isPresented: Binding(
                get: { pendingSenderPolicyDeletion != nil },
                set: { if !$0 { pendingSenderPolicyDeletionID = nil } }
            ),
            presenting: pendingSenderPolicyDeletion
        ) { policy in
            Button(LT("Cancel", "取消", "キャンセル"), role: .cancel) {
                pendingSenderPolicyDeletionID = nil
            }
            Button(LT("Delete sender", "删除发件人", "送信者を削除"), role: .destructive) {
                pendingSenderPolicyDeletionID = nil
                Task { @MainActor in
                    await workspaceModel.deleteSenderPolicy(policy)
                }
            }
        } message: { policy in
            Text(
                LT(
                    "Delete the rule for \(policy.senderAddress)? Future mail from this sender will be ignored.",
                    "确认删除 \(policy.senderAddress) 的规则吗？之后来自这个发件人的邮件会被忽略。",
                    "\(policy.senderAddress) のルールを削除しますか？以後この送信者からのメールは無視されます。"
                )
            )
        }
    }

    private var allContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                statusBanners
                mailboxOverviewCard
                identityMailboxCard
                mailboxConfigCard
                managedProjectsSummaryCard
                senderPoliciesSummaryCard
                policyDecisionCard
                jobStoreCard
            }
            .padding(24)
        }
    }

    private var mailboxesContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                mailboxOverviewCard
                compactMailboxManagementCard
            }
            .padding(24)
        }
    }

    private var projectsContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                compactManagedProjectManagementCard
            }
            .padding(24)
        }
    }

    private var policiesContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                compactSenderPolicyManagementCard
            }
            .padding(24)
        }
    }

    private var dispatchContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                statusBanners
                policyDecisionCard
                jobStoreCard
            }
            .padding(24)
        }
    }

    private var mailboxOverviewCard: some View {
        let identityValue = workspaceModel.identityAccount == nil
            ? LT("Missing", "未配置", "未設定")
            : LT("Configured", "已配置", "設定完成")
        let identityDetail = workspaceModel.identityAccount?.account.emailAddress
            ?? LT("Set one mailbox for this Mac", "先给这台 Mac 配一个邮箱", "この Mac 用のメールボックスを設定する")
        let identityTint: Color = workspaceModel.identityAccount == nil ? .orange : .green
        let receiving = receivingOverview
        let whitelist = whitelistOverview
        let connectivity = connectivityOverview

        return SetupCard(
            title: LT("Setup overview", "配置总览", "設定の概要"),
            subtitle: nil,
            icon: "square.grid.2x2.fill",
            tint: Color(red: 0.28, green: 0.42, blue: 0.63)
        ) {
            LazyVGrid(columns: overviewColumns, alignment: .leading, spacing: 14) {
                OverviewTile(
                    title: LT("Relay", "信使邮箱", "中継メール"),
                    value: identityValue,
                    detail: identityDetail,
                    tint: identityTint
                )
                OverviewTile(
                    title: LT("Receiving", "收信状态", "受信状態"),
                    value: receiving.value,
                    detail: receiving.detail,
                    tint: receiving.tint
                )
                OverviewTile(
                    title: LT("Whitelist", "白名单", "許可リスト"),
                    value: whitelist.value,
                    detail: whitelist.detail,
                    tint: whitelist.tint
                )
                OverviewTile(
                    title: LT("Connectivity", "连通性", "接続状態"),
                    value: connectivity.value,
                    detail: connectivity.detail,
                    tint: connectivity.tint
                )
            }
        }
    }

    private var compactMailboxManagementCard: some View {
        SetupCard(
            title: LT("Relay mailbox", "信使邮箱", "中継メール"),
            subtitle: LT(
                "Keep the page clean and open the full form only when you need to add or edit mailbox details.",
                "平时保持页面简洁，只有在新增或编辑邮箱时才打开完整表单。",
                "通常は画面をすっきり保ち、メール設定の追加や編集が必要なときだけ完全なフォームを開く。"
            ),
            icon: "tray.full",
            tint: Color(red: 0.20, green: 0.34, blue: 0.63)
        ) {
            VStack(alignment: .leading, spacing: 18) {
                if let configuredAccount = workspaceModel.identityAccount {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(configuredAccount.account.label)
                                    .font(.title3.weight(.semibold))
                                Text(configuredAccount.account.emailAddress)
                                    .font(.subheadline.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }

                            Spacer(minLength: 0)

                            HStack(spacing: 8) {
                                StatusBadge(
                                    label: configuredAccount.hasPasswordStored
                                        ? LT("Password ready", "密码已就绪", "パスワード保存済み")
                                        : LT("Password missing", "缺少密码", "パスワード未設定"),
                                    tint: configuredAccount.hasPasswordStored ? .green : .orange
                                )

                                if let mailboxHealth = workspaceModel.daemonMailboxHealth.first(where: { $0.accountID == configuredAccount.id }) {
                                    StatusBadge(
                                        label: mailboxHealthStateLabel(mailboxHealth.state),
                                        tint: mailboxHealthTint(mailboxHealth.state)
                                    )
                                }
                            }
                        }

                        LazyVGrid(columns: overviewColumns, alignment: .leading, spacing: 14) {
                            CompactInfoTile(
                                title: LT("Role", "角色", "ロール"),
                                value: configuredAccount.account.role.title
                            )
                            CompactInfoTile(
                                title: LT("Workspace", "工作区", "ワークスペース"),
                                value: configuredAccount.account.workspaceRoot,
                                monospaced: true
                            )
                            CompactInfoTile(
                                title: LT("Mail servers", "邮件服务器", "メールサーバー"),
                                value: configuredAccount.account.connectionSummary,
                                monospaced: true
                            )
                            CompactInfoTile(
                                title: LT("Polling", "轮询", "ポーリング"),
                                value: LT(
                                    "Every \(configuredAccount.account.pollingIntervalSeconds) seconds",
                                    "每 \(configuredAccount.account.pollingIntervalSeconds) 秒",
                                    "\(configuredAccount.account.pollingIntervalSeconds) 秒ごと"
                                )
                            )
                        }

                        if let summary = latestProbeSummary {
                            compactProbeSummary(summary)
                        }

                        HStack(spacing: 12) {
                            Button(LT("Edit", "编辑", "編集")) {
                                openMailboxEditor(for: configuredAccount)
                            }
                            .buttonStyle(.borderedProminent)

                            Button(probeButtonLabel(for: configuredAccount)) {
                                workspaceModel.probeAccount(configuredAccount)
                            }
                            .buttonStyle(.bordered)
                            .disabled(!configuredAccount.hasPasswordStored || isProbing(configuredAccount))

                            Button(LT("Remove", "删除", "削除"), role: .destructive) {
                                pendingMailboxDeletionID = configuredAccount.id
                            }
                            .buttonStyle(.bordered)

                            Spacer(minLength: 0)
                        }
                    }
                } else {
                    EmptyStateView(
                        title: LT("No relay mailbox yet", "还没有信使邮箱", "中継メールがまだない"),
                        message: LT(
                            "Add one relay mailbox and this Mac can start receiving approved command mail.",
                            "添加一个信使邮箱后，这台 Mac 才能开始接收已授权的命令邮件。",
                            "中継メールを 1 つ追加すると、この Mac が承認済みコマンドメールを受信できるようになる。"
                        ),
                        icon: "tray"
                    )

                    HStack {
                        Spacer(minLength: 0)
                        Button(LT("Add relay mailbox", "添加信使邮箱", "中継メールを追加")) {
                            openMailboxEditor(for: nil)
                        }
                        .buttonStyle(.borderedProminent)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var managedProjectsSummaryCard: some View {
        SetupCard(
            title: LT("Managed projects", "受管项目", "管理対象プロジェクト"),
            subtitle: LT(
                "Only the projects configured here are sent back in the first probe reply.",
                "只有这里配置过的项目，才会出现在首次探针邮件的回信里。",
                "ここで設定したプロジェクトだけが最初のプローブ返信に載る。"
            ),
            icon: "folder.badge.gearshape",
            tint: Color(red: 0.55, green: 0.43, blue: 0.22)
        ) {
            LazyVGrid(columns: overviewColumns, alignment: .leading, spacing: 14) {
                OverviewTile(
                    title: LT("Enabled", "启用中", "有効"),
                    value: "\(enabledManagedProjectCount)",
                    detail: LT(
                        "\(workspaceModel.managedProjects.count) total projects",
                        "共 \(workspaceModel.managedProjects.count) 个项目",
                        "合計 \(workspaceModel.managedProjects.count) 件"
                    ),
                    tint: enabledManagedProjectCount == 0 ? .orange : .green
                )
                OverviewTile(
                    title: LT("Reply model", "回信方式", "返信モデル"),
                    value: LT("Project probe", "项目探针", "プロジェクトプローブ"),
                    detail: LT(
                        "Whitelist admins/operators receive project choices first.",
                        "白名单管理员 / 操作员会先收到项目选择回信。",
                        "許可リストの admin / operator には先にプロジェクト選択を返す。"
                    ),
                    tint: Color(red: 0.55, green: 0.43, blue: 0.22)
                )
            }
        }
    }

    private var compactManagedProjectManagementCard: some View {
        SetupCard(
            title: LT("Managed projects", "受管项目", "管理対象プロジェクト"),
            subtitle: LT(
                "Use this list to decide which local repos can be offered back in mail replies.",
                "用这个列表决定哪些本地项目会被回信给邮件里的管理员 / 操作员。",
                "メール返信で提示するローカルプロジェクトをこの一覧で決める。"
            ),
            icon: "folder.badge.gearshape",
            tint: Color(red: 0.55, green: 0.43, blue: 0.22)
        ) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 12) {
                    HStack(spacing: 8) {
                        StatusBadge(
                            label: LT(
                                "\(enabledManagedProjectCount) active",
                                "\(enabledManagedProjectCount) 个启用",
                                "\(enabledManagedProjectCount) 件有効"
                            ),
                            tint: enabledManagedProjectCount == 0 ? .orange : .green
                        )
                        StatusBadge(
                            label: LT(
                                "\(workspaceModel.managedProjects.count) total",
                                "共 \(workspaceModel.managedProjects.count) 个",
                                "合計 \(workspaceModel.managedProjects.count) 件"
                            ),
                            tint: Color(red: 0.55, green: 0.43, blue: 0.22)
                        )
                    }

                    Spacer(minLength: 0)

                    Button(LT("Add project", "添加项目", "プロジェクト追加")) {
                        beginManagedProjectCreation()
                    }
                    .buttonStyle(.borderedProminent)
                }

                if workspaceModel.managedProjects.isEmpty {
                    EmptyStateView(
                        title: LT("No managed project yet", "还没有受管项目", "管理対象プロジェクトがまだない"),
                        message: LT(
                            "Add the local projects you want Mailroom to offer in first-contact probe replies.",
                            "把你希望 Mailroom 在首次探针回信里给出的本地项目加到这里。",
                            "最初のプローブ返信で Mailroom が提示すべきローカルプロジェクトをここへ追加する。"
                        ),
                        icon: "folder"
                    )
                } else {
                    VStack(spacing: 12) {
                        ForEach(workspaceModel.managedProjects) { project in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(project.displayName)
                                            .font(.headline)
                                        Text(project.slug)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }

                                    Spacer(minLength: 0)

                                    HStack(spacing: 8) {
                                        StatusBadge(
                                            label: project.isEnabled
                                                ? LT("Enabled", "已启用", "有効")
                                                : LT("Disabled", "已停用", "無効"),
                                            tint: project.isEnabled ? .green : .orange
                                        )
                                        StatusBadge(
                                            label: project.defaultCapability.title,
                                            tint: Color(red: 0.19, green: 0.31, blue: 0.56)
                                        )
                                    }
                                }

                                CompactInfoTile(
                                    title: LT("Root", "根目录", "ルート"),
                                    value: project.rootPath,
                                    monospaced: true
                                )

                                if !project.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(project.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                HStack(spacing: 12) {
                                    Button(LT("Edit", "编辑", "編集")) {
                                        openManagedProjectEditor(for: project)
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Button(LT("Remove", "删除", "削除"), role: .destructive) {
                                        pendingManagedProjectDeletionID = project.id
                                    }
                                    .buttonStyle(.bordered)

                                    Spacer(minLength: 0)
                                }
                            }
                            .padding(16)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color.black.opacity(0.03))
                            )
                        }
                    }
                }
            }
        }
    }

    private var compactSenderPolicyManagementCard: some View {
        SetupCard(
            title: LT("Authorized senders", "授权发件人", "許可済み送信者"),
            subtitle: LT(
                "The list stays compact until you explicitly open the sender editor.",
                "列表默认保持简洁，只有在你明确点编辑时才展开输入表单。",
                "リストは普段コンパクトに保ち、明示的に編集を開いたときだけ入力フォームを表示する。"
            ),
            icon: "person.crop.rectangle.badge.checkmark",
            tint: Color(red: 0.21, green: 0.54, blue: 0.43)
        ) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 12) {
                    HStack(spacing: 8) {
                        StatusBadge(
                            label: LT(
                                "\(enabledSenderCount) active",
                                "\(enabledSenderCount) 个启用",
                                "\(enabledSenderCount) 件有効"
                            ),
                            tint: enabledSenderCount == 0 ? .orange : .green
                        )
                        StatusBadge(
                            label: LT(
                                "\(workspaceModel.senderPolicies.count) total",
                                "共 \(workspaceModel.senderPolicies.count) 个",
                                "合計 \(workspaceModel.senderPolicies.count) 件"
                            ),
                            tint: .blue
                        )
                    }

                    Spacer(minLength: 0)

                    Button(LT("New sender", "新增发件人", "送信者を追加")) {
                        beginNewSenderPolicy()
                        isPresentingSenderPolicyEditor = true
                    }
                    .buttonStyle(.borderedProminent)
                }

                if workspaceModel.senderPolicies.isEmpty {
                    EmptyStateView(
                        title: LT("No whitelist yet", "还没有白名单", "許可リストがまだない"),
                        message: LT(
                            "Only listed senders can reach Codex. Add the first sender when you're ready.",
                            "只有白名单中的发件人才能进入 Codex。准备好了再添加第一位。",
                            "許可リストに入っている送信者だけが Codex に到達できる。準備ができたら最初の送信者を追加する。"
                        ),
                        icon: "person.crop.rectangle.stack"
                    )
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(workspaceModel.senderPolicies) { policy in
                            VStack(alignment: .leading, spacing: 14) {
                                policySummaryRow(policy)

                                HStack(spacing: 10) {
                                    Button(LT("Edit", "编辑", "編集")) {
                                        selectPolicy(policy)
                                        isPresentingSenderPolicyEditor = true
                                    }
                                    .buttonStyle(.bordered)

                                    Button(LT("Delete", "删除", "削除"), role: .destructive) {
                                        pendingSenderPolicyDeletionID = policy.id
                                    }
                                    .buttonStyle(.bordered)

                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var mailboxConfigCard: some View {
        SetupCard(
            title: LT("Configure relay mailbox", "配置信使邮箱", "中継メールの設定"),
            subtitle: nil,
            icon: "slider.horizontal.3",
            tint: Color(red: 0.20, green: 0.34, blue: 0.63)
        ) {
            VStack(alignment: .leading, spacing: 18) {
                if let configuredIdentity = workspaceModel.identityAccount {
                    InlineBanner(
                        label: LT(
                            "This Mac already uses \(configuredIdentity.account.emailAddress) as its relay mailbox. Remove it above before switching to another one.",
                            "这台 Mac 已经把 \(configuredIdentity.account.emailAddress) 设为信使邮箱。如果要切换，请先在上面删除当前信使邮箱。",
                            "この Mac はすでに \(configuredIdentity.account.emailAddress) を中継メールとして使っている。切り替える前に上で現在の中継メールを削除してください。"
                        ),
                        tint: .orange
                    )
                }

                mailboxFormSections(
                    editingAccount: nil,
                    disableCoreFields: workspaceModel.identityAccount != nil
                )

                if workspaceModel.identityAccount == nil {
                    HStack(spacing: 12) {
                        Button(LT("Use example", "填入示例", "サンプルを使う")) {
                            draft = .example
                            password = ""
                        }
                        .buttonStyle(.bordered)

                        Spacer(minLength: 0)

                        Button(saveButtonLabel) {
                            Task { @MainActor in
                                await saveMailbox(editingAccount: nil)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(workspaceModel.isSavingAccount)
                    }
                }
            }
        }
    }

    private var identityMailboxCard: some View {
        SetupCard(
            title: LT("Current relay mailbox", "当前信使邮箱", "現在の中継メール"),
            subtitle: nil,
            icon: "envelope.badge.shield.half.filled",
            tint: Color(red: 0.14, green: 0.53, blue: 0.42)
        ) {
            if let configuredAccount = workspaceModel.identityAccount {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(configuredAccount.account.label)
                                .font(.title3.weight(.semibold))
                            Text(configuredAccount.account.emailAddress)
                                .font(.subheadline.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        Spacer(minLength: 0)

                        VStack(alignment: .trailing, spacing: 12) {
                            StatusBadge(
                                label: configuredAccount.hasPasswordStored
                                    ? LT("Ready", "已就绪", "準備完了")
                                    : LT("Password missing", "缺少密码", "パスワード未設定"),
                                tint: configuredAccount.hasPasswordStored ? .green : .orange
                            )

                            HStack(spacing: 10) {
                                Button(probeButtonLabel(for: configuredAccount)) {
                                    workspaceModel.probeAccount(configuredAccount)
                                }
                                .buttonStyle(.bordered)
                                .disabled(!configuredAccount.hasPasswordStored || isProbing(configuredAccount))

                                Button(LT("Remove", "删除", "削除"), role: .destructive) {
                                    Task { @MainActor in
                                        await workspaceModel.deleteAccount(configuredAccount)
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    LazyVGrid(columns: overviewColumns, alignment: .leading, spacing: 14) {
                        CompactInfoTile(
                            title: LT("Role", "角色", "ロール"),
                            value: configuredAccount.account.role.title
                        )
                        CompactInfoTile(
                            title: LT("Workspace", "工作区", "ワークスペース"),
                            value: configuredAccount.account.workspaceRoot,
                            monospaced: true
                        )
                        CompactInfoTile(
                            title: LT("Mail servers", "邮件服务器", "メールサーバー"),
                            value: configuredAccount.account.connectionSummary,
                            monospaced: true
                        )
                        CompactInfoTile(
                            title: LT("Polling", "轮询", "ポーリング"),
                            value: LT(
                                "Every \(configuredAccount.account.pollingIntervalSeconds) seconds",
                                "每 \(configuredAccount.account.pollingIntervalSeconds) 秒",
                                "\(configuredAccount.account.pollingIntervalSeconds) 秒ごと"
                            )
                        )
                    }

                    receptionStatusView(for: configuredAccount)
                    probeResultView(for: configuredAccount)
                }
            } else {
                EmptyStateView(
                    title: LT("No relay mailbox yet", "还没有信使邮箱", "中継メールがまだない"),
                    message: LT(
                        "Add one relay mailbox below and this Mac can start receiving command mail.",
                        "在下面配置一个信使邮箱后，这台 Mac 才能开始收命令邮件。",
                        "下で中継メールを 1 つ設定すると、この Mac がコマンドメールを受信できるようになる。"
                    ),
                    icon: "tray"
                )
            }
        }
    }

    private var senderPoliciesSummaryCard: some View {
        SetupCard(
            title: LT("Authorized senders", "授权邮箱", "許可済み送信者"),
            subtitle: nil,
            icon: "person.crop.rectangle.badge.checkmark",
            tint: Color(red: 0.21, green: 0.54, blue: 0.43)
        ) {
            if workspaceModel.senderPolicies.isEmpty {
                EmptyStateView(
                    title: LT("No whitelist yet", "还没有白名单", "許可リストがまだない"),
                    message: LT(
                        "Add the senders you want to forward into Codex.",
                        "把你要转发给 Codex 的发件人加进来。",
                        "Codex に転送したい送信者を追加する。"
                    ),
                    icon: "person.crop.rectangle.stack"
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        StatusBadge(
                            label: LT(
                                "\(enabledSenderCount) active",
                                "\(enabledSenderCount) 个启用",
                                "\(enabledSenderCount) 件有効"
                            ),
                            tint: enabledSenderCount == 0 ? .orange : .green
                        )
                        StatusBadge(
                            label: LT(
                                "\(workspaceModel.senderPolicies.count) total",
                                "共 \(workspaceModel.senderPolicies.count) 个",
                                "合計 \(workspaceModel.senderPolicies.count) 件"
                            ),
                            tint: .blue
                        )
                    }

                    ForEach(Array(workspaceModel.senderPolicies.prefix(3))) { policy in
                        policySummaryRow(policy)
                    }

                    if workspaceModel.senderPolicies.count > 3 {
                        Text(
                            LT(
                                "+ \(workspaceModel.senderPolicies.count - 3) more senders",
                                "+ \(workspaceModel.senderPolicies.count - 3) 个更多发件人",
                                "+ \(workspaceModel.senderPolicies.count - 3) 件の送信者"
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var senderPolicyListPane: some View {
        SetupCard(
            title: LT("Authorized senders", "授权邮箱", "許可済み送信者"),
            subtitle: nil,
            icon: "person.crop.rectangle.badge.checkmark",
            tint: Color(red: 0.21, green: 0.54, blue: 0.43)
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    Text(
                        LT(
                            "\(enabledSenderCount) active / \(workspaceModel.senderPolicies.count) total",
                            "\(enabledSenderCount) 个启用 / 共 \(workspaceModel.senderPolicies.count) 个",
                            "\(enabledSenderCount) 件有効 / 合計 \(workspaceModel.senderPolicies.count) 件"
                        )
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    Button(LT("New", "新增", "新規")) {
                        beginNewSenderPolicy()
                    }
                    .buttonStyle(.borderedProminent)
                }

                if workspaceModel.senderPolicies.isEmpty {
                    EmptyStateView(
                        title: LT("No whitelist yet", "还没有白名单", "許可リストがまだない"),
                        message: LT(
                            "Create the first sender rule on the right.",
                            "在右边创建第一条发件人规则。",
                            "右側で最初の送信者ルールを作成する。"
                        ),
                        icon: "person.crop.rectangle.stack"
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(workspaceModel.senderPolicies) { policy in
                                Button {
                                    selectPolicy(policy)
                                } label: {
                                    SenderPolicyListRow(
                                        policy: policy,
                                        isSelected: policy.id == selectedPolicyID
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
    }

    private var senderPolicyEditorPane: some View {
        let policy = selectedPolicy

        return SetupCard(
            title: policy == nil
                ? LT("New sender rule", "新增发件人规则", "新しい送信者ルール")
                : LT("Edit sender rule", "编辑发件人规则", "送信者ルールを編集"),
            subtitle: nil,
            icon: "slider.horizontal.3",
            tint: Color(red: 0.31, green: 0.48, blue: 0.68)
        ) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(policy?.displayName.isEmpty == false ? policy?.displayName ?? "" : LT("Unsaved sender", "未保存发件人", "未保存の送信者"))
                            .font(.headline)
                        Text(
                            policy?.senderAddress
                                ?? LT("Fill the sender address and save it.", "填好发件人地址后保存即可。", "送信者アドレスを入れて保存する。")
                        )
                        .font(policy == nil ? .subheadline : .subheadline.monospaced())
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 8) {
                        StatusBadge(
                            label: senderPolicyDraft.assignedRole.title,
                            tint: .blue
                        )
                        StatusBadge(
                            label: senderPolicyDraft.isEnabled
                                ? LT("Enabled", "已启用", "有効")
                                : LT("Disabled", "已禁用", "無効"),
                            tint: senderPolicyDraft.isEnabled ? .green : .gray
                        )
                        StatusBadge(
                            label: senderPolicyDraft.requiresReplyToken
                                ? LT("First-mail confirm", "需首封确认", "初回メール確認あり")
                                : LT("Direct start", "可直接启动", "即時開始"),
                            tint: senderPolicyDraft.requiresReplyToken ? .orange : .green
                        )
                    }
                }

                if workspaceModel.identityAccount == nil {
                    InlineBanner(
                        label: LT(
                            "You can save whitelist rules now, but mail will not start flowing until this Mac also has a relay mailbox.",
                            "白名单现在就可以先配，但只有这台 Mac 也配置好信使邮箱后，邮件才会真正流转。",
                            "許可ルールは先に保存できるが、この Mac に中継メールが設定されるまでは実際の受信は始まらない。"
                        ),
                        tint: .orange
                    )
                }

                senderPolicyFormSections

                HStack(spacing: 12) {
                    Button(LT("Admin example", "管理员示例", "管理者サンプル")) {
                        selectedPolicyID = nil
                        senderPolicyDraft = .exampleAdmin
                    }
                    .buttonStyle(.bordered)

                    if let policy {
                        Button(LT("Revert", "恢复", "元に戻す")) {
                            senderPolicyDraft = .template(from: policy)
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer(minLength: 0)

                    if let policy {
                        Button(LT("Delete", "删除", "削除"), role: .destructive) {
                            Task { @MainActor in
                                await workspaceModel.deleteSenderPolicy(policy)
                            }
                        }
                        .buttonStyle(.bordered)
                    }

                    Button(policy == nil ? LT("Save sender", "保存发件人", "送信者を保存") : LT("Save changes", "保存修改", "変更を保存")) {
                        Task { @MainActor in
                            await saveSelectedSenderPolicy()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var jobStoreCard: some View {
        SetupCard(
            title: LT("Job queue", "任务队列", "ジョブキュー"),
            subtitle: nil,
            icon: "shippingbox.circle",
            tint: Color(red: 0.73, green: 0.38, blue: 0.24)
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Button(LT("Insert sample job", "插入演示任务", "デモジョブを挿入")) {
                        workspaceModel.insertSampleJob()
                    }
                    .buttonStyle(.bordered)
                }

                if workspaceModel.jobs.isEmpty {
                    EmptyStateView(
                        title: LT("No queued jobs yet", "还没有任务", "ジョブがまだない"),
                        message: nil,
                        icon: "shippingbox"
                    )
                } else {
                    ForEach(workspaceModel.jobs) { job in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(job.action)
                                        .font(.headline)
                                    if !job.subject.isEmpty {
                                        Text(job.subject)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 12)
                                StatusBadge(label: job.status.title, tint: color(for: job.status))
                            }

                            Text(job.summary)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 12) {
                                StatusBadge(label: job.requestedRole.title, tint: .blue)
                                StatusBadge(label: job.capability.title, tint: .purple)
                                StatusBadge(label: job.approvalRequirement.title, tint: color(for: job.approvalRequirement))
                            }

                            Text(LT("Sender: \(job.senderAddress)", "发件人：\(job.senderAddress)", "送信者: \(job.senderAddress)"))
                                .font(.subheadline.monospaced())
                                .foregroundStyle(.secondary)
                            Text(LT("Workspace: \(job.workspaceRoot)", "工作区：\(job.workspaceRoot)", "ワークスペース: \(job.workspaceRoot)"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            if let detailPreview = job.detailPreview {
                                Text(detailPreview)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }

                            if let codexCommand = job.codexCommand {
                                Text(codexCommand)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }

                            HStack(spacing: 12) {
                                Text(LT("Received \(job.receivedAt.formatted(date: .numeric, time: .shortened))", "接收于 \(job.receivedAt.formatted(date: .numeric, time: .shortened))", "受信 \(job.receivedAt.formatted(date: .numeric, time: .shortened))"))
                                if let startedAt = job.startedAt {
                                    Text(LT("Started \(startedAt.formatted(date: .omitted, time: .shortened))", "开始于 \(startedAt.formatted(date: .omitted, time: .shortened))", "開始 \(startedAt.formatted(date: .omitted, time: .shortened))"))
                                }
                                if let completedAt = job.completedAt {
                                    Text(LT("Finished \(completedAt.formatted(date: .omitted, time: .shortened))", "完成于 \(completedAt.formatted(date: .omitted, time: .shortened))", "完了 \(completedAt.formatted(date: .omitted, time: .shortened))"))
                                }
                                if let exitCode = job.exitCode {
                                    Text(LT("Exit \(exitCode)", "退出码 \(exitCode)", "終了コード \(exitCode)"))
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .background(cardInsetBackground)
                    }
                }
            }
        }
    }

    private var policyDecisionCard: some View {
        let decision = workspaceModel.evaluatePolicy(request: policyPreview)

        return SetupCard(
            title: LT("Preview", "预览", "プレビュー"),
            subtitle: nil,
            icon: "mail.stack",
            tint: Color(red: 0.55, green: 0.43, blue: 0.17)
        ) {
            VStack(alignment: .leading, spacing: 18) {
                LazyVGrid(columns: formColumns, alignment: .leading, spacing: 14) {
                    FieldGroup(title: LT("Preview sender", "预览发件人", "プレビュー送信者")) {
                        TextField("ops@example.com", text: $policyPreview.senderAddress)
                            .textFieldStyle(.roundedBorder)
                    }
                    FieldGroup(title: LT("Capability", "能力类别", "権限カテゴリ")) {
                        Picker(LT("Capability", "能力类别", "権限カテゴリ"), selection: $policyPreview.capability) {
                            ForEach(MailCapability.allCases) { capability in
                                Text(capability.title).tag(capability)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    FieldGroup(title: LT("Workspace root", "工作区根目录", "ワークスペースルート")) {
                        FolderPathField(
                            path: $policyPreview.workspaceRoot,
                            placeholder: "~/Workspace/patch-courier",
                            chooseLabel: LT("Choose folder", "选择文件夹", "フォルダを選択"),
                            status: workspaceRootStatus(for: policyPreview.workspaceRoot)
                        ) {
                            choosePolicyPreviewWorkspaceRoot()
                        }
                    }
                    FieldGroup(title: LT("First-mail confirm", "首封确认", "初回確認")) {
                        Toggle(LT("Preview already includes confirmation token", "预览请求已包含确认 token", "プレビュー要求に確認トークンが含まれている"), isOn: $policyPreview.replyTokenPresent)
                    }
                }

                FieldGroup(title: LT("Requested action", "请求动作", "要求アクション")) {
                    TextField(LT("Run xcodebuild to verify the current workspace.", "运行 xcodebuild 验证当前工作区。", "xcodebuild を実行して現在のワークスペースを確認する。"), text: $policyPreview.actionSummary)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        StatusBadge(label: decision.requirement.title, tint: color(for: decision.requirement))
                        if let role = decision.effectiveRole {
                            StatusBadge(label: role.title, tint: .blue)
                        }
                        if workspaceModel.isRunningCodex {
                            StatusBadge(label: LT("Codex running", "Codex 执行中", "Codex 実行中"), tint: .orange)
                        }
                    }

                    if let matchedPolicy = decision.matchedPolicy {
                        Text(LT("Matched sender policy: \(matchedPolicy.displayName) • \(matchedPolicy.senderAddress)", "匹配到发件人策略：\(matchedPolicy.displayName) • \(matchedPolicy.senderAddress)", "一致した送信者ポリシー: \(matchedPolicy.displayName) • \(matchedPolicy.senderAddress)"))
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                    } else {
                        Text(LT("No sender policy matched the current preview sender.", "当前预览发件人没有匹配到任何策略。", "現在のプレビュー送信者に一致するポリシーがない。"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Text(decision.reason)
                        .font(.headline)
                    Text(decision.nextStep)
                        .foregroundStyle(.secondary)
                    Text(policyPreview.capability.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(cardInsetBackground)

                executionButtons(for: decision)

                if let latestJob = workspaceModel.latestJob {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(LT("Latest bridge snapshot", "最近一次执行桥快照", "最新ブリッジスナップショット"))
                                    .font(.headline)
                                Text(latestJob.id)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 12)
                            StatusBadge(label: latestJob.status.title, tint: color(for: latestJob.status))
                        }

                        Text(latestJob.summary)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            StatusBadge(label: latestJob.capability.title, tint: .purple)
                            StatusBadge(label: latestJob.approvalRequirement.title, tint: color(for: latestJob.approvalRequirement))
                        }

                        if let detailPreview = latestJob.detailPreview {
                            Text(detailPreview)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(cardInsetBackground)
                }
            }
        }
    }

    @ViewBuilder
    private var senderPolicyAllowedWorkspacesEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button(LT("Add folder", "添加文件夹", "フォルダ追加")) {
                    chooseSenderPolicyWorkspaceRoot()
                }
                .buttonStyle(.bordered)

                Text(LT("Pick a folder or paste paths below.", "可以选择文件夹，也可以继续在下面直接粘贴路径。", "フォルダを選ぶか、下にパスを直接貼り付ける。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if senderPolicyWorkspaceRoots.isEmpty {
                InlineBanner(
                    label: LT(
                        "Add at least one workspace root for this sender.",
                        "请至少给这个发件人添加一个工作区根目录。",
                        "この送信者に少なくとも 1 つのワークスペースルートを追加する。"
                    ),
                    tint: .orange
                )
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(senderPolicyWorkspaceRoots, id: \.self) { root in
                        AllowedWorkspacePathRow(
                            path: root,
                            status: workspaceRootStatus(for: root),
                            removeLabel: LT("Remove", "移除", "削除")
                        ) {
                            removeSenderPolicyWorkspaceRoot(root)
                        }
                    }
                }
            }

            MultiLineInsetEditor(
                text: $senderPolicyDraft.workspaceRootsText,
                placeholder: LT(
                    "~/Workspace\n~/Workspace/patch-courier",
                    "~/Workspace\n~/Workspace/patch-courier",
                    "~/Workspace\n~/Workspace/patch-courier"
                )
            )
            Text(LT("One path per line, or separate paths with commas.", "每行一个路径，或者用逗号分隔。", "1 行 1 パス、またはカンマ区切り。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var senderPolicyFormSections: some View {
        SettingsBlock(title: LT("Sender", "发件人", "送信者")) {
            LazyVGrid(columns: formColumns, alignment: .leading, spacing: 14) {
                FieldGroup(title: LT("Display name", "显示名称", "表示名")) {
                    TextField(LT("Primary Admin", "主管理员", "メイン管理者"), text: $senderPolicyDraft.displayName)
                        .textFieldStyle(.roundedBorder)
                }
                FieldGroup(title: LT("Sender address", "发件人地址", "送信者アドレス")) {
                    TextField("admin@example.com", text: $senderPolicyDraft.senderAddress)
                        .textFieldStyle(.roundedBorder)
                }
                FieldGroup(title: LT("Assigned role", "分配角色", "割り当てロール")) {
                    Picker(LT("Assigned role", "分配角色", "割り当てロール"), selection: $senderPolicyDraft.assignedRole) {
                        ForEach(MailboxRole.allCases) { role in
                            Text(role.title).tag(role)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
        }

        SettingsBlock(title: LT("Allowed workspaces", "允许的工作区", "許可ワークスペース")) {
            senderPolicyAllowedWorkspacesEditor
        }

        SettingsBlock(title: LT("Rules", "规则", "ルール")) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(
                    LT("Require first-mail confirmation", "要求首次来信确认", "初回メールの確認を必須にする"),
                    isOn: $senderPolicyDraft.requiresReplyToken
                )
                Toggle(
                    LT("Accept commands from this sender", "接受该发件人的命令", "この送信者からの指示を受け付ける"),
                    isOn: $senderPolicyDraft.isEnabled
                )
            }
        }
    }

    @ViewBuilder
    private func mailboxFormSections(
        editingAccount: ConfiguredMailboxAccount?,
        disableCoreFields: Bool
    ) -> some View {
        SettingsBlock(title: LT("Basic", "基础信息", "基本情報")) {
            LazyVGrid(columns: formColumns, alignment: .leading, spacing: 14) {
                FieldGroup(title: LT("Display label", "显示名称", "表示名")) {
                    TextField(LT("Tokyo Operator", "东京操作员", "東京オペレーター"), text: $draft.label)
                        .textFieldStyle(.roundedBorder)
                }
                FieldGroup(title: LT("Mailbox address", "邮箱地址", "メールアドレス")) {
                    TextField("codex-tokyo@example.com", text: $draft.emailAddress)
                        .textFieldStyle(.roundedBorder)
                }
                FieldGroup(title: LT("Role", "角色", "ロール")) {
                    Picker(LT("Role", "角色", "ロール"), selection: $draft.role) {
                        ForEach(MailboxRole.allCases) { role in
                            Text(role.title).tag(role)
                        }
                    }
                    .pickerStyle(.menu)
                }
                FieldGroup(title: LT("Workspace root", "工作区根目录", "ワークスペースルート")) {
                    FolderPathField(
                        path: $draft.workspaceRoot,
                        placeholder: "~/Workspace",
                        chooseLabel: LT("Choose folder", "选择文件夹", "フォルダを選択"),
                        status: workspaceRootStatus(for: draft.workspaceRoot)
                    ) {
                        chooseMailboxWorkspaceRoot()
                    }
                }
            }
            .disabled(disableCoreFields)
        }

        SettingsBlock(title: LT("Mail servers", "邮件服务器", "メールサーバー")) {
            LazyVGrid(columns: formColumns, alignment: .leading, spacing: 14) {
                FieldGroup(title: LT("IMAP host", "IMAP 主机", "IMAP ホスト")) {
                    TextField("imap.example.com", text: $draft.imapHost)
                        .textFieldStyle(.roundedBorder)
                }
                FieldGroup(title: LT("IMAP port", "IMAP 端口", "IMAP ポート")) {
                    TextField("993", text: $draft.imapPort)
                        .textFieldStyle(.roundedBorder)
                }
                FieldGroup(title: LT("IMAP security", "IMAP 安全性", "IMAP セキュリティ")) {
                    Picker(LT("IMAP security", "IMAP 安全性", "IMAP セキュリティ"), selection: $draft.imapSecurity) {
                        ForEach(MailTransportSecurity.allCases) { security in
                            Text(security.title).tag(security)
                        }
                    }
                    .pickerStyle(.menu)
                }
                FieldGroup(title: LT("SMTP host", "SMTP 主机", "SMTP ホスト")) {
                    TextField("smtp.example.com", text: $draft.smtpHost)
                        .textFieldStyle(.roundedBorder)
                }
                FieldGroup(title: LT("SMTP port", "SMTP 端口", "SMTP ポート")) {
                    TextField("465", text: $draft.smtpPort)
                        .textFieldStyle(.roundedBorder)
                }
                FieldGroup(title: LT("SMTP security", "SMTP 安全性", "SMTP セキュリティ")) {
                    Picker(LT("SMTP security", "SMTP 安全性", "SMTP セキュリティ"), selection: $draft.smtpSecurity) {
                        ForEach(MailTransportSecurity.allCases) { security in
                            Text(security.title).tag(security)
                        }
                    }
                    .pickerStyle(.menu)
                }
                FieldGroup(title: LT("Polling interval", "轮询间隔", "ポーリング間隔")) {
                    Stepper(value: $draft.pollingIntervalSeconds, in: 15...3600, step: 15) {
                        Text(LT("\(draft.pollingIntervalSeconds) seconds", "\(draft.pollingIntervalSeconds) 秒", "\(draft.pollingIntervalSeconds) 秒"))
                    }
                }
            }
            .disabled(disableCoreFields)
        }

        SettingsBlock(title: LT("App password", "应用密码", "アプリ用パスワード")) {
            SecureField(
                editingAccount == nil
                    ? LT("App password", "应用密码", "アプリ用パスワード")
                    : LT("New app password (optional)", "新应用密码（可选）", "新しいアプリ用パスワード（任意）"),
                text: $password
            )
            .textFieldStyle(.roundedBorder)
            .disabled(disableCoreFields)

            Text(
                editingAccount == nil
                    ? LT("A mailbox must pass connectivity testing before it can be saved.", "邮箱必须先通过连通性测试，才能保存。", "メールボックスは接続テストに成功してから保存される。")
                    : LT("Leave this blank to keep the saved Keychain password. Fill it only when you want to rotate the password.", "留空则继续使用 Keychain 里已保存的密码；只有在你想更新密码时才需要填写。", "空欄のままなら保存済み Keychain パスワードを使い続ける。パスワードを更新したいときだけ入力する。")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var receivingOverview: (value: String, detail: String, tint: Color) {
        guard let identityAccount = workspaceModel.identityAccount else {
            return (
                LT("Not ready", "未就绪", "未準備"),
                LT("Configure the local mailbox first", "先配置本机邮箱", "先にローカルメールを設定する"),
                .orange
            )
        }

        if !identityAccount.hasPasswordStored {
            return (
                LT("Paused", "已暂停", "一時停止"),
                LT("Save the app password", "先保存应用密码", "アプリ用パスワードを保存する"),
                .orange
            )
        }

        if let summary = latestProbeSummary, !summary.succeeded {
            return (
                LT("Connection issue", "连接异常", "接続エラー"),
                summary.failureDetails.joined(separator: " • "),
                .red
            )
        }

        if enabledSenderCount == 0 {
            return (
                LT("Waiting", "等待白名单", "許可リスト待ち"),
                LT("Add at least one sender rule", "至少添加一条白名单规则", "少なくとも 1 件の送信者ルールを追加する"),
                .orange
            )
        }

        return (
            LT("Ready", "已就绪", "準備完了"),
            LT("Will receive mail on the next polling cycle", "下一次轮询就会开始收信", "次のポーリングから受信する"),
            .green
        )
    }

    private var whitelistOverview: (value: String, detail: String, tint: Color) {
        let totalCount = workspaceModel.senderPolicies.count
        if totalCount == 0 {
            return (
                LT("Empty", "为空", "空"),
                LT("No sender can reach Codex yet", "目前还没有邮箱能进入 Codex", "まだ Codex に入れる送信者がいない"),
                .orange
            )
        }

        return (
            LT("\(enabledSenderCount) active", "\(enabledSenderCount) 个启用", "\(enabledSenderCount) 件有効"),
            LT("\(totalCount) total sender rules", "共 \(totalCount) 条发件人规则", "送信者ルール合計 \(totalCount) 件"),
            enabledSenderCount == 0 ? .orange : .green
        )
    }

    private var connectivityOverview: (value: String, detail: String, tint: Color) {
        guard let identityAccount = workspaceModel.identityAccount else {
            return (
                LT("No mailbox", "没有邮箱", "メール未設定"),
                LT("Configure the relay mailbox first", "先配置信使邮箱", "先に中継メールを設定する"),
                .orange
            )
        }

        if isProbing(identityAccount) {
            return (
                LT("Testing…", "测试中…", "テスト中…"),
                identityAccount.account.connectionSummary,
                .orange
            )
        }

        guard let summary = latestProbeSummary else {
            return (
                LT("Untested", "未测试", "未テスト"),
                identityAccount.account.connectionSummary,
                .orange
            )
        }

        if summary.succeeded {
            return (
                LT("Healthy", "正常", "正常"),
                identityAccount.account.connectionSummary,
                .green
            )
        }

        return (
            LT("Needs fix", "需处理", "要修正"),
            summary.failureDetails.joined(separator: " • "),
            .red
        )
    }

    private var latestProbeSummary: AccountProbeSummary? {
        guard let identityAccount = workspaceModel.identityAccount else {
            return nil
        }
        guard case .finished(let summary) = workspaceModel.probeStates[identityAccount.id] else {
            return nil
        }
        return summary
    }

    private func isProbing(_ account: ConfiguredMailboxAccount) -> Bool {
        if case .running = workspaceModel.probeStates[account.id] {
            return true
        }
        return false
    }

    private func probeButtonLabel(for account: ConfiguredMailboxAccount) -> String {
        if isProbing(account) {
            return LT("Testing…", "测试中…", "テスト中…")
        }
        return LT("Test connectivity", "测试连通性", "接続テスト")
    }

    private var saveButtonLabel: String {
        if workspaceModel.isSavingAccount {
            return LT("Testing…", "测试中…", "テスト中…")
        }
        return LT("Save relay mailbox", "保存信使邮箱", "中継メールを保存")
    }

    @discardableResult
    private func saveMailbox(editingAccount: ConfiguredMailboxAccount?) async -> Bool {
        if await workspaceModel.saveAccount(
            draft: draft,
            password: password,
            existingAccount: editingAccount
        ) {
            password = ""
            syncDraftFromIdentity(force: true)
            return true
        }
        return false
    }

    private func syncDraftFromIdentity(force: Bool) {
        guard force else {
            return
        }
        if let identityAccount = workspaceModel.identityAccount?.account {
            draft = .template(from: identityAccount)
        } else {
            draft = MailboxAccountDraft()
        }
        password = ""
    }

    private func syncSenderPolicySelection() {
        guard !workspaceModel.senderPolicies.isEmpty else {
            beginNewSenderPolicy()
            return
        }

        if let selectedPolicyID,
           let selectedPolicy = workspaceModel.senderPolicies.first(where: { $0.id == selectedPolicyID }) {
            senderPolicyDraft = .template(from: selectedPolicy)
            return
        }

        if let firstPolicy = workspaceModel.senderPolicies.first {
            selectPolicy(firstPolicy)
        }
    }

    private func beginNewSenderPolicy() {
        selectedPolicyID = nil
        senderPolicyDraft = SenderPolicyDraft()
    }

    private func selectPolicy(_ policy: SenderPolicy) {
        selectedPolicyID = policy.id
        senderPolicyDraft = .template(from: policy)
    }

    @discardableResult
    private func saveSelectedSenderPolicy() async -> Bool {
        let existingPolicy = selectedPolicy
        if let savedPolicy = await workspaceModel.saveSenderPolicy(draft: senderPolicyDraft, existingPolicy: existingPolicy) {
            selectPolicy(savedPolicy)
            return true
        }
        return false
    }

    private var mailboxDeletionTitle: String {
        LT("Remove mailbox?", "删除邮箱？", "メールを削除しますか？")
    }

    private var managedProjectDeletionTitle: String {
        LT("Remove managed project?", "删除受管项目？", "管理対象プロジェクトを削除しますか？")
    }

    private var senderDeletionTitle: String {
        LT("Delete sender rule?", "删除发件人规则？", "送信者ルールを削除しますか？")
    }

    @ViewBuilder
    private var mailboxEditorSheet: some View {
        let editingAccount = mailboxEditorAccount

        EditorSheetShell(
            title: editingAccount == nil
                ? LT("Add relay mailbox", "添加信使邮箱", "中継メールを追加")
                : LT("Edit relay mailbox", "编辑信使邮箱", "中継メールを編集"),
            subtitle: editingAccount == nil
                ? LT("The full mailbox form stays hidden until you explicitly open it.", "只有在你明确点击时，完整邮箱表单才会展开。", "完全なメールフォームは、明示的に開いたときだけ表示される。")
                : LT("Update mailbox details here, then close the sheet once the daemon accepts the change.", "在这里修改邮箱信息，daemon 接受后就可以直接关闭弹窗。", "ここでメール設定を更新し、daemon が受け入れたらそのままシートを閉じる。"),
            closeLabel: LT("Close", "关闭", "閉じる")
        ) {
            mailboxFormSections(
                editingAccount: editingAccount,
                disableCoreFields: false
            )
        } footer: {
            HStack(spacing: 12) {
                if editingAccount == nil {
                    Button(LT("Use example", "填入示例", "サンプルを使う")) {
                        draft = .example
                        password = ""
                    }
                    .buttonStyle(.bordered)
                }

                Spacer(minLength: 0)

                Button(
                    editingAccount == nil
                        ? saveButtonLabel
                        : (workspaceModel.isSavingAccount
                            ? LT("Testing…", "测试中…", "テスト中…")
                            : LT("Save changes", "保存修改", "変更を保存"))
                ) {
                    Task { @MainActor in
                        if await saveMailbox(editingAccount: editingAccount) {
                            isPresentingMailboxEditor = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(workspaceModel.isSavingAccount)
            }
        } onClose: {
            isPresentingMailboxEditor = false
        }
    }

    @ViewBuilder
    private var senderPolicyEditorSheet: some View {
        let policy = selectedPolicy

        EditorSheetShell(
            title: policy == nil
                ? LT("New sender rule", "新增发件人规则", "新しい送信者ルール")
                : LT("Edit sender rule", "编辑发件人规则", "送信者ルールを編集"),
            subtitle: policy == nil
                ? LT("Add only the senders you want to let into Codex.", "只添加你想放行到 Codex 的发件人。", "Codex に通したい送信者だけを追加する。")
                : LT("Adjust the sender rule here and keep the main settings page clean.", "在这里修改规则，让主设置页继续保持干净。", "ここでルールを調整し、メイン設定画面はすっきり保つ。"),
            closeLabel: LT("Close", "关闭", "閉じる")
        ) {
            senderPolicyFormSections
        } footer: {
            HStack(spacing: 12) {
                if policy == nil {
                    Button(LT("Admin example", "管理员示例", "管理者サンプル")) {
                        senderPolicyDraft = .exampleAdmin
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button(LT("Revert", "恢复", "元に戻す")) {
                        if let policy {
                            senderPolicyDraft = .template(from: policy)
                        }
                    }
                    .buttonStyle(.bordered)
                }

                Spacer(minLength: 0)

                Button(policy == nil ? LT("Save sender", "保存发件人", "送信者を保存") : LT("Save changes", "保存修改", "変更を保存")) {
                    Task { @MainActor in
                        if await saveSelectedSenderPolicy() {
                            isPresentingSenderPolicyEditor = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        } onClose: {
            isPresentingSenderPolicyEditor = false
        }
    }

    @ViewBuilder
    private var managedProjectEditorSheet: some View {
        let project = managedProjectEditorProject

        EditorSheetShell(
            title: project == nil
                ? LT("Add managed project", "添加受管项目", "管理対象プロジェクトを追加")
                : LT("Edit managed project", "编辑受管项目", "管理対象プロジェクトを編集"),
            subtitle: project == nil
                ? LT("These projects are what Mailroom sends back to whitelist admins and operators in the first probe reply.", "这些项目会在首次探针回信里返回给白名单管理员和操作员。", "これらのプロジェクトは、最初のプローブ返信で許可済み admin / operator へ返される。")
                : LT("Update the project label, slug, root path, and default capability here.", "在这里调整项目名称、短名、根目录和默认能力。", "ここでプロジェクト名、slug、ルート、既定権限を調整する。"),
            closeLabel: LT("Close", "关闭", "閉じる")
        ) {
            SettingsBlock(title: LT("Project", "项目", "プロジェクト")) {
                LazyVGrid(columns: formColumns, alignment: .leading, spacing: 14) {
                    FieldGroup(title: LT("Display name", "显示名称", "表示名")) {
                        TextField("Patch Courier", text: $managedProjectDraft.displayName)
                            .textFieldStyle(.roundedBorder)
                    }
                    FieldGroup(title: LT("Reply slug", "回信短名", "返信 slug")) {
                        TextField("patch-courier", text: $managedProjectDraft.slug)
                            .textFieldStyle(.roundedBorder)
                    }
                    FieldGroup(title: LT("Root path", "根目录", "ルートパス")) {
                        FolderPathField(
                            path: $managedProjectDraft.rootPath,
                            placeholder: "~/Workspace/patch-courier",
                            chooseLabel: LT("Choose folder", "选择文件夹", "フォルダを選択"),
                            status: managedProjectRootStatus(for: managedProjectDraft.rootPath)
                        ) {
                            chooseManagedProjectRoot()
                        }
                    }
                    FieldGroup(title: LT("Default capability", "默认能力", "既定権限")) {
                        Picker(LT("Default capability", "默认能力", "既定権限"), selection: $managedProjectDraft.defaultCapability) {
                            ForEach(projectCapabilityOptions, id: \.id) { capability in
                                Text(capability.title).tag(capability)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
            }

            SettingsBlock(title: LT("Reply hint", "回信提示", "返信ヒント")) {
                MultiLineInsetEditor(
                    text: $managedProjectDraft.summary,
                    placeholder: LT(
                        "Native macOS relay app and daemon.",
                        "例如：原生 macOS 信使应用与 daemon。",
                        "例: ネイティブ macOS 中継アプリと daemon。"
                    )
                )
                Text(
                    LT(
                        "Shown in the project list email so the human knows what this repo is for.",
                        "会显示在项目列表邮件里，帮助人类快速识别这个项目是干什么的。",
                        "プロジェクト一覧メール内に表示され、人が用途をすぐ判断できるようにする。"
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            SettingsBlock(title: LT("Availability", "可用性", "利用可否")) {
                Toggle(
                    LT("Offer this project in probe replies", "在探针回信里提供这个项目", "プローブ返信でこのプロジェクトを提示する"),
                    isOn: $managedProjectDraft.isEnabled
                )
            }
        } footer: {
            HStack(spacing: 12) {
                if project == nil {
                    Button(LT("Use example", "填入示例", "サンプルを使う")) {
                        managedProjectDraft = .example
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button(LT("Revert", "恢复", "元に戻す")) {
                        if let project {
                            managedProjectDraft = .template(from: project)
                        }
                    }
                    .buttonStyle(.bordered)
                }

                Spacer(minLength: 0)

                Button(project == nil ? LT("Save project", "保存项目", "プロジェクトを保存") : LT("Save changes", "保存修改", "変更を保存")) {
                    Task { @MainActor in
                        if await workspaceModel.saveManagedProject(
                            draft: managedProjectDraft,
                            existingProject: project
                        ) != nil {
                            isPresentingManagedProjectEditor = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        } onClose: {
            isPresentingManagedProjectEditor = false
        }
    }

    private func openMailboxEditor(for account: ConfiguredMailboxAccount?) {
        mailboxEditorAccountID = account?.id
        if let account {
            draft = .template(from: account.account)
        } else {
            draft = MailboxAccountDraft()
        }
        password = ""
        isPresentingMailboxEditor = true
    }

    private func beginManagedProjectCreation() {
        managedProjectEditorProjectID = nil
        managedProjectDraft = ManagedProjectDraft()

        guard let selectedFolder = pickDirectory(
            startingAt: managedProjectDraft.rootPath,
            message: LT(
                "Select the local project folder Mailroom should manage.",
                "选择 Mailroom 要管理的本地项目文件夹。",
                "Mailroom が管理するローカルプロジェクトのフォルダを選択する。"
            )
        ) else {
            return
        }

        applyManagedProjectSelection(selectedFolder, overwriteMetadata: true)
        isPresentingManagedProjectEditor = true
    }

    private func openManagedProjectEditor(for project: ManagedProject?) {
        managedProjectEditorProjectID = project?.id
        if let project {
            managedProjectDraft = .template(from: project)
        } else {
            managedProjectDraft = ManagedProjectDraft()
        }
        isPresentingManagedProjectEditor = true
    }

    private func chooseManagedProjectRoot() {
        guard let selectedFolder = pickDirectory(
            startingAt: managedProjectDraft.rootPath,
            message: LT(
                "Select the local project folder Mailroom should manage.",
                "选择 Mailroom 要管理的本地项目文件夹。",
                "Mailroom が管理するローカルプロジェクトのフォルダを選択する。"
            )
        ) else {
            return
        }

        applyManagedProjectSelection(selectedFolder, overwriteMetadata: false)
    }

    private func chooseMailboxWorkspaceRoot() {
        guard let selectedFolder = pickDirectory(
            startingAt: draft.workspaceRoot,
            message: LT(
                "Select the default workspace root this mailbox can use for Codex tasks.",
                "选择这个信使邮箱可用于 Codex 任务的默认工作区根目录。",
                "この中継メールが Codex タスクで使う既定のワークスペースルートを選択する。"
            )
        ) else {
            return
        }

        draft.workspaceRoot = selectedFolder.standardizedFileURL.path
    }

    private func choosePolicyPreviewWorkspaceRoot() {
        guard let selectedFolder = pickDirectory(
            startingAt: policyPreview.workspaceRoot,
            message: LT(
                "Select a workspace root to preview routing and approval behavior.",
                "选择一个工作区根目录，用于预览路由和审批行为。",
                "ルーティングと承認挙動をプレビューするワークスペースルートを選択する。"
            )
        ) else {
            return
        }

        policyPreview.workspaceRoot = selectedFolder.standardizedFileURL.path
    }

    private func chooseSenderPolicyWorkspaceRoot() {
        guard let selectedFolder = pickDirectory(
            startingAt: senderPolicyWorkspaceRoots.last ?? "",
            message: LT(
                "Select a workspace root this sender is allowed to access.",
                "选择这个发件人允许访问的工作区根目录。",
                "この送信者に許可するワークスペースルートを選択する。"
            )
        ) else {
            return
        }

        addSenderPolicyWorkspaceRoot(selectedFolder.standardizedFileURL.path)
    }

    private func addSenderPolicyWorkspaceRoot(_ path: String) {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return
        }

        let standardizedPath = standardizedDirectoryPath(from: trimmedPath) ?? trimmedPath
        let normalizedPath = normalizedDirectoryPath(standardizedPath) ?? standardizedPath.lowercased()

        var roots = senderPolicyWorkspaceRoots
        if roots.contains(where: { (normalizedDirectoryPath($0) ?? $0.lowercased()) == normalizedPath }) {
            return
        }

        roots.append(standardizedPath)
        senderPolicyDraft.workspaceRootsText = SenderPolicyDraft.workspaceRootsText(from: roots)
    }

    private func removeSenderPolicyWorkspaceRoot(_ path: String) {
        let normalizedPath = normalizedDirectoryPath(path) ?? path.lowercased()
        let roots = senderPolicyWorkspaceRoots.filter {
            (normalizedDirectoryPath($0) ?? $0.lowercased()) != normalizedPath
        }
        senderPolicyDraft.workspaceRootsText = SenderPolicyDraft.workspaceRootsText(from: roots)
    }

    private func applyManagedProjectSelection(_ folderURL: URL, overwriteMetadata: Bool) {
        let previousFolderName = managedProjectFolderName(from: managedProjectDraft.rootPath)
        let standardizedPath = folderURL.standardizedFileURL.path
        let folderName = folderURL.lastPathComponent
        let suggestedDisplayName = suggestedManagedProjectDisplayName(from: folderName)
        let suggestedSlug = suggestedManagedProjectSlug(from: folderName)
        let shouldOverwriteDisplayName = overwriteMetadata || shouldOverwriteManagedProjectMetadata(
            managedProjectDraft.displayName,
            previousSuggestedValue: previousFolderName.map(suggestedManagedProjectDisplayName(from:))
        )
        let shouldOverwriteSlug = overwriteMetadata || shouldOverwriteManagedProjectMetadata(
            managedProjectDraft.slug,
            previousSuggestedValue: previousFolderName.map(suggestedManagedProjectSlug(from:))
        )

        managedProjectDraft.rootPath = standardizedPath

        if shouldOverwriteDisplayName {
            managedProjectDraft.displayName = suggestedDisplayName
        }

        if shouldOverwriteSlug {
            managedProjectDraft.slug = suggestedSlug
        }
    }

    private func managedProjectFolderName(from path: String) -> String? {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: (trimmedPath as NSString).expandingTildeInPath)
            .standardizedFileURL
            .lastPathComponent
    }

    private func shouldOverwriteManagedProjectMetadata(_ currentValue: String, previousSuggestedValue: String?) -> Bool {
        let trimmedValue = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return true
        }

        guard let previousSuggestedValue else {
            return false
        }

        return trimmedValue == previousSuggestedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func suggestedManagedProjectDisplayName(from folderName: String) -> String {
        let words = folderName
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)

        guard !words.isEmpty else {
            return folderName
        }

        return words
            .map { String($0).localizedCapitalized }
            .joined(separator: " ")
    }

    private func suggestedManagedProjectSlug(from folderName: String) -> String {
        ManagedProjectDraft.normalizedSlugCandidate(from: folderName)
    }

    private func workspaceRootStatus(for path: String) -> DirectoryFieldStatus? {
        directoryFieldStatus(for: path)
    }

    private func managedProjectRootStatus(for path: String) -> DirectoryFieldStatus? {
        directoryFieldStatus(for: path, conflictingProject: conflictingManagedProject(for: path))
    }

    private func conflictingManagedProject(for path: String) -> ManagedProject? {
        guard let normalizedPath = normalizedDirectoryPath(path) else {
            return nil
        }

        return workspaceModel.managedProjects.first { project in
            project.id != managedProjectEditorProjectID && normalizedDirectoryPath(project.rootPath) == normalizedPath
        }
    }

    private func directoryFieldStatus(for path: String, conflictingProject: ManagedProject? = nil) -> DirectoryFieldStatus? {
        guard let standardizedPath = standardizedDirectoryPath(from: path) else {
            return nil
        }

        if let conflictingProject {
            return DirectoryFieldStatus(
                label: LT("Already managed", "已被管理", "管理済み"),
                detail: conflictingProject.displayName,
                tint: .orange,
                systemImage: "exclamationmark.triangle.fill"
            )
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: standardizedPath, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                return DirectoryFieldStatus(
                    label: LT("Directory exists", "目录存在", "フォルダあり"),
                    detail: nil,
                    tint: .green,
                    systemImage: "checkmark.circle.fill"
                )
            }

            return DirectoryFieldStatus(
                label: LT("Not a folder", "不是文件夹", "フォルダではない"),
                detail: nil,
                tint: .red,
                systemImage: "xmark.octagon.fill"
            )
        }

        return DirectoryFieldStatus(
            label: LT("Directory missing", "目录不存在", "フォルダなし"),
            detail: nil,
            tint: .red,
            systemImage: "xmark.circle.fill"
        )
    }

    private func standardizedDirectoryPath(from path: String) -> String? {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: (trimmedPath as NSString).expandingTildeInPath)
            .standardizedFileURL
            .path
    }

    private func normalizedDirectoryPath(_ path: String) -> String? {
        standardizedDirectoryPath(from: path)?.lowercased()
    }

    private func pickerDirectoryURL(startingAt path: String) -> URL? {
        for candidatePath in [path, lastPickedDirectory] {
            guard let standardizedPath = standardizedDirectoryPath(from: candidatePath) else {
                continue
            }

            let candidateURL = URL(fileURLWithPath: standardizedPath, isDirectory: true)
            let directoryURL = FileManager.default.fileExists(atPath: candidateURL.path)
                ? candidateURL
                : candidateURL.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: directoryURL.path) {
                return directoryURL
            }
        }

        return nil
    }

    private func pickDirectory(startingAt path: String, message: String) -> URL? {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = LT("Choose", "选择", "選択")
        panel.message = message

        if let directoryURL = pickerDirectoryURL(startingAt: path) {
            panel.directoryURL = directoryURL
        }

        guard panel.runModal() == .OK else {
            return nil
        }
        guard let selectedURL = panel.url?.standardizedFileURL else {
            return nil
        }
        lastPickedDirectory = selectedURL.path
        return selectedURL
        #else
        return nil
        #endif
    }

    private func mailboxHealthStateLabel(_ state: String) -> String {
        switch state {
        case "healthy":
            return LT("Healthy", "正常", "正常")
        case "bootstrapped":
            return LT("Bootstrapped", "已建立游标", "初期化済み")
        case "polling":
            return LT("Polling", "轮询中", "ポーリング中")
        case "failed":
            return LT("Failed", "失败", "失敗")
        case "paused":
            return LT("Paused", "已暂停", "一時停止")
        default:
            return LT("Waiting", "等待中", "待機中")
        }
    }

    private func mailboxHealthTint(_ state: String) -> Color {
        switch state {
        case "healthy", "bootstrapped":
            return .green
        case "polling":
            return .blue
        case "failed":
            return .red
        case "paused":
            return .orange
        default:
            return .gray
        }
    }

    @ViewBuilder
    private func compactProbeSummary(_ summary: AccountProbeSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                StatusBadge(
                    label: summary.imapOK ? LT("IMAP OK", "IMAP 正常", "IMAP 正常") : LT("IMAP failed", "IMAP 失败", "IMAP 失敗"),
                    tint: summary.imapOK ? .green : .red
                )
                StatusBadge(
                    label: summary.smtpOK ? LT("SMTP OK", "SMTP 正常", "SMTP 正常") : LT("SMTP failed", "SMTP 失败", "SMTP 失敗"),
                    tint: summary.smtpOK ? .green : .red
                )
            }

            if let detail = summary.imapDetail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
                Text(LT("IMAP: \(detail)", "IMAP：\(detail)", "IMAP: \(detail)"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let detail = summary.smtpDetail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
                Text(LT("SMTP: \(detail)", "SMTP：\(detail)", "SMTP: \(detail)"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(cardInsetBackground)
    }

    @ViewBuilder
    private func receptionStatusView(for account: ConfiguredMailboxAccount) -> some View {
        if !account.hasPasswordStored {
            InlineBanner(
                label: LT(
                    "Inbox polling is paused until this mailbox has a saved app password.",
                    "在为这个邮箱保存应用密码之前，收件轮询会保持暂停。",
                    "このメールボックスに保存済みのアプリ用パスワードが入るまで、受信ポーリングは停止したままになる。"
                ),
                tint: .orange
            )
        } else if enabledSenderCount == 0 {
            InlineBanner(
                label: LT(
                    "Inbox polling is active, but no authorized sender is enabled yet. New mail will be ignored until you add one.",
                    "收件轮询已经启动，但还没有启用任何授权发件人。在添加白名单之前，新邮件会被忽略。",
                    "受信ポーリングは動作中だが、有効な許可済み送信者がまだいない。許可リストを追加するまでは新着メールを無視する。"
                ),
                tint: .orange
            )
        } else {
            InlineBanner(
                label: LT(
                    "Ready to receive new mail from authorized senders on the next polling cycle.",
                    "已准备好在下一次轮询时接收来自授权发件人的新邮件。",
                    "次のポーリング周期で、許可済み送信者からの新着メールを受信できる状態になっている。"
                ),
                tint: .green
            )
        }
    }

    @ViewBuilder
    private func probeResultView(for account: ConfiguredMailboxAccount) -> some View {
        switch workspaceModel.probeStates[account.id] {
        case .none:
            EmptyView()
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(LT("Contacting IMAP and SMTP…", "正在连接 IMAP 和 SMTP…", "IMAP と SMTP に接続中…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .finished(let summary):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    StatusBadge(
                        label: summary.imapOK ? LT("IMAP OK", "IMAP 正常", "IMAP 正常") : LT("IMAP failed", "IMAP 失败", "IMAP 失敗"),
                        tint: summary.imapOK ? .green : .red
                    )
                    StatusBadge(
                        label: summary.smtpOK ? LT("SMTP OK", "SMTP 正常", "SMTP 正常") : LT("SMTP failed", "SMTP 失败", "SMTP 失敗"),
                        tint: summary.smtpOK ? .green : .red
                    )
                }

                if let detail = summary.imapDetail, !detail.isEmpty {
                    Text(LT("IMAP: \(detail)", "IMAP：\(detail)", "IMAP: \(detail)"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let detail = summary.smtpDetail, !detail.isEmpty {
                    Text(LT("SMTP: \(detail)", "SMTP：\(detail)", "SMTP: \(detail)"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func executionButtons(for decision: MailPolicyDecision) -> some View {
        switch decision.requirement {
        case .automatic:
            HStack(spacing: 12) {
                Button(LT("Run via Codex", "通过 Codex 执行", "Codex で実行")) {
                    workspaceModel.submitPreviewRequest(policyPreview, assumeReviewApproved: false)
                }
                .buttonStyle(.borderedProminent)
                .disabled(workspaceModel.isRunningCodex || !workspaceModel.canRunCodexLocally)
            }

        case .adminReview:
            HStack(spacing: 12) {
                Button(LT("Queue review", "进入审批队列", "レビュー待ちへ送る")) {
                    workspaceModel.submitPreviewRequest(policyPreview, assumeReviewApproved: false)
                }
                .buttonStyle(.bordered)
                .disabled(workspaceModel.isRunningCodex)

                Button(LT("Approve & run", "批准并执行", "承認して実行")) {
                    workspaceModel.submitPreviewRequest(policyPreview, assumeReviewApproved: true)
                }
                .buttonStyle(.borderedProminent)
                .disabled(workspaceModel.isRunningCodex || !workspaceModel.canRunCodexLocally)
            }

        case .denied:
            HStack(spacing: 12) {
                Button(LT("Record rejection", "记录拒绝结果", "拒否を記録")) {
                    workspaceModel.submitPreviewRequest(policyPreview, assumeReviewApproved: false)
                }
                .buttonStyle(.bordered)
                .disabled(workspaceModel.isRunningCodex)
            }
        }
    }

    @ViewBuilder
    private var statusBanners: some View {
        if case .unavailable(let detail) = workspaceModel.daemonConnectionState {
            InlineBanner(
                label: LT(
                    "Daemon control is offline. The app will try to launch it automatically; if it still does not recover, restart it from the dashboard. \(detail)",
                    "daemon 控制平面当前离线。app 会尝试自动拉起；如果还没恢复，请去 dashboard 里重启它。\(detail)",
                    "daemon 制御プレーンは現在オフラインです。アプリが自動起動を試みるが、戻らない場合はダッシュボードから再起動してください。\(detail)"
                ),
                tint: .orange
            )
        }
        if let errorMessage = workspaceModel.errorMessage {
            InlineBanner(label: errorMessage, tint: .red)
        }
        if let statusMessage = workspaceModel.statusMessage {
            InlineBanner(label: statusMessage, tint: .green)
        }
    }

    private func policySummaryRow(_ policy: SenderPolicy) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(policy.displayName)
                    .font(.headline)
                Text(policy.senderAddress)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 8) {
                StatusBadge(label: policy.assignedRole.title, tint: .blue)
                StatusBadge(
                    label: policy.isEnabled ? LT("Enabled", "已启用", "有効") : LT("Disabled", "已禁用", "無効"),
                    tint: policy.isEnabled ? .green : .gray
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(cardInsetBackground)
    }

    private var cardInsetBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.white.opacity(0.72))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            )
    }

    private var formColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
    }

    private var overviewColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 170), spacing: 14)]
    }

    private var projectCapabilityOptions: [MailCapability] {
        [.readOnly, .writeWorkspace, .executeShell, .networkedAccess]
    }

    private func color(for status: MailJobStatus) -> Color {
        switch status {
        case .received, .accepted:
            return .blue
        case .running:
            return .orange
        case .waiting:
            return .yellow
        case .succeeded:
            return .green
        case .failed, .rejected:
            return .red
        }
    }

    private func color(for requirement: ApprovalRequirement) -> Color {
        switch requirement {
        case .automatic:
            return .green
        case .adminReview:
            return .orange
        case .denied:
            return .red
        }
    }
}

private struct SetupCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let icon: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(tint.opacity(0.14))
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(tint)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            content
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color.white.opacity(0.46))
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.04), radius: 18, x: 0, y: 8)
        )
    }
}

private struct SettingsBlock<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.68))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                )
        )
    }
}

private struct OverviewTile: View {
    let title: String
    let value: String
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Circle()
                    .fill(tint)
                    .frame(width: 10, height: 10)
            }

            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color(red: 0.13, green: 0.16, blue: 0.21))

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                )
        )
    }
}

private struct CompactInfoTile: View {
    let title: String
    let value: String
    var monospaced: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .subheadline.monospaced() : .subheadline)
                .foregroundStyle(Color(red: 0.13, green: 0.16, blue: 0.21))
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                )
        )
    }
}

private struct SenderPolicyListRow: View {
    let policy: SenderPolicy
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(policy.displayName)
                        .font(.headline)
                        .foregroundStyle(Color(red: 0.13, green: 0.16, blue: 0.21))
                        .lineLimit(1)
                    Text(policy.senderAddress)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                StatusBadge(
                    label: policy.isEnabled ? LT("On", "开", "オン") : LT("Off", "关", "オフ"),
                    tint: policy.isEnabled ? .green : .gray
                )
            }

            Text(policy.workspaceSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 8) {
                StatusBadge(label: policy.assignedRole.title, tint: .blue)
                if policy.requiresReplyToken {
                    StatusBadge(label: LT("First-mail confirm", "需首封确认", "初回確認"), tint: .orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(isSelected ? Color(red: 0.90, green: 0.95, blue: 1.0) : Color.white.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(isSelected ? Color(red: 0.31, green: 0.48, blue: 0.68) : Color.black.opacity(0.05), lineWidth: 1)
                )
        )
    }
}

private struct EditorSheetShell<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String
    let closeLabel: String
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title2.weight(.semibold))

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button(closeLabel) {
                    onClose()
                }
                .buttonStyle(.bordered)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content
                }
                .padding(.vertical, 2)
            }

            footer
        }
        .padding(24)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.94, blue: 0.91),
                    Color(red: 0.93, green: 0.95, blue: 0.97)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

private struct MultiLineInsetEditor: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(placeholder)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
            }

            TextEditor(text: $text)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 104)
                .background(Color.clear)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DirectoryFieldStatus {
    let label: String
    let detail: String?
    let tint: Color
    let systemImage: String
}

private struct FolderPathField: View {
    @Binding var path: String
    let placeholder: String
    let chooseLabel: String
    let status: DirectoryFieldStatus?
    let chooseAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField(placeholder, text: $path)
                    .textFieldStyle(.roundedBorder)

                Button(chooseLabel) {
                    chooseAction()
                }
                .buttonStyle(.bordered)
            }

            if let status {
                HStack(spacing: 8) {
                    Image(systemName: status.systemImage)
                        .font(.caption.weight(.semibold))
                    Text(status.label)
                        .font(.caption.weight(.semibold))
                    if let detail = status.detail, !detail.isEmpty {
                        Text("· \(detail)")
                            .font(.caption)
                    }
                }
                .foregroundStyle(status.tint)
            }
        }
    }
}

private struct AllowedWorkspacePathRow: View {
    let path: String
    let status: DirectoryFieldStatus?
    let removeLabel: String
    let removeAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(Color(red: 0.13, green: 0.16, blue: 0.21))
                    .textSelection(.enabled)

                if let status {
                    HStack(spacing: 8) {
                        Image(systemName: status.systemImage)
                            .font(.caption.weight(.semibold))
                        Text(status.label)
                            .font(.caption.weight(.semibold))
                        if let detail = status.detail, !detail.isEmpty {
                            Text("· \(detail)")
                                .font(.caption)
                        }
                    }
                    .foregroundStyle(status.tint)
                }
            }

            Spacer(minLength: 0)

            Button(removeLabel, role: .destructive) {
                removeAction()
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                )
        )
    }
}

private struct FieldGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            content
        }
    }
}

private struct InlineBanner: View {
    let label: String
    let tint: Color

    var body: some View {
        Text(label)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(tint.opacity(0.2), lineWidth: 1)
            )
    }
}

private struct StatusBadge: View {
    let label: String
    let tint: Color

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(tint.opacity(0.25), lineWidth: 1)
            )
    }
}

private struct EmptyStateView: View {
    let title: String
    let message: String?
    let icon: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                if let message, !message.isEmpty {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )
        )
    }
}
