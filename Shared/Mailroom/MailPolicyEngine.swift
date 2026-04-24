import Foundation

struct MailPolicyEngine {
    static var defaultProfiles: [RolePolicyProfile] {
        let language = AppLanguageOption.currentResolved()
        return [
            RolePolicyProfile(
                role: .admin,
                rules: [
                    RoleCapabilityRule(capability: .readOnly, requirement: .automatic, rationale: language.text("Admin senders can inspect local state without delay.", "管理员发件人可以直接检查本地状态。", "管理者送信者はローカル状態を即時に確認できる。")),
                    RoleCapabilityRule(capability: .writeWorkspace, requirement: .automatic, rationale: language.text("Admin senders can update files inside allowed roots.", "管理员发件人可以更新允许根目录内的文件。", "管理者送信者は許可されたルート内のファイルを更新できる。")),
                    RoleCapabilityRule(capability: .executeShell, requirement: .adminReview, rationale: language.text("Local command execution is risky enough to require a queue review.", "本地命令执行风险较高，需要进入审批队列。", "ローカルコマンド実行はリスクが高く、レビューキューを必要とする。")),
                    RoleCapabilityRule(capability: .networkedAccess, requirement: .adminReview, rationale: language.text("External network activity should be reviewed before release.", "任何外部网络活动都应先经过审批。", "外部ネットワーク操作は実行前にレビューすべきである。")),
                    RoleCapabilityRule(capability: .secretAndConfig, requirement: .adminReview, rationale: language.text("Secret and config changes should never auto-run from email alone.", "密钥和配置变更不能仅凭邮件自动执行。", "秘密情報や設定変更はメールだけで自動実行してはならない。")),
                    RoleCapabilityRule(capability: .destructiveChange, requirement: .adminReview, rationale: language.text("Destructive work must stay behind an explicit review gate.", "破坏性操作必须保留在明确的审批门之后。", "破壊的な作業は明示的なレビューゲートの後ろに置く必要がある。"))
                ]
            ),
            RolePolicyProfile(
                role: .operator,
                rules: [
                    RoleCapabilityRule(capability: .readOnly, requirement: .automatic, rationale: language.text("Operators can request summaries and inspection safely.", "操作员可以安全地请求摘要和检查。", "オペレーターは安全に要約や確認を要求できる。")),
                    RoleCapabilityRule(capability: .writeWorkspace, requirement: .automatic, rationale: language.text("Operators can edit approved local workspaces.", "操作员可以编辑已批准的本地工作区。", "オペレーターは承認済みのローカルワークスペースを編集できる。")),
                    RoleCapabilityRule(capability: .executeShell, requirement: .adminReview, rationale: language.text("Command execution escalates beyond normal write access.", "命令执行超出了普通写入权限。", "コマンド実行は通常の書き込み権限を超える。")),
                    RoleCapabilityRule(capability: .networkedAccess, requirement: .adminReview, rationale: language.text("Networked actions can leak data or trigger external effects.", "联网操作可能泄露数据或触发外部副作用。", "ネットワーク操作はデータ漏えいや外部副作用を引き起こす可能性がある。")),
                    RoleCapabilityRule(capability: .secretAndConfig, requirement: .denied, rationale: language.text("Operators cannot read or change secrets or control-plane config.", "操作员不能读取或修改密钥或控制面配置。", "オペレーターは秘密情報や制御プレーン設定を読み書きできない。")),
                    RoleCapabilityRule(capability: .destructiveChange, requirement: .denied, rationale: language.text("Operators cannot trigger destructive actions from email.", "操作员不能通过邮件触发破坏性操作。", "オペレーターはメールから破壊的操作を起動できない。"))
                ]
            ),
            RolePolicyProfile(
                role: .observer,
                rules: [
                    RoleCapabilityRule(capability: .readOnly, requirement: .automatic, rationale: language.text("Observers can ask for status-only responses.", "观察者只能请求状态类回复。", "オブザーバーは状態確認の返信のみ要求できる。")),
                    RoleCapabilityRule(capability: .writeWorkspace, requirement: .denied, rationale: language.text("Observers are read-only by design.", "观察者按设计就是只读。", "オブザーバーは設計上読み取り専用である。")),
                    RoleCapabilityRule(capability: .executeShell, requirement: .denied, rationale: language.text("Observers cannot launch local execution.", "观察者不能发起本地执行。", "オブザーバーはローカル実行を起動できない。")),
                    RoleCapabilityRule(capability: .networkedAccess, requirement: .denied, rationale: language.text("Observers cannot trigger external effects.", "观察者不能触发外部副作用。", "オブザーバーは外部副作用を引き起こせない。")),
                    RoleCapabilityRule(capability: .secretAndConfig, requirement: .denied, rationale: language.text("Observers cannot touch secrets or policy.", "观察者不能接触密钥或策略。", "オブザーバーは秘密情報やポリシーに触れられない。")),
                    RoleCapabilityRule(capability: .destructiveChange, requirement: .denied, rationale: language.text("Observers cannot trigger destructive changes.", "观察者不能触发破坏性变更。", "オブザーバーは破壊的変更を起動できない。"))
                ]
            )
        ]
    }

