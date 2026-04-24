import SwiftUI

private enum OperatorSettingsPane: String, CaseIterable, Identifiable {
    case runtime
    case mailboxes
    case projects
    case whitelist

    var id: String { rawValue }

    var title: String {
        switch self {
        case .runtime:
            return LT("Runtime", "运行状态", "ランタイム")
        case .mailboxes:
            return LT("Relay", "信使邮箱", "中継メール")
        case .projects:
            return LT("Projects", "项目", "プロジェクト")
        case .whitelist:
            return LT("Whitelist", "邮箱白名单", "許可リスト")
        }
    }

    var systemImage: String {
        switch self {
        case .runtime:
            return "bolt.horizontal.circle"
        case .mailboxes:
            return "tray.full"
        case .projects:
            return "folder.badge.gearshape"
        case .whitelist:
            return "person.crop.rectangle.badge.checkmark"
        }
    }
}

struct DashboardView: View {
    @ObservedObject var workspaceModel: MailroomWorkspaceModel
    @State private var isShowingSettings = false
    @State private var activeAlert: OperatorFeedbackAlert?
    @State private var selectedMailPanelItemID: String?
    @State private var settingsInitialPane: OperatorSettingsPane = .runtime

    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.95, green: 0.94, blue: 0.91),
                Color(red: 0.93, green: 0.95, blue: 0.97)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var dashboardSections: some View {
        MailDeskSection(
            workspaceModel: workspaceModel,
            selectedItemID: $selectedMailPanelItemID
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var toolbarIdentityLabel: String {
        workspaceModel.identityAccount?.account.emailAddress ?? LT(
            "Codex messenger mailbox not set",
            "Codex 信使邮箱未配置",
            "Codex 中継メール未設定"
        )
    }

    private var toolbarRuntimeLabel: String {
        switch workspaceModel.daemonRuntimeStatus.lifecycle {
        case .discovering:
            return LT("后台检查中", "后台检查中", "バックグラウンド確認中")
        case .ready:
            return LT("后台待启动", "后台待启动", "バックグラウンド待機")
        case .starting:
            return LT("后台启动中", "后台启动中", "バックグラウンド起動中")
        case .running:
            return workspaceModel.daemonRuntimeStatus.isLaunchAgentLoaded
                ? LT("后台运行中", "后台运行中", "バックグラウンド稼働中")
                : LT("运行中", "运行中", "稼働中")
        case .stopping:
            return LT("后台停止中", "后台停止中", "バックグラウンド停止中")
        case .failed:
            return LT("后台需处理", "后台需处理", "バックグラウンド要対応")
        }
    }

    private var toolbarRuntimeHelp: String {
        let residentLine = workspaceModel.daemonRuntimeStatus.isLaunchAgentInstalled
            ? LT("Resident background service is installed.", "后台常驻服务已安装。", "常駐バックグラウンドサービスは登録済み。")
            : LT("Resident background service is not installed yet.", "后台常驻服务还没安装。", "常駐バックグラウンドサービスはまだ未注册。")
        return "\(toolbarIdentityLabel)\n\(toolbarRuntimeLabel)\n\(residentLine)"
    }

    private var toolbarRuntimeTint: Color {
        switch workspaceModel.daemonRuntimeStatus.lifecycle {
        case .discovering, .starting, .stopping:
            return .orange
        case .ready:
            return Color(red: 0.30, green: 0.47, blue: 0.69)
        case .running:
            return .green
        case .failed:
            return .red
        }
    }

    private func openSettings(_ pane: OperatorSettingsPane = .runtime) {
        settingsInitialPane = pane
        isShowingSettings = true
    }

    private func refreshWorkspace() {
        Task { await workspaceModel.refreshMailDesk() }
    }

    @ToolbarContentBuilder
    private var dashboardToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            DashboardToolbarStatusPill(
                label: toolbarRuntimeLabel,
                tint: toolbarRuntimeTint
            )
            .help(toolbarRuntimeHelp)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                refreshWorkspace()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(LT("Refresh mailbox and daemon state", "刷新邮件和 daemon 状态", "メールと daemon 状態を更新"))

            Button {
                openSettings(.runtime)
            } label: {
                Image(systemName: "gearshape")
            }
            .help(LT("Settings", "设置", "設定"))
        }
    }

    private var dashboardContent: some View {
        dashboardSections
            .background(background)
            .navigationTitle(LT("Patch Courier", "Patch Courier", "Patch Courier"))
            .toolbar { dashboardToolbar }
            .sheet(isPresented: $isShowingSettings) {
                SettingsSheetView(
                    workspaceModel: workspaceModel,
                    initialPane: settingsInitialPane
                )
                    .frame(minWidth: 980, minHeight: 700)
            }
            .alert(item: $activeAlert, content: makeAlert)
            .task {
                await loadDashboard()
            }
            .onChange(of: workspaceModel.errorMessage) {
                handleErrorMessageChange()
            }
            .onChange(of: workspaceModel.statusMessage) {
                handleStatusMessageChange()
            }
            .refreshable {
                await workspaceModel.refreshMailDesk()
            }
    }

    var body: some View {
        NavigationStack {
            dashboardContent
        }
    }

    private func makeAlert(_ alert: OperatorFeedbackAlert) -> Alert {
        Alert(
            title: Text(alert.title),
            message: Text(alert.message),
            dismissButton: .default(Text(LT("OK", "好的", "OK")))
        )
    }

    private func loadDashboard() async {
        workspaceModel.loadIfNeeded()
        await workspaceModel.refreshMailDesk()
    }

    private func handleErrorMessageChange() {
        guard !isShowingSettings,
              let message = workspaceModel.errorMessage.trimmedNonEmpty else {
            return
        }
        activeAlert = OperatorFeedbackAlert(
            title: LT("Needs attention", "需要注意", "要対応"),
            message: message
        )
    }

    private func handleStatusMessageChange() {
        guard !isShowingSettings,
              let message = workspaceModel.statusMessage.trimmedNonEmpty else {
            return
        }
        activeAlert = OperatorFeedbackAlert(
            title: LT("Done", "完成", "完了"),
            message: message
        )
    }
}

private struct OperatorFeedbackAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct DaemonOverviewSection: View {
    @ObservedObject var workspaceModel: MailroomWorkspaceModel
    let isShowingDiagnostics: Bool
    let onRefresh: () -> Void
    let onStartDaemon: () -> Void
    let onStopDaemon: () -> Void
    let onRestartDaemon: () -> Void
    let onToggleDiagnostics: () -> Void

    var body: some View {
        SectionSurface {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(primaryTitle)
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(red: 0.13, green: 0.16, blue: 0.21))

                        Text(secondaryTitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 20)

                    HStack(spacing: 10) {
                        Button(LT("Refresh", "刷新", "更新"), action: onRefresh)
                            .buttonStyle(.bordered)
                        Button(primaryDaemonActionTitle, action: primaryDaemonAction)
                            .buttonStyle(.bordered)
                            .disabled(!workspaceModel.canStartDaemon)
                        if workspaceModel.daemonRuntimeStatus.lifecycle == .running {
                            Button(LT("Stop", "停止", "停止"), action: onStopDaemon)
                                .buttonStyle(.bordered)
                                .disabled(!workspaceModel.canStartDaemon)
                        }
                        Button(
                            isShowingDiagnostics
                                ? LT("Hide details", "收起详情", "詳細を隠す")
                                : LT("Show details", "展开详情", "詳細を表示")
                        ) {
                            onToggleDiagnostics()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        statusPills
                        Spacer(minLength: 0)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            statusPills
                        }
                    }
                }

                if !workspaceModel.isDaemonConnected {
                    Text(compactOfflineLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var statusPills: some View {
        MessagePill(label: connectionLabel, tint: connectionTint)
        MessagePill(label: daemonLifecycleLabel, tint: daemonLifecycleTint)
        if let identityAccount = workspaceModel.identityAccount {
            MessagePill(label: identityAccount.account.emailAddress, tint: Color(red: 0.19, green: 0.31, blue: 0.56))
        }
        MessagePill(
            label: LT(
                "\(workspaceModel.pendingApprovals.count) approvals",
                "\(workspaceModel.pendingApprovals.count) 个待审批",
                "承認待ち \(workspaceModel.pendingApprovals.count) 件"
            ),
            tint: workspaceModel.pendingApprovals.isEmpty ? .green : .orange
        )
        MessagePill(
            label: LT(
                "\(workspaceModel.daemonSnapshot?.activeWorkerKeys.count ?? 0) workers",
                "\(workspaceModel.daemonSnapshot?.activeWorkerKeys.count ?? 0) 个 worker",
                "worker \(workspaceModel.daemonSnapshot?.activeWorkerKeys.count ?? 0) 件"
            ),
            tint: Color(red: 0.16, green: 0.44, blue: 0.34)
        )
        MessagePill(
            label: LT(
                "\(workspaceModel.daemonSnapshot?.queuedWorkItemCount ?? 0) queued",
                "\(workspaceModel.daemonSnapshot?.queuedWorkItemCount ?? 0) 封排队",
                "キュー \(workspaceModel.daemonSnapshot?.queuedWorkItemCount ?? 0) 件"
            ),
            tint: Color(red: 0.45, green: 0.31, blue: 0.13)
        )
    }

    private var primaryTitle: String {
        if let identityAccount = workspaceModel.identityAccount {
            return identityAccount.account.emailAddress
        }
        return LT("Codex messenger mailbox is not set", "Codex 信使邮箱还没配置", "Codex 中継メールは未設定")
    }

    private var secondaryTitle: String {
        if let snapshot = workspaceModel.daemonSnapshot {
            return LT(
                "Updated \(snapshot.generatedAt.formatted(date: .omitted, time: .shortened)) · \(workspaceModel.daemonMailboxHealth.count) mailbox lanes",
                "更新于 \(snapshot.generatedAt.formatted(date: .omitted, time: .shortened)) · \(workspaceModel.daemonMailboxHealth.count) 个邮箱 lane",
                "\(snapshot.generatedAt.formatted(date: .omitted, time: .shortened)) 更新 · \(workspaceModel.daemonMailboxHealth.count) メールボックス lane"
            )
        }
        return LT(
            "Keep only the key controls here and let the mail workspace take the page.",
            "这里仅保留关键状态和操作，把主页面让给邮件工作区。",
            "ここは重要な状態と操作だけに絞り、メイン画面はメールワークスペースに譲る。"
        )
    }

    private var compactOfflineLine: String {
        LT(
            "Offline · control file: \(workspaceModel.daemonRuntimeStatus.controlFilePath) · log: \(workspaceModel.daemonRuntimeStatus.logFilePath)",
            "离线 · 控制文件：\(workspaceModel.daemonRuntimeStatus.controlFilePath) · 日志：\(workspaceModel.daemonRuntimeStatus.logFilePath)",
            "オフライン · 制御ファイル: \(workspaceModel.daemonRuntimeStatus.controlFilePath) · ログ: \(workspaceModel.daemonRuntimeStatus.logFilePath)"
        )
    }

    private var primaryDaemonActionTitle: String {
        switch workspaceModel.daemonRuntimeStatus.lifecycle {
        case .starting:
            return LT("Starting…", "启动中…", "起動中…")
        case .stopping:
            return LT("Stopping…", "停止中…", "停止中…")
        case .running:
            return LT("Restart", "重启", "再起動")
        case .ready, .discovering, .failed:
            return LT("Start daemon", "启动 daemon", "daemon を起動")
        }
    }

    private func primaryDaemonAction() {
        switch workspaceModel.daemonRuntimeStatus.lifecycle {
        case .running:
            onRestartDaemon()
        case .ready, .discovering, .failed:
            onStartDaemon()
        case .starting, .stopping:
            break
        }
    }

    private var daemonLifecycleLabel: String {
        switch workspaceModel.daemonRuntimeStatus.lifecycle {
        case .discovering:
            return LT("Discovering runtime", "检查运行环境", "実行環境を確認中")
        case .ready:
            return LT("Ready to launch", "可以启动", "起動可能")
        case .starting:
            return LT("Daemon starting", "daemon 启动中", "daemon 起動中")
        case .running:
            return LT("Daemon running", "daemon 运行中", "daemon 稼働中")
        case .stopping:
            return LT("Daemon stopping", "daemon 停止中", "daemon 停止中")
        case .failed:
            return LT("Launch needs attention", "启动需要处理", "起動エラーあり")
        }
    }

    private var daemonLifecycleTint: Color {
        switch workspaceModel.daemonRuntimeStatus.lifecycle {
        case .discovering:
            return .orange
        case .ready:
            return Color(red: 0.30, green: 0.47, blue: 0.69)
        case .starting, .stopping:
            return .orange
        case .running:
            return .green
        case .failed:
            return .red
        }
    }

    private var daemonModeValue: String {
        if workspaceModel.daemonRuntimeStatus.isManagedByApp {
            return LT("Started by this app", "由本 app 拉起", "このアプリが起動")
        }
        return LT("External / previously started", "外部或之前已启动", "外部または以前に起動")
    }

    private var offlineHeadline: String {
        switch workspaceModel.daemonRuntimeStatus.lifecycle {
        case .starting:
            return LT("Mailroom daemon is starting.", "Mailroom daemon 正在启动。", "Mailroom daemon を起動中。")
        case .failed:
            return LT("Mailroom daemon did not come up cleanly.", "Mailroom daemon 没有正常启动。", "Mailroom daemon が正常起動しなかった。")
        case .ready, .discovering, .stopping, .running:
            return LT("The daemon is not reachable yet.", "暂时还连不上 daemon。", "まだ daemon に接続できない。")
        }
    }

    private var offlineBody: String {
        switch workspaceModel.daemonRuntimeStatus.lifecycle {
        case .starting:
            return LT(
                "The app is waiting for `mailroomd` to publish its control file and accept connections.",
                "app 正在等待 `mailroomd` 发布控制文件并接受连接。",
                "アプリは `mailroomd` が制御ファイルを公開して接続を受け付けるのを待っている。"
            )
        case .failed:
            return LT(
                "Use the launch controls here to retry or restart. The control file and log paths below make it easier to inspect what happened.",
                "可以直接用这里的启动/重启按钮重试。下面也放了控制文件和日志路径，方便定位问题。",
                "ここにある起動 / 再起動ボタンで再試行できる。下の制御ファイルとログのパスも原因確認に使える。"
            )
        case .ready, .discovering, .stopping, .running:
            return LT(
                "The app can now launch `mailroomd` for you. Use the controls here if you want to start or restart the daemon manually.",
                "现在 app 可以直接帮你拉起 `mailroomd`。如果你想手动启动或重启，就用这里的按钮。",
                "このアプリから `mailroomd` を直接起動できる。手動で起動や再起動をしたいときは、ここにある操作を使う。"
            )
        }
    }

    private var connectionLabel: String {
        switch workspaceModel.daemonConnectionState {
        case .unknown:
            return LT("Checking daemon", "检查 daemon", "daemon 確認中")
        case .unavailable:
            return LT("Daemon offline", "daemon 离线", "daemon オフライン")
        case .connected:
            return LT("Daemon connected", "daemon 已连接", "daemon 接続中")
        }
    }

    private var connectionTint: Color {
        switch workspaceModel.daemonConnectionState {
        case .unknown:
            return .orange
        case .unavailable:
            return .red
        case .connected:
            return .green
        }
    }
}

private struct DaemonOverviewTile: View {
    let title: String
    let value: String
    let detail: String
    let tint: Color
    var monospacedDetail: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(tint)
                    .frame(width: 10, height: 10)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }

            Text(value)
                .font(.headline)
                .foregroundStyle(Color(red: 0.13, green: 0.16, blue: 0.21))

            Text(detail)
                .font(monospacedDetail ? .caption.monospaced() : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(monospacedDetail ? 4 : 3)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
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

private struct NoticeCard: View {
    let title: String
    let message: String
    let tint: Color

    var bodyView: some View {
        SectionSurface {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Color(red: 0.20, green: 0.23, blue: 0.29))
                    .textSelection(.enabled)
            }
        }
    }

    var body: some View {
        bodyView
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(tint.opacity(0.35), lineWidth: 1.5)
            )
    }
}

