import Foundation

enum MailboxRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case admin
    case `operator`
    case observer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .admin:
            return LT("Admin", "管理员", "管理者")
        case .operator:
            return LT("Operator", "操作员", "オペレーター")
        case .observer:
            return LT("Observer", "观察者", "オブザーバー")
        }
    }

    var summary: String {
        switch self {
        case .admin:
            return LT("Approve risky actions and manage policy changes.", "批准高风险操作并管理策略变更。", "高リスク操作を承認し、ポリシー変更を管理する。")
        case .operator:
            return LT("Run bounded workflows in approved workspaces.", "在批准的工作区内运行受限工作流。", "承認されたワークスペース内で制限付きワークフローを実行する。")
        case .observer:
            return LT("Request read-only summaries and audit snapshots.", "请求只读摘要和审计快照。", "読み取り専用の要約と監査スナップショットを要求する。")
        }
    }
}

enum MailTransportSecurity: String, Codable, CaseIterable, Identifiable, Sendable {
    case sslTLS
    case startTLS
    case plain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sslTLS:
            return "SSL/TLS"
        case .startTLS:
            return "STARTTLS"
        case .plain:
            return LT("Plain", "明文", "平文")
        }
    }
}

struct MailServerEndpoint: Codable, Hashable, Sendable {
    var host: String
    var port: Int
    var security: MailTransportSecurity
}

struct MailboxAccount: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var label: String
    var emailAddress: String
    var role: MailboxRole
    var workspaceRoot: String
    var imap: MailServerEndpoint
    var smtp: MailServerEndpoint
    var pollingIntervalSeconds: Int
    var createdAt: Date
    var updatedAt: Date

    var connectionSummary: String {
        "IMAP \(imap.host):\(imap.port) • SMTP \(smtp.host):\(smtp.port)"
    }
}

struct ConfiguredMailboxAccount: Identifiable, Hashable, Sendable {
    var account: MailboxAccount
    var hasPasswordStored: Bool

    var id: String { account.id }
}

struct ManagedProject: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var displayName: String
    var slug: String
    var rootPath: String
    var summary: String
    var defaultCapability: MailCapability
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date

    var pathSummary: String {
        rootPath
    }
}

enum MailJobStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case received
    case accepted
    case running
    case waiting
    case succeeded
    case failed
    case rejected

    var id: String { rawValue }

    var title: String {
        switch self {
        case .received:
            return LT("Received", "已接收", "受信済み")
        case .accepted:
            return LT("Accepted", "已接受", "受付済み")
        case .running:
            return LT("Running", "执行中", "実行中")
        case .waiting:
            return LT("Waiting", "等待审批", "レビュー待ち")
        case .succeeded:
            return LT("Succeeded", "成功", "成功")
        case .failed:
            return LT("Failed", "失败", "失敗")
        case .rejected:
            return LT("Rejected", "已拒绝", "拒否")
        }
    }
}

