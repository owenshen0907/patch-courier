import Foundation

enum MailCapability: String, Codable, CaseIterable, Identifiable, Sendable {
    case readOnly
    case writeWorkspace
    case executeShell
    case networkedAccess
    case secretAndConfig
    case destructiveChange

    var id: String { rawValue }

    var title: String {
        switch self {
        case .readOnly:
            return LT("Read-only", "只读", "読み取り専用")
        case .writeWorkspace:
            return LT("Write workspace", "写入工作区", "ワークスペース書き込み")
        case .executeShell:
            return LT("Execute shell", "执行命令", "シェル実行")
        case .networkedAccess:
            return LT("Networked access", "网络访问", "ネットワークアクセス")
        case .secretAndConfig:
            return LT("Secrets and config", "密钥与配置", "秘密情報と設定")
        case .destructiveChange:
            return LT("Destructive change", "破坏性变更", "破壊的変更")
        }
    }

    var summary: String {
        switch self {
        case .readOnly:
            return LT("Inspect files, logs, and workspace state without writing changes.", "检查文件、日志和工作区状态，但不写入任何变更。", "ファイル、ログ、ワークスペース状態を確認するが、変更は書き込まない。")
        case .writeWorkspace:
            return LT("Edit approved local files inside allowed workspaces.", "在允许的工作区内编辑已批准的本地文件。", "許可されたワークスペース内で承認済みのローカルファイルを編集する。")
        case .executeShell:
            return LT("Run local commands, scripts, or build tooling on the machine.", "在本机运行本地命令、脚本或构建工具。", "このマシン上でローカルコマンド、スクリプト、ビルドツールを実行する。")
        case .networkedAccess:
            return LT("Use networked tools or actions that reach external services.", "使用会访问外部服务的联网工具或操作。", "外部サービスへ到達するネットワークツールや操作を利用する。")
        case .secretAndConfig:
            return LT("Read or change mailbox config, tokens, secrets, or policy files.", "读取或修改邮箱配置、token、密钥或策略文件。", "メール設定、トークン、秘密情報、ポリシーファイルを読み取る、または変更する。")
        case .destructiveChange:
            return LT("Delete content, reset state, or make other hard-to-undo changes.", "删除内容、重置状态，或执行其他难以撤销的变更。", "内容削除、状態リセット、その他取り消しにくい変更を行う。")
        }
    }
}

enum ApprovalRequirement: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case adminReview
    case denied

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            return LT("Automatic", "自动执行", "自動実行")
        case .adminReview:
            return LT("Admin review", "管理员审批", "管理者レビュー")
        case .denied:
            return LT("Denied", "拒绝", "拒否")
        }
    }
}

struct RoleCapabilityRule: Codable, Hashable, Identifiable, Sendable {
    var capability: MailCapability
    var requirement: ApprovalRequirement
    var rationale: String

    var id: String { capability.id }
}

struct RolePolicyProfile: Codable, Hashable, Identifiable, Sendable {
    var role: MailboxRole
    var rules: [RoleCapabilityRule]

    var id: String { role.id }

    func rule(for capability: MailCapability) -> RoleCapabilityRule {
        rules.first(where: { $0.capability == capability })
            ?? RoleCapabilityRule(
                capability: capability,
                requirement: .denied,
                rationale: LT("No rule exists for this capability in the role matrix.", "角色矩阵中没有为此能力定义规则。", "この権限カテゴリに対応するルールがロールマトリクスに存在しない。")
            )
    }
}

struct SenderPolicy: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var displayName: String
    var senderAddress: String
    var assignedRole: MailboxRole
    var allowedWorkspaceRoots: [String]
    var requiresReplyToken: Bool
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date

    var normalizedSenderAddress: String {
        senderAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var workspaceSummary: String {
        allowedWorkspaceRoots.joined(separator: ", ")
    }
}

struct SenderPolicyDraft: Equatable, Sendable {
    var displayName: String = ""
    var senderAddress: String = ""
    var assignedRole: MailboxRole = .operator
    var workspaceRootsText: String = "\(NSHomeDirectory())/Workspace"
    var requiresReplyToken: Bool = true
    var isEnabled: Bool = true