private struct SectionTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct EmptySectionState: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.03))
        )
    }
}

private struct DaemonApprovalCard: View {
    @ObservedObject var workspaceModel: MailroomWorkspaceModel
    let approval: MailroomDaemonApprovalSummary

    @State private var selectedDecision: String?
    @State private var note: String = ""
    @State private var selectedOptions: [String: String] = [:]
    @State private var freeformAnswers: [String: String] = [:]

    private var isResolving: Bool {
        workspaceModel.isResolvingApproval(approval.id)
    }

    private var submissionAnswers: [String: [String]] {
        approval.questions.reduce(into: [String: [String]]()) { partialResult, question in
            var values: [String] = []
            if let selectedOption = selectedOptions[question.id], !selectedOption.isEmpty {
                values.append(selectedOption)
            }
            let typedText = freeformAnswers[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !typedText.isEmpty {
                values.append(typedText)
            }
            if !values.isEmpty {
                partialResult[question.id] = values
            }
        }
    }

    private var canSubmit: Bool {
        if !approval.availableDecisions.isEmpty {
            return selectedDecision != nil
        }
        return !submissionAnswers.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerSection

            if let detail = approval.detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SelectableBodyText(text: detail)
            }

            if !approval.availableDecisions.isEmpty {
                decisionSection
            }

            ForEach(approval.questions) { question in
                ApprovalQuestionCard(
                    question: question,
                    selectedOption: optionBinding(for: question),
                    freeformAnswer: binding(for: question),
                    isDisabled: isResolving
                )
            }

            submissionSection
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.03))
        )
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(approval.summary)
                    .font(.headline)
                HStack(spacing: 8) {
                    MessagePill(label: approval.kind, tint: approvalKindTint)
                    if let threadToken = approval.mailThreadToken {
                        MessagePill(label: threadToken, tint: Color(red: 0.19, green: 0.31, blue: 0.56))
                    }
                    MessagePill(label: approval.status, tint: approvalStatusTint)
                }
            }
            Spacer(minLength: 12)
            Text(approval.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var decisionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LT("Decision", "决策", "判断"))
                .font(.subheadline.weight(.semibold))
            FlowLayout(spacing: 10) {
                ForEach(approval.availableDecisions, id: \.self) { decision in
                    decisionButton(for: decision)
                }
            }
        }
    }

    private var submissionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(LT("Optional note back to the daemon", "可选备注", "daemon へのメモ"), text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .disabled(isResolving)

            HStack(spacing: 12) {
                Button {
                    Task {
                        await workspaceModel.resolveApproval(
                            approvalID: approval.id,
                            decision: selectedDecision,
                            answers: submissionAnswers,
                            note: note
                        )
                    }
                } label: {
                    if isResolving {
                        ProgressView()
                    } else {
                        Text(LT("Submit to daemon", "提交给 daemon", "daemon へ送信"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit || isResolving)

                VStack(alignment: .leading, spacing: 2) {
                    Text("turn \(approval.codexTurnID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("item \(approval.itemID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
            }
        }
    }

    private func binding(for question: MailroomDaemonApprovalQuestionSummary) -> Binding<String> {
        Binding(
            get: { freeformAnswers[question.id] ?? "" },
            set: { freeformAnswers[question.id] = $0 }
        )
    }

    private func optionBinding(for question: MailroomDaemonApprovalQuestionSummary) -> Binding<String> {
        Binding(
            get: { selectedOptions[question.id] ?? "" },
            set: { selectedOptions[question.id] = $0 }
        )
    }

    @ViewBuilder
    private func decisionButton(for decision: String) -> some View {
        Button {
            selectedDecision = decision
        } label: {
            Text(label(forDecision: decision))
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(selectedDecision == decision ? approvalKindTint.opacity(0.18) : Color.black.opacity(0.04))
                )
                .overlay(
                    Capsule()
                        .stroke(selectedDecision == decision ? approvalKindTint.opacity(0.5) : Color.black.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(isResolving)
    }

    private func label(forDecision decision: String) -> String {
        switch decision {
        case "accept":
            return LT("Approve once", "批准一次", "今回だけ承認")
        case "acceptForSession":
            return LT("Approve session", "批准本会话", "セッションで承認")
        case "decline":
            return LT("Decline", "拒绝", "拒否")
        case "cancel":
            return LT("Cancel turn", "取消回合", "ターンを中止")
        default:
            return decision
        }
    }

    private var approvalKindTint: Color {
        switch approval.kind {
        case "userInput":
            return .blue
        case "commandExecution", "fileChange":
            return .orange
        default:
            return .red
        }
    }

    private var approvalStatusTint: Color {
        approval.status == "pending" ? .orange : .green
    }
}

private struct ApprovalQuestionCard: View {
    let question: MailroomDaemonApprovalQuestionSummary
    @Binding var selectedOption: String
    @Binding var freeformAnswer: String
    let isDisabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.header)
                .font(.subheadline.weight(.semibold))
            Text(question.question)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !question.options.isEmpty {
                FlowLayout(spacing: 10) {
                    ForEach(question.options, id: \.label) { option in
                        optionButton(for: option)
                    }
                }
            }

            if question.isSecret {
                SecureField(LT("Type your answer", "输入答案", "回答を入力"), text: $freeformAnswer)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isDisabled)
            } else if question.isOther || question.options.isEmpty {
                TextField(LT("Type your answer", "输入答案", "回答を入力"), text: $freeformAnswer, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isDisabled)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.03))
        )
    }

    @ViewBuilder
    private func optionButton(for option: MailroomDaemonApprovalOptionSummary) -> some View {
        Button {
            selectedOption = option.label
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(option.label)
                    .font(.subheadline.weight(.semibold))
                Text(option.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(minWidth: 180, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selectedOption == option.label ? Color(red: 0.19, green: 0.31, blue: 0.56).opacity(0.12) : Color.black.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selectedOption == option.label ? Color(red: 0.19, green: 0.31, blue: 0.56).opacity(0.35) : Color.black.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

private struct DaemonMailboxHealthCard: View {
    let mailbox: MailroomDaemonMailboxHealthSummary
    let latestIncident: MailroomMailboxPollIncidentRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(mailbox.label)
                        .font(.headline)
                    Text(mailbox.emailAddress)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Text(mailbox.updatedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                MessagePill(label: stateLabel, tint: stateTint)
                MessagePill(label: passwordLabel, tint: passwordTint)
                MessagePill(label: cadenceLabel, tint: Color(red: 0.19, green: 0.31, blue: 0.56))
                if mailbox.lastQueuedCount > 0 {
                    MessagePill(
                        label: LT(
                            "\(mailbox.lastQueuedCount) queued",
                            "\(mailbox.lastQueuedCount) 条待处理",
                            "\(mailbox.lastQueuedCount) 件キュー"
                        ),
                        tint: .orange
                    )
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                if let lastPollStartedAt = mailbox.lastPollStartedAt {
                    DetailMetaRow(
                        label: LT("Last poll start", "最近轮询开始", "直近ポーリング開始"),
                        value: lastPollStartedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                }
                if let lastPollCompletedAt = mailbox.lastPollCompletedAt {
                    DetailMetaRow(
                        label: LT("Last poll finish", "最近轮询完成", "直近ポーリング完了"),
                        value: lastPollCompletedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                }
                if let nextPollAt = mailbox.nextPollAt {
                    DetailMetaRow(
                        label: LT("Next poll", "下次轮询", "次回ポーリング"),
                        value: nextPollAt.formatted(date: .abbreviated, time: .shortened)
                    )
                }
                DetailMetaRow(
                    label: LT("Last fetch", "最近拉取", "直近フェッチ"),
                    value: LT(
                        "\(mailbox.lastFetchedCount) fetched / \(mailbox.lastQueuedCount) queued",
                        "拉取 \(mailbox.lastFetchedCount) 封 / 入队 \(mailbox.lastQueuedCount) 封",
                        "\(mailbox.lastFetchedCount) 件取得 / \(mailbox.lastQueuedCount) 件キュー"
                    )
                )
                if let lastSeenUID = mailbox.lastSeenUID {
                    DetailMetaRow(
                        label: LT("Last UID", "最新 UID", "最新 UID"),
                        value: String(lastSeenUID)
                    )
                }
                if let lastProcessedAt = mailbox.lastProcessedAt {
                    DetailMetaRow(
                        label: LT("Cursor updated", "游标更新时间", "カーソル更新"),
                        value: lastProcessedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                }
                if let lastError = mailbox.lastError, !lastError.isEmpty {
                    DetailMetaRow(label: LT("Transport error", "传输错误", "転送エラー"), value: lastError)
                }
            }

            if let latestIncident {
                MailboxIncidentCallout(incident: latestIncident)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.03))
        )
    }

    private var stateLabel: String {
        switch mailbox.state {
        case "polling":
            return LT("Polling", "轮询中", "ポーリング中")
        case "healthy":
            return LT("Healthy", "正常", "正常")
        case "bootstrapped":
            return LT("Bootstrapped", "已引导", "ブートストラップ済み")
        case "failed":
            return LT("Failed", "失败", "失敗")
        case "paused":
            return LT("Paused", "已暂停", "一時停止")
        case "waiting":
            return LT("Waiting", "等待中", "待機中")
        default:
            return mailbox.state
        }
    }

    private var stateTint: Color {
        switch mailbox.state {
        case "polling":
            return .orange
        case "healthy", "bootstrapped":
            return .green
        case "failed":
            return .red
        case "paused":
            return .gray
        default:
            return Color(red: 0.19, green: 0.31, blue: 0.56)
        }
    }

    private var passwordLabel: String {
        mailbox.hasPasswordStored
            ? LT("Password ready", "密码已就绪", "パスワード設定済み")
            : LT("Password missing", "缺少密码", "パスワード未設定")
    }

    private var passwordTint: Color {
        mailbox.hasPasswordStored ? .green : .orange
    }

    private var cadenceLabel: String {
        LT(
            "Every \(mailbox.pollingIntervalSeconds)s",
            "每 \(mailbox.pollingIntervalSeconds) 秒",
            "\(mailbox.pollingIntervalSeconds) 秒ごと"
        )
    }
}

private struct MailboxIncidentCallout: View {
    let incident: MailroomMailboxPollIncidentRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                MessagePill(label: statusLabel, tint: statusTint)
                MessagePill(label: phaseLabel, tint: Color(red: 0.37, green: 0.42, blue: 0.49))
            }

            Text(incident.message)
                .font(.caption)
                .foregroundStyle(Color(red: 0.23, green: 0.25, blue: 0.30))
                .lineLimit(4)

            HStack(spacing: 10) {
                Text(incident.occurredAt.formatted(date: .abbreviated, time: .shortened))
                if let lastSeenUID = incident.lastSeenUID {
                    Text("UID \(lastSeenUID)")
                }
                if let retryAt = incident.retryAt, incident.resolvedAt == nil {
                    Text(LT(
                        "Retry \(retryAt.formatted(date: .omitted, time: .shortened))",
                        "重试 \(retryAt.formatted(date: .omitted, time: .shortened))",
                        "リトライ \(retryAt.formatted(date: .omitted, time: .shortened))"
                    ))
                }
                if let resolvedAt = incident.resolvedAt {
                    Text(LT(
                        "Recovered \(resolvedAt.formatted(date: .omitted, time: .shortened))",
                        "已恢复 \(resolvedAt.formatted(date: .omitted, time: .shortened))",
                        "復旧 \(resolvedAt.formatted(date: .omitted, time: .shortened))"
                    ))
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(statusTint.opacity(0.09))
        )
    }

    private var statusLabel: String {
        incident.resolvedAt == nil
            ? LT("Open incident", "未恢复事件", "未解決インシデント")
            : LT("Recovered", "已恢复", "復旧済み")
    }

    private var statusTint: Color {
        incident.resolvedAt == nil ? .red : .green
    }

    private var phaseLabel: String {
        switch incident.phase {
        case "history":
            return LT("History sync", "历史同步", "履歴同期")
        case "sync":
            return LT("Manual sync", "手动同步", "手動同期")
        case "poll":
            return LT("Mailbox poll", "邮箱轮询", "メールポーリング")
        default:
            return incident.phase
        }
    }
}

private struct DaemonWorkerCard: View {
    let worker: MailroomDaemonWorkerSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(worker.currentSubject ?? laneHeadline)
                        .font(.headline)
                        .lineLimit(2)
                    Text(worker.mailboxAddress)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Text(worker.updatedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                MessagePill(label: activityLabel, tint: activityTint)
                MessagePill(label: backlogLabel, tint: backlogTint)
                MessagePill(label: laneLabel, tint: Color(red: 0.19, green: 0.31, blue: 0.56))
                if let threadToken = worker.displayThreadToken {
                    MessagePill(label: threadToken, tint: Color(red: 0.43, green: 0.47, blue: 0.53))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                if let sender = worker.currentSender, !sender.isEmpty {
                    DetailMetaRow(label: LT("Sender", "发件人", "送信者"), value: sender)
                }
                if let messageID = worker.currentMessageID, !messageID.isEmpty {
                    DetailMetaRow(label: LT("Message", "消息", "メッセージ"), value: messageID)
                }
                if let receivedAt = worker.currentReceivedAt {
                    DetailMetaRow(
                        label: LT("Received", "接收时间", "受信時刻"),
                        value: receivedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                }
                if let lastError = worker.lastError, !lastError.isEmpty {
                    DetailMetaRow(label: LT("Last error", "最近错误", "直近エラー"), value: lastError)
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.03))
        )
    }

    private var laneHeadline: String {
        switch worker.laneKind {
        case "thread":
            return LT("Thread lane", "线程 lane", "スレッドレーン")
        case "codex":
            return LT("Codex approval lane", "Codex 审批 lane", "Codex 承認レーン")
        case "message":
            return LT("New message lane", "新消息 lane", "新規メッセージレーン")
        default:
            return LT("Worker lane", "worker lane", "worker レーン")
        }
    }

    private var laneLabel: String {
        switch worker.laneKind {
        case "thread":
            return LT("Thread", "线程", "スレッド")
        case "codex":
            return LT("Codex", "Codex", "Codex")
        case "message":
            return LT("New mail", "新邮件", "新着メール")
        default:
            return LT("Lane", "lane", "レーン")
        }
    }

    private var activityLabel: String {
        if worker.isActive {
            return LT("Running", "执行中", "実行中")
        }
        return LT("Queued", "排队中", "待機中")
    }

    private var activityTint: Color {
        worker.isActive ? .green : .orange
    }

    private var backlogLabel: String {
        if worker.queuedItemCount == 0 {
            return LT("No backlog", "无积压", "バックログなし")
        }
        return LT(
            "\(worker.queuedItemCount) queued",
            "\(worker.queuedItemCount) 条排队",
            "\(worker.queuedItemCount) 件待機"
        )
    }

    private var backlogTint: Color {
        worker.queuedItemCount == 0 ? Color(red: 0.18, green: 0.45, blue: 0.36) : .orange
    }
}

private struct DaemonThreadCard: View {
    let thread: MailroomDaemonThreadSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(thread.subject)
                    .font(.headline)
                Spacer(minLength: 12)
                Text(thread.updatedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(thread.normalizedSender)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(red: 0.20, green: 0.23, blue: 0.29))

            Text(thread.workspaceRoot)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                MessagePill(label: thread.status, tint: threadStatusTint)
                MessagePill(label: thread.capability, tint: Color(red: 0.19, green: 0.31, blue: 0.56))
                MessagePill(label: thread.id, tint: Color(red: 0.43, green: 0.47, blue: 0.53))
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.03))
        )
    }

    private var threadStatusTint: Color {
        switch thread.status {
        case "completed":
            return .green
        case "failed":
            return .red
        case "waitingOnApproval", "waitingOnUser":
            return .orange
        case "archived":
            return Color(red: 0.37, green: 0.42, blue: 0.49)
        default:
            return .blue
        }
    }
}

private struct MailDeskSection: View {
    @ObservedObject var workspaceModel: MailroomWorkspaceModel
    @Binding var selectedItemID: String?

    private var feedItems: [MailDeskFeedItem] {
        MailDeskFeedItem.build(
            messages: workspaceModel.mailboxMessages,
            threads: workspaceModel.daemonThreads
        )
    }

    private var whitelistAddresses: Set<String> {
        Set(
            workspaceModel.senderPolicies
                .filter(\.isEnabled)
                .map(\.normalizedSenderAddress)
        )
    }

    private var whitelistedItems: [MailDeskFeedItem] {
        feedItems.filter { whitelistAddresses.contains($0.normalizedSenderAddress) }
    }

    private var nonWhitelistedItems: [MailDeskFeedItem] {
        feedItems.filter { !whitelistAddresses.contains($0.normalizedSenderAddress) }
    }

    private var senderGroups: [MailDeskListGroup] {
        [
            MailDeskListGroup(
                id: "whitelist",
                title: LT("Whitelist inbox", "白名单来信", "許可リストのメール"),
                subtitle: LT(
                    "Authorized senders who can start or continue Codex work.",
                    "这些发件人已被授权，可以启动或继续 Codex 任务。",
                    "Codex 作業を開始または継続できる許可済み送信者。"
                ),
                items: whitelistedItems
            ),
            MailDeskListGroup(
                id: "non-whitelist",
                title: LT("Other inbox", "非白名单来信", "その他のメール"),
                subtitle: LT(
                    "Mail that arrived but is outside the active allowlist.",
                    "这些邮件已收到，但当前不在启用中的白名单里。",
                    "受信済みだが、現在の有効な許可リスト外にあるメール。"
                ),
                items: nonWhitelistedItems
            )
        ]
    }

    private var effectiveSelectedItem: MailDeskFeedItem? {
        if let selectedItemID,
           let selected = feedItems.first(where: { $0.id == selectedItemID }) {
            return selected
        }
        return feedItems.first
    }

    private var identityMailboxHealth: MailroomDaemonMailboxHealthSummary? {
        guard let accountID = workspaceModel.identityAccount?.id else {
            return nil
        }
        return workspaceModel.daemonMailboxHealth.first(where: { $0.accountID == accountID })
    }

    private var identityMailboxIncident: MailroomMailboxPollIncidentRecord? {
        guard let accountID = workspaceModel.identityAccount?.id else {
            return nil
        }
        return latestMailboxIncident(accountID: accountID)
    }

    private func latestMailboxIncident(accountID: String) -> MailroomMailboxPollIncidentRecord? {
        workspaceModel.daemonMailboxPollIncidents.first(where: { $0.mailboxID == accountID })
    }

    private var activeWorkers: [MailroomDaemonWorkerSummary] {
        workspaceModel.daemonWorkers.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive {
                return lhs.isActive && !rhs.isActive
            }
            if lhs.queuedItemCount != rhs.queuedItemCount {
                return lhs.queuedItemCount > rhs.queuedItemCount
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private var liveTurns: [MailroomDaemonTurnSummary] {
        workspaceModel.daemonTurns
            .filter { turn in
                switch turn.status {
                case "active", "waitingOnApproval", "waitingOnUserInput":
                    return true
                default:
                    return false
                }
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        HSplitView {
            MailDeskSidebar(
                identityAccount: workspaceModel.identityAccount,
                mailboxHealth: identityMailboxHealth,
                latestIncident: identityMailboxIncident,
                groups: senderGroups,
                selectedItemID: effectiveSelectedItem?.id,
                inboxCount: feedItems.count,
                whitelistCount: whitelistedItems.count,
                otherCount: nonWhitelistedItems.count,
                onSelect: { selectedItemID = $0 }
            )
            .frame(minWidth: 300, idealWidth: 336, maxWidth: 380)
            .frame(maxHeight: .infinity)

            MailDeskPreview(
                item: effectiveSelectedItem,
                isResolvingThreadDecision: effectiveSelectedItem?.threadToken.map(workspaceModel.isResolvingThreadDecision) ?? false,
                onResolveThreadDecision: { decision in
                    guard let threadToken = effectiveSelectedItem?.threadToken else {
                        return
                    }
                    Task {
                        await workspaceModel.resolveThreadDecision(
                            threadToken: threadToken,
                            decision: decision
                        )
                    }
                }
            )
                .frame(minWidth: 440, idealWidth: 620, maxWidth: .infinity)
                .frame(maxHeight: .infinity)
            MailDeskTaskSidebar(
                selectedItem: effectiveSelectedItem,
                threads: workspaceModel.daemonThreads,
                workers: activeWorkers,
                approvals: workspaceModel.pendingApprovals,
                liveTurns: liveTurns,
                isResolvingThreadDecision: workspaceModel.isResolvingThreadDecision,
                onResolveThreadDecision: { threadToken, decision in
                    Task {
                        await workspaceModel.resolveThreadDecision(
                            threadToken: threadToken,
                            decision: decision
                        )
                    }
                }
            )
            .frame(minWidth: 260, idealWidth: 292, maxWidth: 340)
            .frame(maxHeight: .infinity)
        }
        .padding(.top, 6)
        .frame(minHeight: 640, maxHeight: .infinity)
        .background(
            Rectangle()
                .fill(Color.white.opacity(0.82))
                .overlay(
                    Rectangle()
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                )
        )
    }
}

private enum MailDeskFilter: String, CaseIterable, Identifiable {
    case all
    case attention
    case completed
    case recorded
    case inboxOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return LT("All", "全部", "すべて")
        case .attention:
            return LT("Attention", "待处理", "要対応")
        case .completed:
            return LT("Completed", "已完成", "完了")
        case .recorded:
            return LT("Recorded", "仅记录", "記録のみ")
        case .inboxOnly:
            return LT("Inbox", "仅邮件", "受信のみ")
        }
    }

    var sectionTitle: String {
        switch self {
        case .all:
            return LT("Mail", "邮件", "メール")
        case .attention:
            return LT("Attention queue", "待处理队列", "要対応キュー")
        case .completed:
            return LT("Completed runs", "已完成任务", "完了した実行")
        case .recorded:
            return LT("Recorded threads", "仅记录线程", "記録のみのスレッド")
        case .inboxOnly:
            return LT("Mailbox-only messages", "纯邮件记录", "メールのみの記録")
        }
    }

    var sectionSubtitle: String {
        switch self {
        case .all:
            return LT(
                "Everything visible in the mail desk.",
                "邮件台里当前可见的全部内容。",
                "メールデスクに表示されている全件。"
            )
        case .attention:
            return LT(
                "Messages still waiting on a human or follow-up.",
                "还在等待人类确认、回复或后续处理的邮件。",
                "人の確認、返信、または追加入力を待っているメール。"
            )
        case .completed:
            return LT(
                "Threads where Mailroom already delivered a result.",
                "Mailroom 已经给出结果的线程。",
                "Mailroom がすでに結果を返したスレッド。"
            )
        case .recorded:
            return LT(
                "Threads that were intentionally captured without starting Codex.",
                "明确只归档、不启动 Codex 的线程。",
                "Codex を起動せず、意図的に記録だけしたスレッド。"
            )
        case .inboxOnly:
            return LT(
                "Messages that are synced into the inbox but do not yet have a workflow result attached.",
                "已同步进邮箱，但还没有挂上工作流结果的邮件。",
                "受信トレイには同期済みだが、まだワークフロー結果が付いていないメール。"
            )
        }
    }

    var tint: Color {
        switch self {
        case .all:
            return Color(red: 0.19, green: 0.31, blue: 0.56)
        case .attention:
            return .orange
        case .completed:
            return .green
        case .recorded:
            return Color(red: 0.48, green: 0.35, blue: 0.16)
        case .inboxOnly:
            return Color(red: 0.37, green: 0.42, blue: 0.49)
        }
    }

    func matches(_ item: MailDeskFeedItem) -> Bool {
        switch self {
        case .all:
            return true
        case .attention:
            return item.needsAttention
        case .completed:
            return item.isCompleted
        case .recorded:
            return item.isRecordedOnly
        case .inboxOnly:
            return item.isMailboxOnly
        }
    }
}

private struct MailDeskListGroup: Identifiable {
    let id: String
    let title: String?
    let subtitle: String?
    let items: [MailDeskFeedItem]
}

private struct MailDeskSidebar: View {
    let identityAccount: ConfiguredMailboxAccount?
    let mailboxHealth: MailroomDaemonMailboxHealthSummary?
    let latestIncident: MailroomMailboxPollIncidentRecord?
    let groups: [MailDeskListGroup]
    let selectedItemID: String?
    let inboxCount: Int
    let whitelistCount: Int
    let otherCount: Int
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MailDeskMailboxCard(
                identityAccount: identityAccount,
                mailboxHealth: mailboxHealth,
                latestIncident: latestIncident,
                inboxCount: inboxCount,
                whitelistCount: whitelistCount,
                otherCount: otherCount
            )

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    if let title = group.title {
                                        Text(title)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(Color(red: 0.24, green: 0.27, blue: 0.32))
                                            .textCase(.uppercase)
                                    }
                                    if let subtitle = group.subtitle {
                                        Text(subtitle)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer(minLength: 12)

                                MessagePill(
                                    label: LT(
                                        "\(group.items.count) items",
                                        "\(group.items.count) 封",
                                        "\(group.items.count) 件"
                                    ),
                                    tint: group.id == "whitelist"
                                        ? Color(red: 0.19, green: 0.31, blue: 0.56)
                                        : Color(red: 0.37, green: 0.42, blue: 0.49)
                                )
                            }

                            if group.items.isEmpty {
                                Text(emptyMessage(for: group.id))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .fill(Color.black.opacity(0.03))
                                    )
                            } else {
                                ForEach(group.items) { item in
                                    Button {
                                        onSelect(item.id)
                                    } label: {
                                        MailDeskRow(item: item, isSelected: item.id == selectedItemID)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private func emptyMessage(for groupID: String) -> String {
        if groupID == "whitelist" {
            return LT(
                "No mail from approved senders yet.",
                "白名单发件人还没有新邮件。",
                "許可済み送信者からのメールはまだない。"
            )
        }

        return LT(
            "No mail outside the whitelist right now.",
            "当前没有白名单外来信。",
            "現在は許可リスト外のメールはない。"
        )
    }
}

private struct MailDeskMailboxCard: View {
    let identityAccount: ConfiguredMailboxAccount?
    let mailboxHealth: MailroomDaemonMailboxHealthSummary?
    let latestIncident: MailroomMailboxPollIncidentRecord?
    let inboxCount: Int
    let whitelistCount: Int
    let otherCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LT("Codex messenger mailbox", "Codex 信使邮箱", "Codex 中継メール"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if let identityAccount {
                Text(identityAccount.account.emailAddress)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.16, green: 0.18, blue: 0.22))
                    .textSelection(.enabled)

                Text(identityAccount.account.label)
                    .font(.subheadline)
                    .foregroundStyle(Color(red: 0.29, green: 0.32, blue: 0.38))

                if let mailboxHealth {
                    Text(mailboxDetailLine(mailboxHealth))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    MessagePill(
                        label: LT(
                            "INBOX \(inboxCount)",
                            "收件箱 \(inboxCount)",
                            "INBOX \(inboxCount)"
                        ),
                        tint: Color(red: 0.19, green: 0.31, blue: 0.56)
                    )
                    MessagePill(
                        label: LT(
                            "Whitelist \(whitelistCount)",
                            "白名单 \(whitelistCount)",
                            "許可 \(whitelistCount)"
                        ),
                        tint: Color(red: 0.16, green: 0.44, blue: 0.34)
                    )
                    MessagePill(
                        label: LT(
                            "Other \(otherCount)",
                            "其他 \(otherCount)",
                            "その他 \(otherCount)"
                        ),
                        tint: Color(red: 0.44, green: 0.46, blue: 0.50)
                    )
                }

                if let mailboxHealth {
                    MessagePill(label: mailboxStateTitle(mailboxHealth.state), tint: mailboxStateTint(mailboxHealth.state))
                }

                if let latestIncident, latestIncident.resolvedAt == nil {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LT("Mailbox transport needs attention", "邮箱传输需要处理", "メール転送に対応が必要"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                        Text(latestIncident.message)
                            .font(.caption)
                            .foregroundStyle(Color(red: 0.52, green: 0.12, blue: 0.10))
                            .lineLimit(3)
                        if let retryAt = latestIncident.retryAt {
                            Text(LT(
                                "Next retry \(retryAt.formatted(date: .omitted, time: .shortened))",
                                "下次重试 \(retryAt.formatted(date: .omitted, time: .shortened))",
                                "次回リトライ \(retryAt.formatted(date: .omitted, time: .shortened))"
                            ))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.red.opacity(0.07))
                    )
                }
            } else {
                Text(LT("No relay mailbox is configured yet.", "还没有配置任何信使邮箱。", "中継メールがまだ設定されていない。"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(red: 0.95, green: 0.97, blue: 0.99))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                )
        )
    }

    private func mailboxDetailLine(_ mailboxHealth: MailroomDaemonMailboxHealthSummary) -> String {
        if let processedAt = mailboxHealth.lastProcessedAt {
            return LT(
                "Last processed \(processedAt.formatted(date: .omitted, time: .shortened)) · every \(mailboxHealth.pollingIntervalSeconds)s",
                "最近处理于 \(processedAt.formatted(date: .omitted, time: .shortened)) · 每 \(mailboxHealth.pollingIntervalSeconds) 秒轮询",
                "最終処理 \(processedAt.formatted(date: .omitted, time: .shortened)) · \(mailboxHealth.pollingIntervalSeconds) 秒ごと"
            )
        }

        return LT(
            "Polling every \(mailboxHealth.pollingIntervalSeconds) seconds.",
            "当前每 \(mailboxHealth.pollingIntervalSeconds) 秒轮询一次。",
            "\(mailboxHealth.pollingIntervalSeconds) 秒ごとにポーリング。"
        )
    }

    private func mailboxStateTitle(_ state: String) -> String {
        switch state {
        case "healthy", "bootstrapped":
            return LT("Receiving", "收信正常", "受信正常")
        case "polling":
            return LT("Polling", "轮询中", "取得中")
        case "paused":
            return LT("Paused", "已暂停", "一時停止")
        case "failed":
            return LT("Needs attention", "需要处理", "要対応")
        default:
            return state
        }
    }

    private func mailboxStateTint(_ state: String) -> Color {
        switch state {
        case "healthy", "bootstrapped":
            return .green
        case "polling":
            return .blue
        case "paused":
            return .orange
        case "failed":
            return .red
        default:
            return Color(red: 0.44, green: 0.46, blue: 0.50)
        }
    }
}

private struct MailDeskTaskSidebar: View {
    let selectedItem: MailDeskFeedItem?
    let threads: [MailroomDaemonThreadSummary]
    let workers: [MailroomDaemonWorkerSummary]
    let approvals: [MailroomDaemonApprovalSummary]
    let liveTurns: [MailroomDaemonTurnSummary]
    let isResolvingThreadDecision: (String) -> Bool
    let onResolveThreadDecision: (String, MailroomDaemonThreadDecision) -> Void

    private var runningWorkerCount: Int {
        workers.filter(\.isActive).count
    }

    private var pendingDecisionThreads: [MailroomDaemonThreadSummary] {
        threads
            .filter { $0.status == "waitingOnUser" }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var focusThread: MailroomDaemonThreadSummary? {
        guard let selectedItem else {
            return nil
        }

        if let threadToken = selectedItem.threadToken,
           let exactMatch = threads.first(where: { $0.id == threadToken }) {
            return exactMatch
        }

        if let exactMessageMatch = threads.first(where: { $0.lastInboundMessageID == selectedItem.messageID || $0.lastOutboundMessageID == selectedItem.messageID }) {
            return exactMessageMatch
        }

        let senderMatches = threads.filter { $0.normalizedSender == selectedItem.normalizedSenderAddress }
        guard !senderMatches.isEmpty else {
            return nil
        }

        let normalizedSelectedSubject = normalizedSubject(selectedItem.subject)
        if !normalizedSelectedSubject.isEmpty,
           let subjectMatch = senderMatches.first(where: { normalizedSubject($0.subject) == normalizedSelectedSubject }) {
            return subjectMatch
        }

        return senderMatches.sorted { $0.updatedAt > $1.updatedAt }.first
    }

    private var focusWorkers: [MailroomDaemonWorkerSummary] {
        guard let selectedItem else {
            return []
        }

        return workers.filter { worker in
            if worker.currentMessageID == selectedItem.messageID {
                return true
            }
            guard let focusThread else {
                return false
            }
            return worker.displayThreadToken == focusThread.id || worker.currentThreadToken == focusThread.id
        }
    }

    private var focusApprovals: [MailroomDaemonApprovalSummary] {
        guard let focusThread else {
            return []
        }
        return approvals.filter { $0.mailThreadToken == focusThread.id }
    }

    private var focusTurns: [MailroomDaemonTurnSummary] {
        guard let focusThread else {
            return []
        }
        return liveTurns.filter { $0.mailThreadToken == focusThread.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LT("Task status", "任务状态", "タスク状態"))
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(red: 0.18, green: 0.20, blue: 0.24))
                    Text(
                        LT(
                            "What the daemon is executing now, what is waiting for approval, and which turns are still alive.",
                            "这里集中看 daemon 当前在跑什么、哪些在等审批、哪些 turn 还处于活跃状态。",
                            "daemon が今何を実行しているか、何が承認待ちか、どの turn がまだ生きているかをここで確認する。"
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 6) {
                    MessagePill(
                        label: LT(
                            "\(runningWorkerCount) running",
                            "\(runningWorkerCount) 个执行中",
                            "\(runningWorkerCount) 件実行中"
                        ),
                        tint: .blue
                    )
                    MessagePill(
                        label: LT(
                            "\(pendingDecisionThreads.count) pending",
                            "\(pendingDecisionThreads.count) 个待回复",
                            "保留中 \(pendingDecisionThreads.count) 件"
                        ),
                        tint: pendingDecisionThreads.isEmpty ? .green : .orange
                    )
                    MessagePill(
                        label: LT(
                            "\(approvals.count) approvals",
                            "\(approvals.count) 个待审批",
                            "\(approvals.count) 件承認待ち"
                        ),
                        tint: approvals.isEmpty ? .green : .orange
                    )
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let selectedItem {
                        MailDeskTaskSection(
                            title: LT("Selected mail", "当前邮件", "選択中メール"),
                            subtitle: LT(
                                "How the selected message maps to a Mailroom thread and the daemon state around it.",
                                "当前选中的邮件，在 Mailroom 线程和 daemon 里的对应状态。",
                                "選択中メールが Mailroom スレッドと daemon 状態にどう対応しているか。"
                            )
                        ) {
                            MailDeskFocusStatusCard(
                                item: selectedItem,
                                thread: focusThread,
                                workers: focusWorkers,
                                approvals: focusApprovals,
                                turns: focusTurns,
                                isResolvingThreadDecision: focusThread.map { isResolvingThreadDecision($0.id) } ?? false,
                                onResolveThreadDecision: { decision in
                                    guard let focusThread else {
                                        return
                                    }
                                    onResolveThreadDecision(focusThread.id, decision)
                                }
                            )
                        }
                    }

                    MailDeskTaskSection(
                        title: LT("Pending mail threads", "待回复线程", "保留中メールスレッド"),
                        subtitle: LT(
                            "Threads that are still waiting for a human reply, including first-mail confirmation and project selection.",
                            "这些线程仍在等待人类回信，包括首封确认和项目选择两种情况。",
                            "初回確認やプロジェクト選択を含め、まだ人の返信待ちのスレッド。"
                        )
                    ) {
                        if pendingDecisionThreads.isEmpty {
                            MailDeskTaskEmptyState(
                                message: LT("No pending mail reply is waiting right now.", "当前没有等待回信的邮件线程。", "現在、返信待ちのメールスレッドはない。")
                            )
                        } else {
                            ForEach(pendingDecisionThreads) { thread in
                                MailDeskThreadStatusRow(
                                    thread: thread,
                                    isResolving: isResolvingThreadDecision(thread.id),
                                    onResolveThreadDecision: { decision in
                                        onResolveThreadDecision(thread.id, decision)
                                    }
                                )
                            }
                        }
                    }

                    MailDeskTaskSection(
                        title: LT("Active workers", "活跃 worker", "稼働中 worker"),
                        subtitle: LT(
                            "Current mail lanes being processed.",
                            "当前正在处理的邮件执行 lane。",
                            "現在処理中のメールレーン。"
                        )
                    ) {
                        if workers.isEmpty {
                            MailDeskTaskEmptyState(
                                message: LT("No worker is running right now.", "当前没有 worker 在执行。", "現在実行中の worker はない。")
                            )
                        } else {
                            ForEach(workers) { worker in
                                MailDeskWorkerStatusRow(worker: worker)
                            }
                        }
                    }

                    MailDeskTaskSection(
                        title: LT("Pending approvals", "待处理审批", "保留中の承認"),
                        subtitle: LT(
                            "Anything waiting for you before execution can continue.",
                            "所有等待你处理后才能继续执行的事项。",
                            "実行を続ける前にあなたの判断を待っている項目。"
                        )
                    ) {
                        if approvals.isEmpty {
                            MailDeskTaskEmptyState(
                                message: LT("Nothing is waiting for approval.", "当前没有等待审批的项。", "承認待ちの項目はない。")
                            )
                        } else {
                            ForEach(approvals) { approval in
                                MailDeskApprovalStatusRow(approval: approval)
                            }
                        }
                    }

                    MailDeskTaskSection(
                        title: LT("Live turns", "活跃 turn", "進行中 turn"),
                        subtitle: LT(
                            "Codex turns that are still running or blocked on feedback.",
                            "仍在运行，或卡在反馈/审批环节的 Codex turn。",
                            "まだ進行中、またはフィードバック/承認待ちで止まっている Codex turn。"
                        )
                    ) {
                        if liveTurns.isEmpty {
                            MailDeskTaskEmptyState(
                                message: LT("No live turn is hanging right now.", "当前没有悬而未决的 turn。", "現在ぶら下がっている turn はない。")
                            )
                        } else {
                            ForEach(liveTurns) { turn in
                                MailDeskTurnStatusRow(turn: turn)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private func normalizedSubject(_ value: String) -> String {
        MailroomMailParser.normalizeSubject(value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

private struct MailDeskTaskSection<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0.24, green: 0.27, blue: 0.32))
                    .textCase(.uppercase)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            content
        }
    }
}

private struct MailDeskTaskEmptyState: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.03))
            )
    }
}

private struct MailDeskFocusStatusCard: View {
    let item: MailDeskFeedItem
    let thread: MailroomDaemonThreadSummary?
    let workers: [MailroomDaemonWorkerSummary]
    let approvals: [MailroomDaemonApprovalSummary]
    let turns: [MailroomDaemonTurnSummary]
    let isResolvingThreadDecision: Bool
    let onResolveThreadDecision: (MailroomDaemonThreadDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displaySubject)
                        .font(.headline)
                        .lineLimit(3)
                    Text(item.displaySender)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(item.receivedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let actionLabel = item.actionLabel {
                HStack(spacing: 8) {
                    MessagePill(label: actionLabel, tint: item.actionTint)
                    if let thread {
                        MessagePill(label: threadStatusLabel(thread.status), tint: threadStatusTint(thread.status))
                    }
                }
            } else if let thread {
                MessagePill(label: threadStatusLabel(thread.status), tint: threadStatusTint(thread.status))
            }

            if let thread {
                VStack(alignment: .leading, spacing: 6) {
                    if let managedProjectName = thread.managedProjectName?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !managedProjectName.isEmpty {
                        LabeledValueRow(
                            title: LT("Project", "项目", "プロジェクト"),
                            value: managedProjectName
                        )
                    }
                    if !thread.workspaceRoot.isEmpty {
                        LabeledValueRow(
                            title: LT("Workspace", "工作区", "ワークスペース"),
                            value: thread.workspaceRoot
                        )
                    }
                    LabeledValueRow(
                        title: LT("Thread", "线程", "スレッド"),
                        value: thread.id
                    )
                    LabeledValueRow(
                        title: LT("Capability", "能力", "権限"),
                        value: thread.capability
                    )
                }
            }

            if let note = item.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Color(red: 0.24, green: 0.27, blue: 0.32))
                    .padding(.top, 2)
            }

            if let thread, thread.status == "waitingOnUser", thread.pendingStage != "projectSelection" {
                HStack(spacing: 10) {
                    Button {
                        onResolveThreadDecision(.startTask)
                    } label: {
                        if isResolvingThreadDecision {
                            ProgressView()
                        } else {
                            Text(LT("Start task", "开始任务", "タスク開始"))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isResolvingThreadDecision)

                    Button {
                        onResolveThreadDecision(.recordOnly)
                    } label: {
                        Text(LT("Record only", "仅记录", "記録のみ"))
                    }
                    .buttonStyle(.bordered)
                    .disabled(isResolvingThreadDecision)
                }
            } else if let thread, thread.status == "waitingOnUser", thread.pendingStage == "projectSelection" {
                Text(
                    LT(
                        "Waiting for a project selection reply from email.",
                        "正在等待通过邮件回信选择项目。",
                        "メールからのプロジェクト選択返信待ち。"
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if !workers.isEmpty {
                    MessagePill(
                        label: LT(
                            "\(workers.count) workers",
                            "\(workers.count) 个 worker",
                            "worker \(workers.count) 件"
                        ),
                        tint: .blue
                    )
                }
                if !approvals.isEmpty {
                    MessagePill(
                        label: LT(
                            "\(approvals.count) approvals",
                            "\(approvals.count) 个审批",
                            "承認 \(approvals.count) 件"
                        ),
                        tint: .orange
                    )
                }
                if !turns.isEmpty {
                    MessagePill(
                        label: LT(
                            "\(turns.count) turns",
                            "\(turns.count) 个 turn",
                            "turn \(turns.count) 件"
                        ),
                        tint: Color(red: 0.45, green: 0.31, blue: 0.13)
                    )
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.03))
        )
    }

    private func threadStatusLabel(_ status: String) -> String {
        switch status {
        case "active":
            return LT("Running", "执行中", "実行中")
        case "waitingOnApproval":
            return LT("Approval needed", "待审批", "承認待ち")
        case "waitingOnUser":
            if thread?.pendingStage == "projectSelection" {
                return LT("Waiting for project", "等待选项目", "プロジェクト選択待ち")
            }
            return LT("Awaiting first reply", "等待首封回复", "初回返信待ち")
        case "waitingOnUserInput":
            return LT("Needs input", "需要补充输入", "追加入力待ち")
        case "completed":
            return LT("Completed", "已完成", "完了")
        case "failed":
            return LT("Failed", "失败", "失敗")
        case "archived":
            return LT("Recorded only", "仅记录", "記録のみ")
        default:
            return status
        }
    }

    private func threadStatusTint(_ status: String) -> Color {
        switch status {
        case "completed":
            return .green
        case "failed":
            return .red
        case "waitingOnApproval", "waitingOnUser", "waitingOnUserInput":
            return .orange
        case "archived":
            return Color(red: 0.48, green: 0.35, blue: 0.16)
        default:
            return .blue
        }
    }
}

private struct MailDeskThreadStatusRow: View {
    let thread: MailroomDaemonThreadSummary
    let isResolving: Bool
    let onResolveThreadDecision: (MailroomDaemonThreadDecision) -> Void

    private var displaySubject: String {
        let trimmed = thread.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? LT("(No subject)", "（无主题）", "（件名なし）") : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displaySubject)
                        .font(.headline)
                        .lineLimit(3)
                    Text(thread.normalizedSender)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(thread.updatedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !thread.workspaceRoot.isEmpty {
                Text(thread.workspaceRoot)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            if let managedProjectName = thread.managedProjectName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !managedProjectName.isEmpty {
                Text(managedProjectName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0.55, green: 0.43, blue: 0.22))
            }

            HStack(spacing: 8) {
                MessagePill(label: threadStatusLabel, tint: threadStatusTint)
                MessagePill(label: thread.capability, tint: Color(red: 0.19, green: 0.31, blue: 0.56))
            }

            if thread.status == "waitingOnUser", thread.pendingStage != "projectSelection" {
                HStack(spacing: 10) {
                    Button {
                        onResolveThreadDecision(.startTask)
                    } label: {
                        if isResolving {
                            ProgressView()
                        } else {
                            Text(LT("Start task", "开始任务", "タスク開始"))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isResolving)

                    Button {
                        onResolveThreadDecision(.recordOnly)
                    } label: {
                        Text(LT("Record only", "仅记录", "記録のみ"))
                    }
                    .buttonStyle(.bordered)
                    .disabled(isResolving)
                }
            } else if thread.status == "waitingOnUser", thread.pendingStage == "projectSelection" {
                Text(
                    LT(
                        "Waiting for the sender to choose a project and provide a command by email.",
                        "正在等待发件人先选项目，再通过邮件补充命令。",
                        "送信者がプロジェクトを選び、メールでコマンドを送るのを待っている。"
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Text(thread.id)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.03))
        )
    }

    private var threadStatusLabel: String {
        switch thread.status {
        case "active":
            return LT("Running", "执行中", "実行中")
        case "waitingOnApproval":
            return LT("Approval needed", "待审批", "承認待ち")
        case "waitingOnUser":
            if thread.pendingStage == "projectSelection" {
                return LT("Waiting for project", "等待选项目", "プロジェクト選択待ち")
            }
            return LT("Awaiting first reply", "等待首封回复", "初回返信待ち")
        case "waitingOnUserInput":
            return LT("Needs input", "需要补充输入", "追加入力待ち")
        case "completed":
            return LT("Completed", "已完成", "完了")
        case "failed":
            return LT("Failed", "失败", "失敗")
        case "archived":
            return LT("Recorded only", "仅记录", "記録のみ")
        default:
            return thread.status
        }
    }

    private var threadStatusTint: Color {
        switch thread.status {
        case "completed":
            return .green
        case "failed":
            return .red
        case "waitingOnApproval", "waitingOnUser", "waitingOnUserInput":
            return .orange
        case "archived":
            return Color(red: 0.48, green: 0.35, blue: 0.16)
        default:
            return .blue
        }
    }
}

private struct LabeledValueRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .foregroundStyle(Color(red: 0.24, green: 0.27, blue: 0.32))
                .textSelection(.enabled)
        }
    }
}