struct ExecutionJobRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var accountID: String?
    var senderAddress: String
    var requestedRole: MailboxRole
    var capability: MailCapability
    var approvalRequirement: ApprovalRequirement
    var action: String
    var subject: String
    var status: MailJobStatus
    var workspaceRoot: String
    var summary: String
    var promptBody: String
    var replyBody: String?
    var errorDetails: String?
    var codexCommand: String?
    var exitCode: Int?
    var receivedAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var updatedAt: Date

    var detailPreview: String? {
        let candidates = [replyBody, errorDetails, promptBody]
        guard let firstValue = candidates
            .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) else {
            return nil
        }

        if firstValue.count <= 220 {
            return firstValue
        }

        return String(firstValue.prefix(220)) + "..."
    }

    static func sample(account: MailboxAccount?) -> ExecutionJobRecord {
        let timestamp = Date()
        return ExecutionJobRecord(
            id: UUID().uuidString,
            accountID: account?.id,
            senderAddress: account?.emailAddress ?? "admin@example.com",
            requestedRole: account?.role ?? .operator,
            capability: .readOnly,
            approvalRequirement: .automatic,
            action: "summarize-latest-session",
            subject: LT("Preview the latest local Codex session", "预览最近一次本地 Codex 会话", "最新のローカル Codex セッションをプレビューする"),
            status: .received,
            workspaceRoot: account?.workspaceRoot ?? "\(NSHomeDirectory())/Workspace",
            summary: LT("Demo job inserted to verify the SQLite-backed queue and audit timeline.", "已插入演示 job，用于验证基于 SQLite 的队列和审计时间线。", "SQLite ベースのキューと監査タイムラインを確認するためのデモジョブを挿入した。"),
            promptBody: LT(
                "Summarize the latest local Codex session and report whether any guarded actions are pending review.",
                "总结最近一次本地 Codex 会话，并说明是否仍有待审批的受保护操作。",
                "最新のローカル Codex セッションを要約し、レビュー待ちの保護付き操作が残っているか報告する。"
            ),
            replyBody: nil,
            errorDetails: nil,
            codexCommand: nil,
            exitCode: nil,
            receivedAt: timestamp,
            startedAt: nil,
            completedAt: nil,
            updatedAt: timestamp
        )
    }
}

struct MailboxAccountDraft: Equatable, Sendable {
    var label: String = ""
    var emailAddress: String = ""
    var role: MailboxRole = .operator
    var workspaceRoot: String = "\(NSHomeDirectory())/Workspace"
    var imapHost: String = ""
    var imapPort: String = "993"
    var imapSecurity: MailTransportSecurity = .sslTLS
    var smtpHost: String = ""
    var smtpPort: String = "465"
    var smtpSecurity: MailTransportSecurity = .sslTLS
    var pollingIntervalSeconds: Int = 60

    static let example = MailboxAccountDraft(
        label: LT("Tokyo Operator", "东京操作员", "東京オペレーター"),
        emailAddress: "codex-tokyo@example.com",
        role: .operator,
        workspaceRoot: "\(NSHomeDirectory())/Workspace",
        imapHost: "imap.example.com",
        imapPort: "993",
        imapSecurity: .sslTLS,
        smtpHost: "smtp.example.com",
        smtpPort: "465",
        smtpSecurity: .sslTLS,
        pollingIntervalSeconds: 60
    )

    static func template(from account: MailboxAccount) -> MailboxAccountDraft {
        MailboxAccountDraft(
            label: account.label,
            emailAddress: account.emailAddress,
            role: account.role,
            workspaceRoot: account.workspaceRoot,
            imapHost: account.imap.host,
            imapPort: String(account.imap.port),
            imapSecurity: account.imap.security,
            smtpHost: account.smtp.host,
            smtpPort: String(account.smtp.port),
            smtpSecurity: account.smtp.security,
            pollingIntervalSeconds: account.pollingIntervalSeconds
        )
    }

    func buildAccount(existingAccount: MailboxAccount? = nil) throws -> MailboxAccount {
        let trimmedEmail = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else {
            throw MailroomValidationError.emptyEmailAddress
        }
        guard trimmedEmail.contains("@") else {
            throw MailroomValidationError.invalidEmailAddress
        }

        let trimmedWorkspace = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWorkspace.isEmpty else {
            throw MailroomValidationError.emptyWorkspaceRoot
        }

        let normalizedLabel: String
        if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalizedLabel = trimmedEmail.split(separator: "@").first.map(String.init)?.capitalized ?? LT("Mailbox", "邮箱", "メールボックス")
        } else {
            normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let imapEndpoint = try MailServerEndpoint(
            host: MailroomValidationError.requireHost(imapHost, label: LT("IMAP host", "IMAP 主机", "IMAP ホスト")),
            port: MailroomValidationError.requirePort(imapPort, label: LT("IMAP port", "IMAP 端口", "IMAP ポート")),
            security: imapSecurity
        )
        let smtpEndpoint = try MailServerEndpoint(
            host: MailroomValidationError.requireHost(smtpHost, label: LT("SMTP host", "SMTP 主机", "SMTP ホスト")),
            port: MailroomValidationError.requirePort(smtpPort, label: LT("SMTP port", "SMTP 端口", "SMTP ポート")),
            security: smtpSecurity
        )

        let timestamp = Date()
        return MailboxAccount(
            id: existingAccount?.id ?? UUID().uuidString,
            label: normalizedLabel,
            emailAddress: trimmedEmail,
            role: role,
            workspaceRoot: trimmedWorkspace,
            imap: imapEndpoint,
            smtp: smtpEndpoint,
            pollingIntervalSeconds: pollingIntervalSeconds,
            createdAt: existingAccount?.createdAt ?? timestamp,
            updatedAt: timestamp
        )
    }
}