    func evaluate(request: MailPolicyRequestPreview, senderPolicies: [SenderPolicy]) -> MailPolicyDecision {
        let normalizedSender = request.senderAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedWorkspace = normalize(path: request.workspaceRoot)
        let language = AppLanguageOption.currentResolved()

        guard let policy = senderPolicies.first(where: {
            $0.isEnabled && $0.normalizedSenderAddress == normalizedSender
        }) else {
            return MailPolicyDecision(
                senderAddress: normalizedSender,
                matchedPolicy: nil,
                effectiveRole: nil,
                capability: request.capability,
                requirement: .denied,
                reason: language.text("Sender is not in the local allowlist.", "发件人不在本地白名单中。", "送信者がローカル許可リストに存在しない。"),
                nextStep: language.text("Add the sender to the allowlist before processing email commands.", "请先把发件人加入白名单，再处理邮件指令。", "メール指示を処理する前に送信者を許可リストへ追加する。")
            )
        }

        guard policy.allowedWorkspaceRoots.contains(where: { workspaceAllowed(normalizedWorkspace, root: $0) }) else {
            return MailPolicyDecision(
                senderAddress: normalizedSender,
                matchedPolicy: policy,
                effectiveRole: policy.assignedRole,
                capability: request.capability,
                requirement: .denied,
                reason: language.text("The requested workspace is outside the sender's approved roots.", "请求的工作区超出了该发件人的允许根目录。", "要求されたワークスペースが送信者に許可されたルート外にある。"),
                nextStep: language.text("Narrow the workspace or update the sender policy allowlist.", "请收窄工作区，或更新该发件人的允许目录。", "ワークスペースを絞り込むか、送信者ポリシーの許可ルートを更新する。")
            )
        }

        if policy.requiresReplyToken && !request.replyTokenPresent {
            return MailPolicyDecision(
                senderAddress: normalizedSender,
                matchedPolicy: policy,
                effectiveRole: policy.assignedRole,
                capability: request.capability,
                requirement: .denied,
                reason: language.text("This sender needs a first-mail confirmation before email can become a runnable task.", "该发件人在邮件变成可执行任务前，需要先完成一次首封确认。", "この送信者は、メールを実行可能なタスクにする前に初回確認が必要である。"),
                nextStep: language.text("Ask the sender to reply to the confirmation email and choose start-task or record-only.", "要求对方回复确认邮件，并明确选择“启动任务”或“仅记录”。", "確認メールに返信して、タスク開始か記録のみかを選んでもらう。")
            )
        }

        let profile = Self.defaultProfiles.first(where: { $0.role == policy.assignedRole })
        let rule = profile?.rule(for: request.capability)
            ?? RoleCapabilityRule(
                capability: request.capability,
                requirement: .denied,
                rationale: language.text("No rule exists for this capability in the role matrix.", "角色矩阵中没有为此能力定义规则。", "この権限カテゴリに対応するルールがロールマトリクスに存在しない。")
            )

        let nextStep: String
        switch rule.requirement {
        case .automatic:
            nextStep = language.text("This request can move straight into the Codex job queue.", "该请求可以直接进入 Codex job 队列。", "この要求はそのまま Codex ジョブキューへ進められる。")
        case .adminReview:
            nextStep = language.text("Queue the request for explicit review in the local operator console before execution.", "执行前需要先进入本地操作台的审批队列。", "実行前にローカルオペレーターコンソールで明示的なレビューへ回す。")
        case .denied:
            nextStep = language.text("Reject the request and return the rationale in the reply email.", "拒绝该请求，并在回复邮件中返回原因。", "要求を拒否し、その理由を返信メールで返す。")
        }

        return MailPolicyDecision(
            senderAddress: normalizedSender,
            matchedPolicy: policy,
            effectiveRole: policy.assignedRole,
            capability: request.capability,
            requirement: rule.requirement,
            reason: rule.rationale,
            nextStep: nextStep
        )
    }

    private func normalize(path: String) -> String {
        let expandedPath = (path as NSString).expandingTildeInPath
        return (expandedPath as NSString).standardizingPath.lowercased()
    }

    private func workspaceAllowed(_ normalizedWorkspace: String, root rawRoot: String) -> Bool {
        let normalizedRoot = normalize(path: rawRoot)
        guard !normalizedRoot.isEmpty else {
            return false
        }
        return normalizedWorkspace == normalizedRoot || normalizedWorkspace.hasPrefix(normalizedRoot + "/")
    }
}