private struct MailDeskWorkerStatusRow: View {
    let worker: MailroomDaemonWorkerSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(worker.currentSubject ?? worker.currentSender ?? worker.displayThreadToken ?? worker.workerKey)
                        .font(.headline)
                        .lineLimit(3)
                    Text(worker.currentSender ?? worker.mailboxAddress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(worker.updatedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                MessagePill(
                    label: worker.isActive
                        ? LT("Running", "执行中", "実行中")
                        : LT("Queued", "排队中", "待機中"),
                    tint: worker.isActive ? .blue : .orange
                )
                MessagePill(label: worker.laneKind, tint: Color(red: 0.45, green: 0.31, blue: 0.13))
                if worker.queuedItemCount > 0 {
                    MessagePill(
                        label: LT(
                            "\(worker.queuedItemCount) queued",
                            "\(worker.queuedItemCount) 个排队",
                            "\(worker.queuedItemCount) 件待機"
                        ),
                        tint: Color(red: 0.37, green: 0.42, blue: 0.49)
                    )
                }
            }

            if let threadToken = worker.displayThreadToken {
                Text(threadToken)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.03))
        )
    }
}

private struct MailDeskApprovalStatusRow: View {
    let approval: MailroomDaemonApprovalSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text(approval.summary)
                    .font(.headline)
                    .lineLimit(3)
                Spacer(minLength: 8)
                Text(approval.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(approval.mailThreadToken ?? "thread \(approval.codexThreadID)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                MessagePill(label: approval.status, tint: .orange)
                MessagePill(label: approval.kind, tint: Color(red: 0.48, green: 0.35, blue: 0.16))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.03))
        )
    }
}