struct ManagedProjectDraft: Equatable, Sendable {
    var displayName: String = ""
    var slug: String = ""
    var rootPath: String = "\(NSHomeDirectory())/Workspace/patch-courier"
    var summary: String = ""
    var defaultCapability: MailCapability = .executeShell
    var isEnabled: Bool = true

    static let example = ManagedProjectDraft(
        displayName: "Patch Courier",
        slug: "patch-courier",
        rootPath: "\(NSHomeDirectory())/Workspace/patch-courier",
        summary: LT(
            "Native macOS relay app and daemon.",
            "原生 macOS 信使应用与 daemon。",
            "ネイティブ macOS 中継アプリと daemon。"
        ),
        defaultCapability: .executeShell,
        isEnabled: true
    )

    static func template(from project: ManagedProject) -> ManagedProjectDraft {
        ManagedProjectDraft(
            displayName: project.displayName,
            slug: project.slug,
            rootPath: project.rootPath,
            summary: project.summary,
            defaultCapability: project.defaultCapability,
            isEnabled: project.isEnabled
        )
    }

    func buildProject(existingProject: ManagedProject? = nil) throws -> ManagedProject {
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDisplayName.isEmpty else {
            throw MailroomValidationError.emptyProjectName
        }

        let trimmedRootPath = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRootPath.isEmpty else {
            throw MailroomValidationError.emptyProjectRoot
        }

        let standardizedRootPath = URL(fileURLWithPath: (trimmedRootPath as NSString).expandingTildeInPath)
            .standardizedFileURL
            .path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardizedRootPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MailroomValidationError.projectRootMissing(standardizedRootPath)
        }

        let supportedCapabilities: Set<MailCapability> = [.readOnly, .writeWorkspace, .executeShell, .networkedAccess]
        guard supportedCapabilities.contains(defaultCapability) else {
            throw MailroomValidationError.unsupportedProjectCapability(defaultCapability.title)
        }

        let fallbackSlugSource = trimmedDisplayName.isEmpty
            ? URL(fileURLWithPath: standardizedRootPath).lastPathComponent
            : trimmedDisplayName
        let normalizedSlug = Self.normalizedSlug(
            from: slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackSlugSource : slug,
            existingSlug: existingProject?.slug,
            projectID: existingProject?.id
        )

        let timestamp = Date()
        return ManagedProject(
            id: existingProject?.id ?? UUID().uuidString,
            displayName: trimmedDisplayName,
            slug: normalizedSlug,
            rootPath: standardizedRootPath,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            defaultCapability: defaultCapability,
            isEnabled: isEnabled,
            createdAt: existingProject?.createdAt ?? timestamp,
            updatedAt: timestamp
        )
    }

    static func normalizedSlugCandidate(from rawValue: String) -> String {
        let folded = rawValue
            .folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: .current)
            .lowercased()

        var scalars: [Character] = []
        var previousWasSeparator = false

        for scalar in folded.unicodeScalars {
            switch scalar {
            case "a"..."z", "0"..."9":
                scalars.append(Character(scalar))
                previousWasSeparator = false
            default:
                if !previousWasSeparator, !scalars.isEmpty {
                    scalars.append("-")
                    previousWasSeparator = true
                }
            }
        }

        return String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func normalizedSlug(from rawValue: String, existingSlug: String?, projectID: String?) -> String {
        let slug = normalizedSlugCandidate(from: rawValue)
        if !slug.isEmpty {
            return slug
        }
        if let existingSlug, !existingSlug.isEmpty {
            return existingSlug
        }
        let fallbackID = projectID ?? UUID().uuidString
        return "project-\(fallbackID.prefix(8).lowercased())"
    }
}

