import Foundation

struct CodexBridge: Sendable {
    let jobStore: SQLiteJobStore
    let mailroomSkillURL: URL?
    let executableCandidates: [String]

    init(
        jobStore: SQLiteJobStore,
        mailroomSkillURL: URL? = nil,
        executableCandidates: [String] = [
            ProcessInfo.processInfo.environment["CODEX_CLI_PATH"],
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ].compactMap { $0 }
    ) {
        self.jobStore = jobStore
        self.mailroomSkillURL = mailroomSkillURL
        self.executableCandidates = executableCandidates
    }

    static var isLocalExecutionSupported: Bool {
        true
    }

    func handle(
        request: CodexMailRequest,
        decision: MailPolicyDecision,
        fallbackRole: MailboxRole,
        assumeReviewApproved: Bool
    ) throws -> ExecutionJobRecord {
        let role = decision.effectiveRole ?? fallbackRole

        switch decision.requirement {
        case .denied:
            let rejectedJob = makeJob(
                id: request.id,
                request: request,
                role: role,
                requirement: decision.requirement,
                status: .rejected,
                summary: decision.reason,
                errorDetails: decision.nextStep,
                updatedAt: Date()
            )
            try jobStore.insert(rejectedJob)
            return rejectedJob

        case .adminReview where !assumeReviewApproved:
            let queuedJob = makeJob(
                id: request.id,
                request: request,
                role: role,
                requirement: decision.requirement,
                status: .waiting,
                summary: LT("Queued for explicit admin review before launching local Codex.", "已排入管理员审批队列，等待启动本地 Codex。", "ローカル Codex 起動前に管理者レビュー待ちへ入れた。"),
                errorDetails: decision.reason,
                updatedAt: Date()
            )
            try jobStore.insert(queuedJob)
            return queuedJob

        case .automatic, .adminReview:
            let launchSummary = decision.requirement == .automatic
                ? LT("Launching local Codex for an automatically approved request.", "该请求已自动批准，正在启动本地 Codex。", "自動承認された要求としてローカル Codex を起動する。")
                : LT("Admin review simulated as approved; launching local Codex.", "已模拟管理员审批通过，正在启动本地 Codex。", "管理者レビュー承認済みとしてローカル Codex を起動する。")
            let runningJob = makeJob(
                id: request.id,
                request: request,
                role: role,
                requirement: decision.requirement,
                status: .running,
                summary: launchSummary,
                updatedAt: Date(),
                startedAt: Date()
            )
            try jobStore.insert(runningJob)

            do {
                let result = try runCodex(request: request, decision: decision, role: role)
                let completedStatus: MailJobStatus = result.mailResponse.kind == .needInput ? .waiting : result.status
                let completedJob = makeJob(
                    id: request.id,
                    request: request,
                    role: role,
                    requirement: decision.requirement,
                    status: completedStatus,
                    summary: result.summary,
                    replyBody: result.mailResponse.body.nilIfEmpty ?? result.finalReply,
                    errorDetails: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                    codexCommand: result.commandDescription,
                    exitCode: result.exitCode,
                    updatedAt: result.completedAt,
                    startedAt: result.startedAt,
                    completedAt: result.completedAt
                )
                try jobStore.insert(completedJob)
                return completedJob
            } catch {
                let failureTime = Date()
                let failedJob = makeJob(
                    id: request.id,
                    request: request,
                    role: role,
                    requirement: decision.requirement,
                    status: .failed,
                    summary: error.localizedDescription,
                    errorDetails: error.localizedDescription,
                    updatedAt: failureTime,
                    startedAt: runningJob.startedAt,
                    completedAt: failureTime
                )
                try jobStore.insert(failedJob)
                return failedJob
            }
        }
    }

    private func makeJob(
        id: String,
        request: CodexMailRequest,
        role: MailboxRole,
        requirement: ApprovalRequirement,
        status: MailJobStatus,
        summary: String,
        replyBody: String? = nil,
        errorDetails: String? = nil,
        codexCommand: String? = nil,
        exitCode: Int? = nil,
        updatedAt: Date,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) -> ExecutionJobRecord {
        ExecutionJobRecord(
            id: id,
            accountID: request.mailboxAccountID,
            senderAddress: request.senderAddress,
            requestedRole: role,
            capability: request.capability,
            approvalRequirement: requirement,
            action: request.actionSummary,
            subject: request.subject,
            status: status,
            workspaceRoot: request.workspaceRoot,
            summary: summary,
            promptBody: request.promptBody,
            replyBody: replyBody,
            errorDetails: errorDetails,
            codexCommand: codexCommand,
            exitCode: exitCode,
            receivedAt: request.receivedAt,
            startedAt: startedAt,
            completedAt: completedAt,
            updatedAt: updatedAt
        )
    }