private struct MailDeskTurnStatusRow: View {
    let turn: MailroomDaemonTurnSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(turn.promptPreview ?? turn.mailThreadToken ?? turn.codexThreadID)
                        .font(.headline)
                        .lineLimit(3)
                    Text(turn.mailThreadToken ?? "thread \(turn.codexThreadID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Text(turn.updatedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                MessagePill(label: turn.status, tint: turnStatusTint)
                MessagePill(label: turn.origin, tint: Color(red: 0.19, green: 0.31, blue: 0.56))
                if let notifiedState = turn.lastNotifiedState {
                    MessagePill(label: notifiedState, tint: Color(red: 0.45, green: 0.31, blue: 0.13))
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.03))
        )
    }

    private var turnStatusTint: Color {
        switch turn.status {
        case "completed":
            return .green
        case "failed", "systemError":
            return .red
        case "waitingOnApproval", "waitingOnUserInput":
            return .orange
        default:
            return .blue
        }
    }
}

private struct MailDeskFilterChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.caption.weight(.semibold))
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isSelected ? Color.white.opacity(0.92) : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? tint : Color.white.opacity(0.66))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(isSelected ? tint.opacity(0.25) : Color.black.opacity(0.05), lineWidth: 1)
                    )
            )
            .foregroundStyle(isSelected ? Color.white : Color(red: 0.20, green: 0.22, blue: 0.27))
        }
        .buttonStyle(.plain)
    }
}