enum MailroomValidationError: LocalizedError, Sendable {
    case emptyEmailAddress
    case invalidEmailAddress
    case emptyWorkspaceRoot
    case emptyPassword
    case emptyProjectName
    case emptyProjectRoot
    case projectRootMissing(String)
    case duplicateProjectSlug(String)
    case duplicateProjectRoot(String)
    case unsupportedProjectCapability(String)
    case invalidHost(String)
    case invalidPort(String)

    static func requireHost(_ rawValue: String, label: String) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MailroomValidationError.invalidHost(label)
        }
        return trimmed
    }

    static func requirePort(_ rawValue: String, label: String) throws -> Int {
        guard let port = Int(rawValue), (1...65535).contains(port) else {
            throw MailroomValidationError.invalidPort(label)
        }
        return port
    }

    var errorDescription: String? {
        switch self {
        case .emptyEmailAddress:
            return LT("Mailbox email address is required.", "必须填写邮箱地址。", "メールアドレスが必要です。")
        case .invalidEmailAddress:
            return LT("Mailbox email address must contain @.", "邮箱地址必须包含 @。", "メールアドレスには @ が必要です。")
        case .emptyWorkspaceRoot:
            return LT("Workspace root is required so Codex knows where it can work.", "必须填写工作区根目录，Codex 才知道可以在哪里工作。", "Codex が作業可能な場所を判断できるよう、ワークスペースルートが必要です。")
        case .emptyPassword:
            return LT("An app password is required before the mailbox can be saved.", "保存邮箱前必须填写应用专用密码。", "メールボックスを保存する前にアプリ専用パスワードが必要です。")
        case .emptyProjectName:
            return LT("Project name is required.", "必须填写项目名称。", "プロジェクト名が必要です。")
        case .emptyProjectRoot:
            return LT("Project root path is required.", "必须填写项目根目录。", "プロジェクトのルートパスが必要です。")
        case .projectRootMissing(let path):
            return LT("Project root does not exist or is not a folder: \(path)", "项目根目录不存在，或不是文件夹：\(path)", "プロジェクトルートが存在しないか、フォルダではない: \(path)")
        case .duplicateProjectSlug(let slug):
            return LT("Project slug is already in use: \(slug)", "项目短名已被使用：\(slug)", "プロジェクト slug はすでに使われている: \(slug)")
        case .duplicateProjectRoot(let path):
            return LT("Project root is already managed: \(path)", "这个项目根目录已经在管理列表里：\(path)", "このプロジェクトルートはすでに管理対象: \(path)")
        case .unsupportedProjectCapability(let capability):
            return LT("Managed projects only support read, write, shell, or network capabilities. Current value: \(capability)", "受管项目只支持只读、写入、命令或网络能力。当前值：\(capability)", "管理対象プロジェクトは read / write / shell / network のみ対応。現在の値: \(capability)")
        case .invalidHost(let label):
            return LT("\(label) cannot be empty.", "\(label) 不能为空。", "\(label) は空にできません。")
        case .invalidPort(let label):
            return LT("\(label) must be a number between 1 and 65535.", "\(label) 必须是 1 到 65535 之间的数字。", "\(label) は 1 から 65535 の数値である必要があります。")
        }
    }
}