    static let exampleAdmin = SenderPolicyDraft(
        displayName: LT("Primary Admin", "主管理员", "メイン管理者"),
        senderAddress: "admin@example.com",
        assignedRole: .admin,
        workspaceRootsText: "\(NSHomeDirectory())/Workspace",
        requiresReplyToken: true,
        isEnabled: true
    )

    static func template(from policy: SenderPolicy) -> SenderPolicyDraft {
        SenderPolicyDraft(
            displayName: policy.displayName,
            senderAddress: policy.senderAddress,
            assignedRole: policy.assignedRole,
            workspaceRootsText: workspaceRootsText(from: policy.allowedWorkspaceRoots),
            requiresReplyToken: policy.requiresReplyToken,
            isEnabled: policy.isEnabled
        )
    }

    func buildPolicy(existingPolicy: SenderPolicy? = nil) throws -> SenderPolicy {
        let trimmedSender = senderAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedSender.isEmpty else {
            throw MailPolicyValidationError.emptySenderAddress
        }
        guard trimmedSender.contains("@") else {
            throw MailPolicyValidationError.invalidSenderAddress
        }

        let roots = Self.normalizedWorkspaceRoots(from: workspaceRootsText)

        guard !roots.isEmpty else {
            throw MailPolicyValidationError.emptyWorkspaceAllowlist
        }

        let normalizedDisplayName: String
        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalizedDisplayName = trimmedSender.split(separator: "@").first.map(String.init)?.capitalized ?? LT("Sender", "发件人", "送信者")
        } else {
            normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let timestamp = Date()
        return SenderPolicy(
            id: existingPolicy?.id ?? UUID().uuidString,
            displayName: normalizedDisplayName,
            senderAddress: trimmedSender,
            assignedRole: assignedRole,
            allowedWorkspaceRoots: roots,
            requiresReplyToken: requiresReplyToken,
            isEnabled: isEnabled,
            createdAt: existingPolicy?.createdAt ?? timestamp,
            updatedAt: timestamp
        )
    }

    static func normalizedWorkspaceRoots(from rawValue: String) -> [String] {
        var roots: [String] = []
        var seen: Set<String> = []

        for root in rawValue
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .filter({ !$0.isEmpty }) {
            let standardizedRoot = URL(fileURLWithPath: (root as NSString).expandingTildeInPath)
                .standardizedFileURL
                .path
            let normalizedRoot = standardizedRoot.lowercased()
            if seen.insert(normalizedRoot).inserted {
                roots.append(standardizedRoot)
            }
        }

        return roots
    }

    static func workspaceRootsText(from roots: [String]) -> String {
        roots.joined(separator: "\n")
    }
}

struct MailPolicyRequestPreview: Hashable, Sendable {
    var senderAddress: String
    var capability: MailCapability
    var workspaceRoot: String
    var replyTokenPresent: Bool
    var actionSummary: String

    static let example = MailPolicyRequestPreview(
        senderAddress: "ops@example.com",
        capability: .executeShell,
        workspaceRoot: "\(NSHomeDirectory())/Workspace/patch-courier",
        replyTokenPresent: false,
        actionSummary: LT(
            "Run xcodebuild to verify the current workspace.",
            "运行 xcodebuild 验证当前工作区。",
            "xcodebuild を実行して現在のワークスペースを確認する。"
        )
    )
}

struct MailPolicyDecision: Hashable, Sendable {
    var senderAddress: String
    var matchedPolicy: SenderPolicy?
    var effectiveRole: MailboxRole?
    var capability: MailCapability
    var requirement: ApprovalRequirement
    var reason: String
    var nextStep: String
}

enum MailPolicyValidationError: LocalizedError, Sendable {
    case emptySenderAddress
    case invalidSenderAddress
    case emptyWorkspaceAllowlist

    var errorDescription: String? {
        switch self {
        case .emptySenderAddress:
            return LT("Sender address is required before a policy can be saved.", "保存策略前必须填写发件人地址。", "ポリシーを保存する前に送信者アドレスが必要です。")
        case .invalidSenderAddress:
            return LT("Sender address must contain @.", "发件人地址必须包含 @。", "送信者アドレスには @ が必要です。")
        case .emptyWorkspaceAllowlist:
            return LT("At least one allowed workspace root is required.", "至少需要一个允许的工作区根目录。", "少なくとも 1 つの許可済みワークスペースルートが必要です。")
        }
    }
}