private struct MailDeskList: View {
    let groups: [MailDeskListGroup]
    let selectedItemID: String?
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LT("Inbox", "收件箱", "受信トレイ"))
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(red: 0.18, green: 0.20, blue: 0.24))
                    Text(
                        LT(
                            "Newest messages and daemon outcomes in one list.",
                            "把最新邮件和 daemon 处理结果合并到一张列表里。",
                            "最新メールと daemon の処理結果を一つの一覧で確認できる。"
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                MessagePill(
                    label: LT(
                        "\(itemCount) items",
                        "\(itemCount) 条",
                        "\(itemCount) 件"
                    ),
                    tint: Color(red: 0.19, green: 0.31, blue: 0.56)
                )
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            if let title = group.title {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color(red: 0.24, green: 0.27, blue: 0.32))
                                        .textCase(.uppercase)
                                    if let subtitle = group.subtitle {
                                        Text(subtitle)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            ForEach(group.items) { item in
                                Button {
                                    onSelect(item.id)
                                } label: {
                                    MailDeskRow(item: item, isSelected: item.id == selectedItemID)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.bottom, 4)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                )
        )
    }

    private var itemCount: Int {
        groups.reduce(0) { $0 + $1.items.count }
    }
}

private struct MailDeskRow: View {
    let item: MailDeskFeedItem
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(item.statusTint)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Text(item.displaySubject)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(red: 0.18, green: 0.20, blue: 0.24))
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    Text(item.receivedAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    if let actionLabel = item.actionLabel {
                        MessagePill(label: actionLabel, tint: item.actionTint)
                    }
                    if item.groupedMessageCount > 1 {
                        MessagePill(
                            label: LT(
                                "\(item.groupedMessageCount) mails",
                                "\(item.groupedMessageCount) 封",
                                "\(item.groupedMessageCount) 件"
                            ),
                            tint: Color(red: 0.37, green: 0.42, blue: 0.49)
                        )
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isSelected ? Color(red: 0.90, green: 0.95, blue: 1.0) : Color.black.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(isSelected ? Color(red: 0.31, green: 0.48, blue: 0.68) : Color.black.opacity(0.05), lineWidth: 1)
                )
        )
    }
}

private struct MailDeskPreview: View {
    let item: MailDeskFeedItem?
    let isResolvingThreadDecision: Bool
    let onResolveThreadDecision: (MailroomDaemonThreadDecision) -> Void

    var body: some View {
        Group {
            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 14) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(LT("Conversation", "对话", "会話"))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)

                                Text(item.displaySubject)
                                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color(red: 0.16, green: 0.18, blue: 0.22))
                                Text(
                                    LT(
                                        "\(item.groupedMessageCount) messages in this thread",
                                        "这个线程里共 \(item.groupedMessageCount) 条消息",
                                        "このスレッドのメッセージ \(item.groupedMessageCount) 件"
                                    )
                                )
                                .font(.subheadline)
                                .foregroundStyle(Color(red: 0.25, green: 0.28, blue: 0.34))
                                if let threadToken = item.threadToken {
                                    Text(threadToken)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            Spacer(minLength: 12)
                            VStack(alignment: .trailing, spacing: 6) {
                                Text(item.receivedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let processedAt = item.processedAt {
                                    Text(
                                        LT(
                                            "Updated \(processedAt.formatted(date: .omitted, time: .shortened))",
                                            "更新于 \(processedAt.formatted(date: .omitted, time: .shortened))",
                                            "更新 \(processedAt.formatted(date: .omitted, time: .shortened))"
                                        )
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color(red: 0.95, green: 0.97, blue: 0.99))
                        )

                        HStack(spacing: 8) {
                            if let actionLabel = item.actionLabel {
                                MessagePill(label: actionLabel, tint: item.actionTint)
                            }
                            if let threadCapability = item.threadCapability {
                                MessagePill(label: threadCapability, tint: Color(red: 0.19, green: 0.31, blue: 0.56))
                            }
                            if let mailboxSummary = item.mailboxSummary {
                                MessagePill(label: mailboxSummary, tint: Color(red: 0.37, green: 0.42, blue: 0.49))
                            }
                        }

                        if item.threadStatus == "waitingOnUser",
                           let threadToken = item.threadToken,
                           item.threadPendingStage != "projectSelection" {
                            MailDeskThreadDecisionCard(
                                threadToken: threadToken,
                                isResolving: isResolvingThreadDecision,
                                onResolveThreadDecision: onResolveThreadDecision
                            )
                        } else if item.threadStatus == "waitingOnUser",
                                  item.threadPendingStage == "projectSelection",
                                  let threadToken = item.threadToken {
                            MailDeskProjectSelectionCard(threadToken: threadToken)
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(item.conversationEntries) { entry in
                                MailDeskConversationBubble(entry: entry)
                            }
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(Color.white.opacity(0.82))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                                        .stroke(Color.black.opacity(0.04), lineWidth: 1)
                                )
                        )
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack {
                    EmptySectionState(
                        title: LT("Choose a message", "请选择一封邮件", "メールを選択してください"),
                        detail: LT(
                            "Select a row from the inbox on the left to read the body and see what the daemon did with it.",
                            "从左边选一封邮件，就能在这里直接看正文和 daemon 的处理结果。",
                            "左の受信トレイからメールを選ぶと、本文と daemon の処理結果をここで確認できる。"
                        )
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
            }
        }
    }
}