    private func runCodex(
        request: CodexMailRequest,
        decision: MailPolicyDecision,
        role: MailboxRole
    ) throws -> CodexExecutionResult {
        let fileManager = FileManager.default
        let workspaceURL = URL(fileURLWithPath: request.workspaceRoot, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: workspaceURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CodexBridgeError.workspaceRootMissing(request.workspaceRoot)
        }

        let executableURL = try resolveExecutableURL()
        let prompt = buildPrompt(for: request, decision: decision, role: role)
        let sandboxMode = sandboxMode(for: request.capability)
        let commandDescription = renderedCommand(
            executableURL: executableURL,
            sandboxMode: sandboxMode,
            workspaceRoot: request.workspaceRoot
        )

        let artifactsDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("patch-courier", isDirectory: true)
            .appendingPathComponent(request.id, isDirectory: true)
        try fileManager.createDirectory(at: artifactsDirectory, withIntermediateDirectories: true, attributes: nil)

        let stdoutURL = artifactsDirectory.appendingPathComponent("stdout.log")
        let stderrURL = artifactsDirectory.appendingPathComponent("stderr.log")
        let lastMessageURL = artifactsDirectory.appendingPathComponent("last-message.txt")
        _ = fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        _ = fileManager.createFile(atPath: stderrURL.path, contents: nil)

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "-a", "never",
            "exec",
            "-s", sandboxMode,
            "-C", request.workspaceRoot,
            "--color", "never",
            "--skip-git-repo-check",
            "--ephemeral",
            "-o", lastMessageURL.path,
            prompt
        ]
        process.currentDirectoryURL = workspaceURL
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        let startedAt = Date()
        do {
            try process.run()
        } catch {
            throw CodexBridgeError.launchFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        let completedAt = Date()

        let stdout = readText(at: stdoutURL)
        let stderr = readText(at: stderrURL)
        let finalReply = readText(at: lastMessageURL).nilIfEmpty ?? stdout.nilIfEmpty ?? stderr
        let status: MailJobStatus = process.terminationStatus == 0 ? .succeeded : .failed
        let parsedResponse = MailroomAgentResponseParser.parse(
            rawText: finalReply,
            fallbackSubject: request.subject,
            status: status
        )

        return CodexExecutionResult(
            status: status,
            exitCode: Int(process.terminationStatus),
            stdout: stdout,
            stderr: stderr,
            finalReply: finalReply,
            mailResponse: parsedResponse,
            commandDescription: commandDescription,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    private func buildPrompt(
        for request: CodexMailRequest,
        decision: MailPolicyDecision,
        role: MailboxRole
    ) -> String {
        let replyTokenState = request.replyToken == nil ? "missing" : "present"
        let skillLine: String
        if let mailroomSkillURL {
            skillLine = "Use [$mailroom-email-loop](\(mailroomSkillURL.path)) for your response format."
        } else {
            skillLine = "Use the Mailroom response format with MAILROOM_RESPONSE_KIND / SUBJECT / SUMMARY / BODY markers."
        }
        return """
        You are handling a Patch Courier task that originated from an approved email workflow.

        \(skillLine)

        Sender: \(request.senderAddress)
        Assigned role: \(role.title)
        Capability: \(request.capability.title)
        Approval gate: \(decision.requirement.title)
        Workspace root: \(request.workspaceRoot)
        Subject: \(request.subject)
        Reply token: \(replyTokenState)

        Request:
        \(request.promptBody)

        Guardrails:
        - Work only inside the approved workspace root.
        - Respect the capability boundary: \(request.capability.summary)
        - If more information is required, use the structured NEED_INPUT response instead of stopping with a generic blocker.
        - Return a concise operator-ready response with result, evidence, changed files, and next step.
        """
    }

    private func sandboxMode(for capability: MailCapability) -> String {
        switch capability {
        case .readOnly:
            return "read-only"
        case .writeWorkspace, .executeShell, .networkedAccess, .secretAndConfig, .destructiveChange:
            return "workspace-write"
        }
    }

    private func resolveExecutableURL() throws -> URL {
        let fileManager = FileManager.default
        if let candidate = executableCandidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: candidate)
        }
        throw CodexBridgeError.executableNotFound
    }

    private func renderedCommand(
        executableURL: URL,
        sandboxMode: String,
        workspaceRoot: String
    ) -> String {
        "\(executableURL.path) -a never exec -s \(sandboxMode) -C \(workspaceRoot) --color never --skip-git-repo-check --ephemeral -o <last-message-file> <prompt>"
    }

    private func readText(at url: URL) -> String {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return ""
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CodexBridgeError: LocalizedError, Sendable {
    case executableNotFound
    case workspaceRootMissing(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return LT("Could not find the Codex CLI executable. Install Codex or set CODEX_CLI_PATH first.", "找不到 Codex CLI 可执行文件。请先安装 Codex 或设置 CODEX_CLI_PATH。", "Codex CLI 実行ファイルが見つからない。Codex をインストールするか CODEX_CLI_PATH を設定してください。")
        case .workspaceRootMissing(let path):
            return LT("The requested workspace root does not exist: \(path)", "请求的工作区根目录不存在：\(path)", "要求されたワークスペースルートが存在しない: \(path)")
        case .launchFailed(let message):
            return LT("Codex could not start the local execution process: \(message)", "Codex 无法启动本地执行进程：\(message)", "Codex がローカル実行プロセスを起動できない: \(message)")
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