private struct MailDeskThreadDecisionCard: View {
    let threadToken: String
    let isResolving: Bool
    let onResolveThreadDecision: (MailroomDaemonThreadDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LT("First-mail confirmation", "首封确认", "初回メール確認"))
                        .font(.headline)
                        .foregroundStyle(Color(red: 0.24, green: 0.27, blue: 0.32))
                    Text(
                        LT(
                            "Choose whether this thread should start Codex work or stay recorded only.",
                            "选择这个线程是要启动 Codex，还是只做记录。",
                            "このスレッドで Codex を開始するか、記録だけにするかを選ぶ。"
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                MessagePill(label: threadToken, tint: Color(red: 0.45, green: 0.31, blue: 0.13))
            }

            HStack(spacing: 10) {
                decisionOptionCard(
                    title: LT("Start task", "开始任务", "タスク開始"),
                    detail: LT(
                        "Use the current request to launch Codex.",
                        "按当前请求启动 Codex。",
                        "現在の依頼で Codex を起動する。"
                    ),
                    tint: Color(red: 0.23, green: 0.49, blue: 0.85),
                    isPrimary: true
                ) {
                    onResolveThreadDecision(.startTask)
                }

                decisionOptionCard(
                    title: LT("Record only", "仅记录", "記録のみ"),
                    detail: LT(
                        "Keep the thread but do not run Codex yet.",
                        "保留这个线程，但暂时不运行 Codex。",
                        "スレッドは残すが、まだ Codex は実行しない。"
                    ),
                    tint: Color(red: 0.74, green: 0.57, blue: 0.27),
                    isPrimary: false
                ) {
                    onResolveThreadDecision(.recordOnly)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.98, green: 0.95, blue: 0.90))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color(red: 0.85, green: 0.77, blue: 0.63).opacity(0.55), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func decisionOptionCard(
        title: String,
        detail: String,
        tint: Color,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(tint)
                        .frame(width: 8, height: 8)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(isPrimary ? Color.white.opacity(0.86) : .secondary)
                    .multilineTextAlignment(.leading)
                if isResolving {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isPrimary ? tint : Color.white.opacity(0.9))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(isPrimary ? tint.opacity(0.2) : tint.opacity(0.25), lineWidth: 1)
                    )
            )
            .foregroundStyle(isPrimary ? Color.white : Color(red: 0.24, green: 0.27, blue: 0.32))
        }
        .buttonStyle(.plain)
        .disabled(isResolving)
    }
}

private struct MailDeskProjectSelectionCard: View {
    let threadToken: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LT("Project probe", "项目探针", "プロジェクトプローブ"))
                        .font(.headline)
                        .foregroundStyle(Color(red: 0.24, green: 0.27, blue: 0.32))
                    Text(
                        LT(
                            "This thread is waiting for the human to pick a managed project and reply with the command body.",
                            "这个线程正在等待人类先选一个受管项目，再回信写下要执行的命令。",
                            "このスレッドは、管理対象プロジェクトを選び、その後コマンド本文を返信するのを待っている。"
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                MessagePill(label: threadToken, tint: Color(red: 0.55, green: 0.43, blue: 0.22))
            }

            Text(
                LT(
                    "Use the project link inside the reply email, or send PROJECT: <slug> and COMMAND: <what Codex should do>.",
                    "直接点回信里的项目链接，或者手动回复 PROJECT: <短名> 和 COMMAND: <让 Codex 做什么>。",
                    "返信メール内のプロジェクトリンクを使うか、PROJECT: <slug> と COMMAND: <Codex にしてほしいこと> を送る。"
                )
            )
            .font(.caption)
            .foregroundStyle(Color(red: 0.24, green: 0.27, blue: 0.32))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.99, green: 0.96, blue: 0.91))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color(red: 0.84, green: 0.73, blue: 0.53).opacity(0.55), lineWidth: 1)
                )
        )
    }
}

private struct MailDeskConversationBubble: View {
    let entry: MailDeskConversationEntry

    var body: some View {
        if entry.role == .sender {
            senderBubble
        } else {
            systemBubble
        }
    }

    private var senderBubble: some View {
        VStack(
            alignment: .trailing,
            spacing: 6
        ) {
            HStack {
                Spacer(minLength: 54)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.92))
                        if let timestamp = entry.timestamp {
                            Text(timestamp.formatted(date: .omitted, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(Color.white.opacity(0.72))
                        }
                        Spacer(minLength: 0)
                    }

                    Text(entry.body)
                        .font(.system(size: 15, weight: .regular, design: .rounded))
                        .lineSpacing(4)
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)

                    if entry.didCollapseQuotedReply {
                        Text(LT("Quoted reply collapsed", "已折叠引用回复", "引用返信を折りたたみ"))
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.72))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(senderBubbleBackground)
            }
        }
    }

    private var systemBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(red: 0.24, green: 0.27, blue: 0.32))
                        if let timestamp = entry.timestamp {
                            Text(timestamp.formatted(date: .omitted, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if let actionLabel = entry.actionLabel {
                            MessagePill(label: actionLabel, tint: entry.theme.tint)
                        }
                    }

                    Text(entry.body)
                        .font(.system(size: 15, weight: .regular, design: .rounded))
                        .lineSpacing(4)
                        .foregroundStyle(Color(red: 0.22, green: 0.24, blue: 0.28))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)

                    if entry.didCollapseQuotedReply {
                        Text(LT("Quoted reply collapsed", "已折叠引用回复", "引用返信を折りたたみ"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: 620, alignment: .leading)
                .background(systemBubbleBackground)

                Spacer(minLength: 54)
            }
        }
    }

    private var senderBubbleBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color(red: 0.28, green: 0.49, blue: 0.84))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.clear, lineWidth: 1)
            )
    }

    private var systemBubbleBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(entry.theme.background)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(entry.theme.border, lineWidth: 1)
            )
    }
}

private struct MailDeskMetricCard: View {
    let title: String
    let value: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tint)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(value)")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.18, green: 0.20, blue: 0.24))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.64))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.black.opacity(0.04), lineWidth: 1)
                )
        )
    }
}

private struct MailDeskPreviewBlock<Content: View>: View {
    let title: String
    let tint: Color
    let content: Content

    init(title: String, tint: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(tint)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.black.opacity(0.04), lineWidth: 1)
                )
        )
    }
}

private struct MailDeskDetailRow: View {
    let label: String
    let value: String
    var monospaced: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .foregroundStyle(Color(red: 0.24, green: 0.27, blue: 0.32))
                .textSelection(.enabled)
        }
    }
}

private struct MailDeskFeedItem: Identifiable, Hashable {
    var id: String
    var messageID: String
    var uid: UInt64?
    var sender: String
    var subject: String
    var body: String?
    var receivedAt: Date
    var processedAt: Date?
    var mailboxSummary: String?
    var action: String?
    var note: String?
    var threadToken: String?
    var threadStatus: String?
    var threadPendingStage: String?
    var threadCapability: String?
    var groupedMessageCount: Int = 1
    var conversationEntries: [MailDeskConversationEntry] = []

    var normalizedSenderAddress: String {
        sender.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var displaySubject: String {
        subject.isEmpty ? LT("(No subject)", "（无主题）", "（件名なし）") : subject
    }

    var displaySender: String {
        sender.isEmpty ? LT("(Unknown sender)", "（未知发件人）", "（差出人不明）") : sender
    }

    var previewLine: String {
        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            return note.replacingOccurrences(of: "\n", with: " ")
        }
        if let body = body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            return body.replacingOccurrences(of: "\n", with: " ")
        }
        return LT("No preview available.", "暂无预览。", "プレビューはありません。")
    }

    var metadataLine: String? {
        let parts = [mailboxSummary, threadToken]
            .compactMap { value -> String? in
                guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !trimmed.isEmpty else {
                    return nil
                }
                return trimmed
            }
        return parts.isEmpty ? nil : parts.joined(separator: "  •  ")
    }

    var displayBody: String {
        if let body = body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            return body
        }
        return LT(
            "This entry currently has no synced body content. You can still use the daemon note above to understand what happened.",
            "这条记录目前没有同步到正文内容，但仍然可以通过上面的 daemon 注释了解处理结果。",
            "この項目は本文がまだ同期されていないが、上の daemon メモで何が起きたかは確認できる。"
        )
    }

    var displayMessageID: String {
        messageID.isEmpty ? id : messageID
    }

    var searchableText: String {
        [
            sender,
            subject,
            body,
            note,
            mailboxSummary,
            threadToken,
            messageID
        ]
        .compactMap { $0 }
        .map { $0.lowercased() }
        .joined(separator: "\n")
    }

    var hasDaemonNote: Bool {
        note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var actionLabel: String? {
        if let threadStatus {
            switch threadStatus {
            case "active":
                return LT("Running", "执行中", "実行中")
            case "waitingOnApproval":
                return LT("Approval needed", "待审批", "承認待ち")
            case "waitingOnUser":
                if threadPendingStage == "projectSelection" {
                    return LT("Choose project", "等待选项目", "プロジェクト選択待ち")
                }
                return LT("Awaiting first reply", "等待首封回复", "初回返信待ち")
            case "waitingOnUserInput":
                return LT("Needs input", "需要补充输入", "追加入力待ち")
            case "completed":
                return LT("Completed", "已完成", "完了")
            case "failed":
                return LT("Failed", "失败", "失敗")
            case "archived":
                return LT("Recorded only", "仅记录", "記録のみ")
            default:
                break
            }
        }

        guard let action else { return nil }
        switch action {
        case "received":
            return LT("Queued", "已入队", "キュー済み")
        case "historical":
            return LT("History synced", "历史已同步", "履歴同期")
        case "challenged":
            return LT("Awaiting choice", "等待选择", "選択待ち")
        case "recorded":
            return LT("Recorded only", "仅记录", "記録のみ")
        case "completed":
            return LT("Completed", "已完成", "完了")
        case "approvalRequested":
            return LT("Waiting reply", "等待回复", "返信待ち")
        case "rejected":
            return LT("Rejected", "已拒绝", "拒否")
        case "failed":
            return LT("Failed", "失败", "失敗")
        default:
            return LT("Ignored", "已忽略", "無視")
        }
    }

    var actionTint: Color {
        switch threadStatus ?? action {
        case "active":
            return Color(red: 0.19, green: 0.31, blue: 0.56)
        case "waitingOnApproval", "waitingOnUser", "waitingOnUserInput":
            return .orange
        case "archived":
            return Color(red: 0.48, green: 0.35, blue: 0.16)
        case "completed":
            return .green
        case "failed":
            return .red
        case "received":
            return Color(red: 0.19, green: 0.31, blue: 0.56)
        case "historical":
            return Color(red: 0.37, green: 0.42, blue: 0.49)
        case "challenged", "approvalRequested":
            return .orange
        case "recorded":
            return Color(red: 0.48, green: 0.35, blue: 0.16)
        case "rejected":
            return .red
        default:
            return .blue
        }
    }

    var statusTint: Color {
        action == nil ? Color(red: 0.61, green: 0.64, blue: 0.69) : actionTint
    }

    var needsAttention: Bool {
        switch threadStatus ?? action {
        case "waitingOnApproval", "waitingOnUser", "waitingOnUserInput", "challenged", "approvalRequested", "failed", "rejected":
            return true
        default:
            return false
        }
    }

    var isCompleted: Bool {
        threadStatus == "completed" || action == "completed"
    }

    var isRecordedOnly: Bool {
        threadStatus == "archived" || action == "recorded"
    }

    var isMailboxOnly: Bool {
        threadStatus == nil && (action == nil || action == "historical" || action == "received")
    }

    var listPriority: Int {
        if needsAttention {
            return 4
        }
        if isCompleted {
            return 3
        }
        if isRecordedOnly {
            return 2
        }
        if isMailboxOnly {
            return 1
        }
        return 0
    }

    static func build(
        messages: [MailroomMailboxMessageRecord],
        threads: [MailroomDaemonThreadSummary]
    ) -> [MailDeskFeedItem] {
        let threadsByID = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })

        return Dictionary(grouping: messages) { message in
            if let threadToken = normalizedThreadToken(message.threadToken) {
                return "thread:\(threadToken)"
            }
            return "message:\(message.id)"
        }
        .values
        .compactMap { groupedMessages -> MailDeskFeedItem? in
            guard let message = groupedMessages.max(by: feedItemSort(lhs:rhs:)) else {
                return nil
            }

            let normalizedThreadToken = normalizedThreadToken(message.threadToken)
            let matchedThread = normalizedThreadToken.flatMap { threadsByID[$0] }
            let conversationEntries = buildConversationEntries(from: groupedMessages)

                let mailboxFields: [String?] = [message.mailboxLabel, message.mailboxEmailAddress]
                let mailboxSummaryParts = mailboxFields.compactMap { value -> String? in
                    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !trimmed.isEmpty else {
                        return nil
                    }
                    return trimmed
                }
                let mailboxSummary = mailboxSummaryParts.isEmpty ? nil : mailboxSummaryParts.joined(separator: " · ")
            return MailDeskFeedItem(
                    id: normalizedThreadToken.map { "thread:\($0)" } ?? message.id,
                    messageID: message.messageID,
                    uid: message.uid,
                    sender: message.fromAddress,
                    subject: matchedThread?.subject ?? message.subject,
                    body: message.plainBody,
                    receivedAt: message.receivedAt,
                    processedAt: message.processedAt,
                    mailboxSummary: mailboxSummary,
                    action: message.action.rawValue,
                    note: message.note,
                    threadToken: normalizedThreadToken,
                    threadStatus: matchedThread?.status,
                    threadPendingStage: matchedThread?.pendingStage,
                    threadCapability: matchedThread?.capability,
                    groupedMessageCount: groupedMessages.count,
                    conversationEntries: conversationEntries
                )
            }
            .sorted { lhs, rhs in
                if lhs.listPriority != rhs.listPriority {
                    return lhs.listPriority > rhs.listPriority
                }
                if lhs.receivedAt != rhs.receivedAt {
                    return lhs.receivedAt > rhs.receivedAt
                }
                return (lhs.processedAt ?? .distantPast) > (rhs.processedAt ?? .distantPast)
            }
    }

    private static func normalizedThreadToken(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func feedItemSort(lhs: MailroomMailboxMessageRecord, rhs: MailroomMailboxMessageRecord) -> Bool {
        if lhs.receivedAt != rhs.receivedAt {
            return lhs.receivedAt < rhs.receivedAt
        }
        return (lhs.processedAt ?? .distantPast) < (rhs.processedAt ?? .distantPast)
    }

    private static func buildConversationEntries(from messages: [MailroomMailboxMessageRecord]) -> [MailDeskConversationEntry] {
        messages
            .sorted(by: feedItemSort(lhs:rhs:))
            .flatMap { message -> [MailDeskConversationEntry] in
                let senderBody = cleanedConversationBody(from: message.plainBody)
                let senderTitle = displaySenderName(
                    address: message.fromAddress,
                    displayName: message.fromDisplayName
                )

                var entries: [MailDeskConversationEntry] = [
                    MailDeskConversationEntry(
                        id: "\(message.id):sender",
                        role: .sender,
                        title: senderTitle,
                        body: senderBody.body,
                        timestamp: message.receivedAt,
                        actionLabel: nil,
                        didCollapseQuotedReply: senderBody.didCollapseQuotedReply,
                        theme: .sender
                    )
                ]

                let note = message.note.trimmingCharacters(in: .whitespacesAndNewlines)
                if !note.isEmpty {
                    entries.append(
                        MailDeskConversationEntry(
                            id: "\(message.id):mailroom",
                            role: .mailroom,
                            title: LT("Mailroom", "Mailroom", "Mailroom"),
                            body: note,
                            timestamp: message.processedAt ?? message.receivedAt,
                            actionLabel: actionLabel(for: message.action.rawValue),
                            didCollapseQuotedReply: false,
                            theme: conversationTheme(for: message.action.rawValue)
                        )
                    )
                }

                return entries
            }
    }

    private static func cleanedConversationBody(from rawBody: String) -> (body: String, didCollapseQuotedReply: Bool) {
        let trimmedRaw = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = MailroomMailParser.stripQuotedReplyChain(from: rawBody)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !stripped.isEmpty {
            return (stripped, stripped != trimmedRaw)
        }

        if !trimmedRaw.isEmpty {
            return (trimmedRaw, false)
        }

        return (
            LT("No readable body content.", "没有可读正文。", "読める本文がない。"),
            false
        )
    }

    private static func displaySenderName(address: String, displayName: String?) -> String {
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedName.isEmpty {
            return trimmedName
        }
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedAddress.isEmpty ? LT("Sender", "发件人", "送信者") : trimmedAddress
    }

    private static func actionLabel(for action: String?) -> String? {
        guard let action else {
            return nil
        }
        switch action {
        case "received":
            return LT("Queued", "已入队", "キュー済み")
        case "historical":
            return LT("History synced", "历史已同步", "履歴同期")
        case "challenged":
            return LT("Awaiting choice", "等待选择", "選択待ち")
        case "recorded":
            return LT("Recorded only", "仅记录", "記録のみ")
        case "completed":
            return LT("Completed", "已完成", "完了")
        case "approvalRequested":
            return LT("Waiting reply", "等待回复", "返信待ち")
        case "rejected":
            return LT("Rejected", "已拒绝", "拒否")
        case "failed":
            return LT("Failed", "失败", "失敗")
        default:
            return LT("Ignored", "已忽略", "無視")
        }
    }

    private static func conversationTheme(for action: String?) -> MailDeskConversationEntry.Theme {
        switch action {
        case "challenged", "approvalRequested":
            return .pending
        case "completed":
            return .success
        case "recorded":
            return .recorded
        case "failed", "rejected":
            return .failure
        case "historical":
            return .muted
        default:
            return .neutral
        }
    }
}

private struct MailDeskConversationEntry: Identifiable, Hashable {
    enum Role: String, Hashable {
        case sender
        case mailroom
    }

    enum Theme: Hashable {
        case sender
        case neutral
        case muted
        case pending
        case success
        case recorded
        case failure

        var tint: Color {
            switch self {
            case .sender:
                return Color(red: 0.28, green: 0.49, blue: 0.84)
            case .neutral:
                return Color(red: 0.47, green: 0.51, blue: 0.58)
            case .muted:
                return Color(red: 0.50, green: 0.54, blue: 0.60)
            case .pending:
                return .orange
            case .success:
                return .green
            case .recorded:
                return Color(red: 0.74, green: 0.57, blue: 0.27)
            case .failure:
                return .red
            }
        }

        var background: Color {
            switch self {
            case .sender:
                return Color(red: 0.28, green: 0.49, blue: 0.84)
            case .neutral:
                return Color(red: 0.96, green: 0.96, blue: 0.97)
            case .muted:
                return Color(red: 0.95, green: 0.95, blue: 0.96)
            case .pending:
                return Color(red: 0.99, green: 0.95, blue: 0.90)
            case .success:
                return Color(red: 0.93, green: 0.98, blue: 0.94)
            case .recorded:
                return Color(red: 0.98, green: 0.95, blue: 0.89)
            case .failure:
                return Color(red: 1.0, green: 0.94, blue: 0.94)
            }
        }

        var border: Color {
            switch self {
            case .sender:
                return .clear
            case .neutral, .muted:
                return Color.black.opacity(0.05)
            case .pending:
                return Color.orange.opacity(0.28)
            case .success:
                return Color.green.opacity(0.28)
            case .recorded:
                return Color(red: 0.74, green: 0.57, blue: 0.27).opacity(0.28)
            case .failure:
                return Color.red.opacity(0.22)
            }
        }
    }

    var id: String
    var role: Role
    var title: String
    var body: String
    var timestamp: Date?
    var actionLabel: String?
    var didCollapseQuotedReply: Bool
    var theme: Theme
}

private struct DaemonTurnCard: View {
    let turn: MailroomDaemonTurnSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(turn.promptPreview ?? LT("No prompt preview", "无 prompt 预览", "プロンプトプレビューなし"))
                        .font(.headline)
                        .lineLimit(3)
                    Text("thread \(turn.codexThreadID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 12)
                Text(turn.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                MessagePill(label: turn.status, tint: turnStatusTint)
                MessagePill(label: turn.origin, tint: Color(red: 0.19, green: 0.31, blue: 0.56))
                if let notifiedState = turn.lastNotifiedState {
                    MessagePill(label: notifiedState, tint: Color(red: 0.45, green: 0.31, blue: 0.13))
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.03))
        )
    }

    private var turnStatusTint: Color {
        switch turn.status {
        case "completed":
            return .green
        case "failed", "systemError":
            return .red
        case "waitingOnApproval", "waitingOnUserInput":
            return .orange
        default:
            return .blue
        }
    }
}

private struct LegacyJobRow: View {
    let job: ExecutionJobRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(job.subject.isEmpty ? job.action : job.subject)
                    .font(.headline)
                Spacer(minLength: 12)
                Text(job.updatedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(job.senderAddress)
                .font(.subheadline.weight(.semibold))
            if let preview = job.detailPreview {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            HStack(spacing: 8) {
                MessagePill(label: job.status.title, tint: legacyStatusTint)
                MessagePill(label: job.capability.title, tint: Color(red: 0.19, green: 0.31, blue: 0.56))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.03))
        )
    }

    private var legacyStatusTint: Color {
        switch job.status {
        case .succeeded:
            return .green
        case .failed, .rejected:
            return .red
        case .waiting, .running:
            return .orange
        case .received, .accepted:
            return .blue
        }
    }
}

private struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsSheetView: View {
    @ObservedObject var workspaceModel: MailroomWorkspaceModel
    let initialPane: OperatorSettingsPane
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppLanguageOption.storageKey) private var appLanguageRaw: String = AppLanguageOption.system.rawValue

    @State private var selectedPane: OperatorSettingsPane
    @State private var activeAlert: OperatorFeedbackAlert?

    init(
        workspaceModel: MailroomWorkspaceModel,
        initialPane: OperatorSettingsPane = .runtime
    ) {
        self.workspaceModel = workspaceModel
        self.initialPane = initialPane
        _selectedPane = State(initialValue: initialPane)
    }

    private var languageSelection: Binding<AppLanguageOption> {
        Binding(
            get: { AppLanguageOption(rawValue: appLanguageRaw) ?? .system },
            set: { appLanguageRaw = $0.rawValue }
        )
    }

    private var whitelistCount: Int {
        workspaceModel.senderPolicies.count
    }

    private var enabledWhitelistCount: Int {
        workspaceModel.senderPolicies.filter { $0.isEnabled }.count
    }

    private var enabledManagedProjectCount: Int {
        workspaceModel.managedProjects.filter { $0.isEnabled }.count
    }

    private var receiveStatusText: String {
        guard let identity = workspaceModel.identityAccount else {
            return LT("Needs mailbox", "需先配置邮箱", "メール設定が必要")
        }
        if !identity.hasPasswordStored {
            return LT("Password missing", "缺少密码", "パスワード未設定")
        }
        if enabledWhitelistCount == 0 {
            return LT("No active sender", "没有启用的白名单", "有効な送信者なし")
        }
        return LT("Ready", "已就绪", "準備完了")
    }

    private var daemonStatusText: String {
        switch workspaceModel.daemonRuntimeStatus.lifecycle {
        case .discovering:
            return LT("Checking runtime", "检查运行环境", "実行環境を確認中")
        case .ready:
            return LT("Ready to start", "可以启动", "起動可能")
        case .starting:
            return LT("Starting", "启动中", "起動中")
        case .running:
            return LT("Running", "运行中", "稼働中")
        case .stopping:
            return LT("Stopping", "停止中", "停止中")
        case .failed:
            return LT("Needs attention", "需要处理", "要対応")
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LT("Settings", "设置", "設定"))
                        .font(.title2.weight(.semibold))
                    Text(LT("Runtime, mailbox, projects + whitelist", "运行状态、邮箱、项目与白名单", "ランタイム・メール・プロジェクト・許可リスト"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 8) {
                    ForEach(OperatorSettingsPane.allCases) { pane in
                        SettingsSidebarButton(
                            pane: pane,
                            isSelected: pane == selectedPane
                        ) {
                            selectedPane = pane
                        }
                    }
                }

                Spacer(minLength: 0)

                SectionSurface {
                    VStack(alignment: .leading, spacing: 14) {
                        SettingsStatusRow(
                            title: LT("Relay", "信使邮箱", "中継メール"),
                            value: workspaceModel.identityAccount?.account.emailAddress ?? LT("Not configured", "未配置", "未設定")
                        )
                        SettingsStatusRow(
                            title: LT("Daemon", "Daemon", "Daemon"),
                            value: daemonStatusText
                        )
                        SettingsStatusRow(
                            title: LT("Receiving", "收信状态", "受信状態"),
                            value: receiveStatusText
                        )
                        SettingsStatusRow(
                            title: LT("Projects", "项目", "プロジェクト"),
                            value: LT(
                                "\(enabledManagedProjectCount) active / \(workspaceModel.managedProjects.count) total",
                                "\(enabledManagedProjectCount) 个启用 / 共 \(workspaceModel.managedProjects.count) 个",
                                "\(enabledManagedProjectCount) 件有効 / 合計 \(workspaceModel.managedProjects.count) 件"
                            )
                        )
                        SettingsStatusRow(
                            title: LT("Whitelist", "白名单", "許可リスト"),
                            value: LT(
                                "\(enabledWhitelistCount) active / \(whitelistCount) total",
                                "\(enabledWhitelistCount) 个启用 / 共 \(whitelistCount) 个",
                                "\(enabledWhitelistCount) 件有効 / 合計 \(whitelistCount) 件"
                            )
                        )

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text(LT("Language", "语言", "言語"))
                                .font(.subheadline.weight(.semibold))

                            Picker(LT("Language", "语言", "言語"), selection: languageSelection) {
                                ForEach(AppLanguageOption.allCases) { option in
                                    Text(option.nativeName).tag(option)
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        Divider()

                        SettingsStatusRow(
                            title: LT("Version", "版本", "バージョン"),
                            value: AppBuildMetadata.displayVersion
                        )
                    }
                }
            }
            .frame(width: 250)
            .padding(20)
            .background(settingsSidebarBackground)

            Divider()

            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 16) {
                    Text(selectedPane.title)
                        .font(.title2.weight(.semibold))

                    Spacer(minLength: 16)

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color.black.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(LT("Close settings", "关闭设置", "設定を閉じる"))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)

                Divider()

                Group {
                    switch selectedPane {
                    case .runtime:
                        RuntimeSettingsPane(workspaceModel: workspaceModel)
                    case .mailboxes:
                        MailroomSetupView(workspaceModel: workspaceModel, contentMode: .mailboxes)
                    case .projects:
                        MailroomSetupView(workspaceModel: workspaceModel, contentMode: .projects)
                    case .whitelist:
                        MailroomSetupView(workspaceModel: workspaceModel, contentMode: .policies)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(settingsContentBackground)
        }
        .alert(item: $activeAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text(LT("OK", "好的", "OK")))
            )
        }
        .onChange(of: workspaceModel.errorMessage) {
            guard let message = workspaceModel.errorMessage.trimmedNonEmpty else {
                return
            }
            activeAlert = OperatorFeedbackAlert(
                title: LT("Needs attention", "需要注意", "要対応"),
                message: message
            )
        }
        .onChange(of: workspaceModel.statusMessage) {
            guard let message = workspaceModel.statusMessage.trimmedNonEmpty else {
                return
            }
            activeAlert = OperatorFeedbackAlert(
                title: LT("Done", "完成", "完了"),
                message: message
            )
        }
    }

    private var settingsSidebarBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.98, green: 0.97, blue: 0.95),
                Color(red: 0.96, green: 0.97, blue: 0.98)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var settingsContentBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.95, green: 0.94, blue: 0.91),
                Color(red: 0.93, green: 0.95, blue: 0.97)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct RuntimeSettingsPane: View {
    @ObservedObject var workspaceModel: MailroomWorkspaceModel
    @State private var isShowingPathStorageSheet = false

    private var runningWorkerCount: Int {
        workspaceModel.daemonWorkers.filter(\.isActive).count
    }

    private var runtimeTitle: String {
        switch workspaceModel.daemonRuntimeStatus.lifecycle {
        case .discovering:
            return LT("Checking runtime", "检查运行环境", "実行環境を確認中")
        case .ready:
            return LT("Ready to start", "可以启动", "起動可能")
        case .starting:
            return LT("Daemon starting", "daemon 启动中", "daemon 起動中")
        case .running:
            return LT("Daemon running", "daemon 运行中", "daemon 稼働中")
        case .stopping:
            return LT("Daemon stopping", "daemon 停止中", "daemon 停止中")
        case .failed:
            return LT("Needs attention", "需要处理", "要対応")
        }
    }

    private var primaryActionTitle: String {
        switch workspaceModel.daemonRuntimeStatus.lifecycle {
        case .running:
            return LT("Restart", "重启", "再起動")
        case .starting:
            return LT("Starting…", "启动中…", "起動中…")
        case .stopping:
            return LT("Stopping…", "停止中…", "停止中…")
        case .ready, .discovering, .failed:
            return LT("Start background daemon", "启动后台 daemon", "バックグラウンド daemon を起動")
        }
    }

    private var backgroundServiceValue: String {
        if workspaceModel.daemonRuntimeStatus.isLaunchAgentLoaded {
            return LT("Resident and active", "已常驻并运行", "常駐・稼働中")
        }
        if workspaceModel.daemonRuntimeStatus.isLaunchAgentInstalled {
            return LT("Installed, currently stopped", "已安装，当前停止", "登録済み・現在停止中")
        }
        return LT("Not installed yet", "尚未安装", "未登録")
    }

    private var backgroundServiceDetail: String {
        if workspaceModel.daemonRuntimeStatus.isLaunchAgentInstalled {
            return LT(
                "mailroomd now runs through macOS LaunchAgent so it can stay alive after the app closes.",
                "mailroomd 现在通过 macOS LaunchAgent 常驻，关掉 app 也能继续跑。",
                "mailroomd は macOS LaunchAgent 経由で常駐し、アプリを閉じても動き続ける。"
            )
        }
        return LT(
            "Start once and the app will register the resident background service for this Mac user.",
            "启动一次后，app 会为当前 Mac 用户注册常驻后台服务。",
            "一度起動すると、この Mac ユーザー向けの常駐バックグラウンドサービスを登録する。"
        )
    }

    private var supportRootPath: String {
        (workspaceModel.daemonSnapshot?.supportRoot).trimmedNonEmpty
            ?? Optional(workspaceModel.applicationSupportPath).trimmedNonEmpty
            ?? LT("Not available", "暂不可用", "利用不可")
    }

    private var daemonDatabasePath: String {
        (workspaceModel.daemonSnapshot?.databasePath).trimmedNonEmpty
            ?? Optional(workspaceModel.daemonDatabasePath).trimmedNonEmpty
            ?? LT("Not available", "暂不可用", "利用不可")
    }

    private var latestSnapshotValue: String {
        workspaceModel.daemonSnapshot?.generatedAt.formatted(date: .abbreviated, time: .shortened)
            ?? LT("No snapshot yet", "还没有快照", "スナップショット未取得")
    }

    private var startedAtValue: String {
        workspaceModel.daemonRuntimeStatus.startedAt?.formatted(date: .abbreviated, time: .shortened)
            ?? LT("Not running", "未运行", "未起動")
    }

    private var executablePath: String {
        workspaceModel.daemonRuntimeStatus.executablePath.trimmedNonEmpty
            ?? LT("Not found yet", "暂未发现", "未検出")
    }

    private func latestMailboxIncident(accountID: String) -> MailroomMailboxPollIncidentRecord? {
        workspaceModel.daemonMailboxPollIncidents.first(where: { $0.mailboxID == accountID })
    }

    private func refreshRuntime() {
        Task { await workspaceModel.refreshMailDesk() }
    }

    private func performPrimaryAction() {
        Task {
            switch workspaceModel.daemonRuntimeStatus.lifecycle {
            case .running:
                await workspaceModel.restartDaemon()
            case .ready, .discovering, .failed:
                await workspaceModel.startDaemon()
            case .starting, .stopping:
                break
            }
        }
    }

    private var launchAgentPath: String {
        workspaceModel.daemonRuntimeStatus.launchAgentPlistPath ?? LT("Not available", "暂不可用", "利用不可")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionSurface {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(LT("Runtime", "运行状态", "ランタイム"))
                                    .font(.headline)
                                Text(
                                    LT(
                                        "Daemon controls and sync details live here now, so the main window can stay focused on mail.",
                                        "Daemon 控制和同步细节放到这里，主窗口只保留邮件工作区。",
                                        "daemon 制御と同期詳細はここへ移し、メイン画面はメール作業に集中させる。"
                                    )
                                )
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 12)

                            HStack(spacing: 10) {
                                Button(LT("Refresh", "刷新", "更新"), action: refreshRuntime)
                                    .buttonStyle(.bordered)
                                Button(primaryActionTitle, action: performPrimaryAction)
                                    .buttonStyle(.bordered)
                                    .disabled(!workspaceModel.canStartDaemon)
                                if workspaceModel.daemonRuntimeStatus.lifecycle == .running {
                                    Button(LT("Stop", "停止", "停止")) {
                                        Task { await workspaceModel.stopDaemon() }
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(!workspaceModel.canStartDaemon)
                                }
                            }
                        }

                        if let detail = workspaceModel.daemonRuntimeStatus.detail.trimmedNonEmpty {
                            SelectableBodyText(text: detail)
                        }

                        LazyVGrid(
                            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                            spacing: 12
                        ) {
                            RuntimeMetricCard(
                                title: LT("Daemon", "Daemon", "Daemon"),
                                value: runtimeTitle,
                                detail: workspaceModel.daemonConnectionState.isConnected
                                    ? LT("Control channel connected", "控制通道已连接", "制御チャネル接続済み")
                                    : LT("Control channel unavailable", "控制通道不可用", "制御チャネル未接続"),
                                tint: runtimeMetricTint
                            )
                            RuntimeMetricCard(
                                title: LT("Background service", "后台服务", "バックグラウンドサービス"),
                                value: backgroundServiceValue,
                                detail: backgroundServiceDetail,
                                tint: workspaceModel.daemonRuntimeStatus.isLaunchAgentInstalled ? .green : .orange
                            )
                            RuntimeMetricCard(
                                title: LT("Approvals", "审批", "承認"),
                                value: "\(workspaceModel.pendingApprovals.count)",
                                detail: LT(
                                    "Pending approvals that still need a human decision.",
                                    "仍然等待人工决定的审批项。",
                                    "まだ人の判断を待っている承認件数。"
                                ),
                                tint: workspaceModel.pendingApprovals.isEmpty ? .green : .orange
                            )
                            RuntimeMetricCard(
                                title: LT("Workers", "Workers", "Workers"),
                                value: "\(runningWorkerCount)",
                                detail: LT(
                                    "\(workspaceModel.daemonWorkers.count) visible lanes",
                                    "共 \(workspaceModel.daemonWorkers.count) 条可见 lane",
                                    "表示中レーン \(workspaceModel.daemonWorkers.count) 件"
                                ),
                                tint: runningWorkerCount == 0 ? Color(red: 0.37, green: 0.42, blue: 0.49) : .blue
                            )
                            RuntimeMetricCard(
                                title: LT("Latest snapshot", "最新快照", "最新スナップショット"),
                                value: latestSnapshotValue,
                                detail: LT(
                                    "\(workspaceModel.daemonThreads.count) threads · \(workspaceModel.daemonTurns.count) turns",
                                    "\(workspaceModel.daemonThreads.count) 个线程 · \(workspaceModel.daemonTurns.count) 个 turn",
                                    "\(workspaceModel.daemonThreads.count) スレッド · \(workspaceModel.daemonTurns.count) turn"
                                ),
                                tint: Color(red: 0.19, green: 0.31, blue: 0.56)
                            )
                        }

                        HStack {
                            Text(
                                LT(
                                    "Diagnostic paths are hidden by default.",
                                    "诊断路径默认收起，需要时再查看。",
                                    "診断パスは通常非表示で、必要なときだけ開く。"
                                )
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            Spacer(minLength: 12)

                            Button(LT("View paths + storage", "查看路径与存储", "パスと保存先を見る")) {
                                isShowingPathStorageSheet = true
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                SectionSurface {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(LT("Mailbox health", "邮箱健康", "メールボックス健全性"))
                            .font(.headline)

                        if workspaceModel.daemonMailboxHealth.isEmpty {
                            EmptySectionState(
                                title: LT("No relay mailbox is reporting yet.", "还没有信使邮箱上报状态。", "状態を報告している中継メールはまだない。"),
                                detail: LT(
                                    "Once a relay mailbox is configured, polling cadence and sync health will appear here.",
                                    "配置好信使邮箱后，这里会显示轮询节奏和同步健康状态。",
                                    "中継メールを設定すると、ここへポーリング周期と同期状態が表示される。"
                                )
                            )
                        } else {
                            ForEach(workspaceModel.daemonMailboxHealth) { mailbox in
                                DaemonMailboxHealthCard(
                                    mailbox: mailbox,
                                    latestIncident: latestMailboxIncident(accountID: mailbox.accountID)
                                )
                            }
                        }
                    }
                }

                if !workspaceModel.daemonWorkers.isEmpty {
                    SectionSurface {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(LT("Active workers", "活跃 workers", "稼働中 workers"))
                                .font(.headline)

                            ForEach(Array(workspaceModel.daemonWorkers.prefix(4))) { worker in
                                DaemonWorkerCard(worker: worker)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .sheet(isPresented: $isShowingPathStorageSheet) {
            RuntimePathStorageSheet(
                supportRootPath: supportRootPath,
                controlFilePath: workspaceModel.daemonRuntimeStatus.controlFilePath,
                logFilePath: workspaceModel.daemonRuntimeStatus.logFilePath,
                daemonDatabasePath: daemonDatabasePath,
                jobsDatabasePath: Optional(workspaceModel.jobsDatabasePath).trimmedNonEmpty ?? LT("Not available", "暂不可用", "利用不可"),
                executablePath: executablePath,
                launchAgentPath: launchAgentPath,
                backgroundServiceValue: backgroundServiceValue,
                startedAtValue: startedAtValue
            )
            .frame(minWidth: 720, minHeight: 520)
        }
    }

    private var runtimeMetricTint: Color {
        switch workspaceModel.daemonRuntimeStatus.lifecycle {
        case .discovering, .starting, .stopping:
            return .orange
        case .ready:
            return Color(red: 0.30, green: 0.47, blue: 0.69)
        case .running:
            return .green
        case .failed:
            return .red
        }
    }
}

private struct RuntimeMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Text(value)
                .font(.headline)
                .foregroundStyle(Color(red: 0.14, green: 0.17, blue: 0.22))

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(tint.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(tint.opacity(0.15), lineWidth: 1)
                )
        )
    }
}

private struct RuntimePathStorageSheet: View {
    let supportRootPath: String
    let controlFilePath: String
    let logFilePath: String
    let daemonDatabasePath: String
    let jobsDatabasePath: String
    let executablePath: String
    let launchAgentPath: String
    let backgroundServiceValue: String
    let startedAtValue: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LT("Paths + storage", "路径与存储", "パスと保存先"))
                        .font(.title2.weight(.semibold))
                    Text(
                        LT(
                            "These are mostly for debugging launch, storage, or sync issues.",
                            "这些信息主要用于排查启动、存储或同步问题。",
                            "起動・保存・同期トラブルを調べるときに使う情報。"
                        )
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LT("Close", "关闭", "閉じる"))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SectionSurface {
                        VStack(alignment: .leading, spacing: 14) {
                            SettingsStatusRow(
                                title: LT("Background mode", "后台模式", "バックグラウンドモード"),
                                value: backgroundServiceValue
                            )
                            SettingsStatusRow(
                                title: LT("Started at", "启动时间", "起動時刻"),
                                value: startedAtValue
                            )
                            SettingsStatusRow(
                                title: LT("Support root", "支持目录", "サポートルート"),
                                value: supportRootPath
                            )
                            SettingsStatusRow(
                                title: LT("Control file", "控制文件", "制御ファイル"),
                                value: controlFilePath
                            )
                            SettingsStatusRow(
                                title: LT("Log file", "日志文件", "ログファイル"),
                                value: logFilePath
                            )
                            SettingsStatusRow(
                                title: LT("Daemon DB", "Daemon 数据库", "Daemon DB"),
                                value: daemonDatabasePath
                            )
                            SettingsStatusRow(
                                title: LT("Jobs DB", "任务数据库", "ジョブ DB"),
                                value: jobsDatabasePath
                            )
                            SettingsStatusRow(
                                title: LT("Executable", "可执行文件", "実行ファイル"),
                                value: executablePath
                            )
                            SettingsStatusRow(
                                title: LT("LaunchAgent", "LaunchAgent", "LaunchAgent"),
                                value: launchAgentPath
                            )
                            SettingsStatusRow(
                                title: LT("App version", "App 版本", "App バージョン"),
                                value: "\(AppBuildMetadata.displayVersion) · \(AppBuildMetadata.updatedAt)"
                            )
                        }
                    }
                }
                .padding(24)
            }
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
}

private struct DashboardToolbarStatusPill: View {
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
    }
}

private struct DashboardToolbarStrip: View {
    let identityLabel: String
    let runtimeLabel: String
    let runtimeTint: Color
    let approvalCount: Int
    let workerCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Label {
                Text(identityLabel)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "tray.full")
                    .foregroundStyle(Color(red: 0.19, green: 0.31, blue: 0.56))
            }

            MessagePill(label: runtimeLabel, tint: runtimeTint)

            if approvalCount > 0 {
                MessagePill(
                    label: LT(
                        "\(approvalCount) approvals",
                        "\(approvalCount) 个待审批",
                        "承認待ち \(approvalCount) 件"
                    ),
                    tint: .orange
                )
            }

            if workerCount > 0 {
                MessagePill(
                    label: LT(
                        "\(workerCount) running",
                        "\(workerCount) 个执行中",
                        "\(workerCount) 件実行中"
                    ),
                    tint: .blue
                )
            }
        }
    }
}

private struct SettingsSidebarButton: View {
    let pane: OperatorSettingsPane
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: pane.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 18)
                Text(pane.title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color(red: 0.15, green: 0.24, blue: 0.38) : Color(red: 0.30, green: 0.35, blue: 0.41))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.82) : Color.white.opacity(0.34))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(isSelected ? Color(red: 0.31, green: 0.48, blue: 0.68).opacity(0.35) : Color.black.opacity(0.04), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsStatusRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(Color(red: 0.13, green: 0.16, blue: 0.21))
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }
}

private struct SectionSurface<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color.white.opacity(0.56))
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.05), radius: 18, x: 0, y: 8)
        )
    }
}

private struct MessagePill: View {
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
                    .stroke(tint.opacity(0.18), lineWidth: 1)
            )
    }
}

private struct DetailMetaRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .textSelection(.enabled)
        }
    }
}

private struct SelectableBodyText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.body)
            .foregroundStyle(Color(red: 0.13, green: 0.16, blue: 0.21))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.03))
            )
    }
}

private extension Optional where Wrapped == String {
    var trimmedNonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

private struct DashboardView_Previews: PreviewProvider {
    static var previews: some View {
        DashboardView(workspaceModel: MailroomWorkspaceModel())
    }
}
