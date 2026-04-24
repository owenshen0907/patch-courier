import Foundation

struct CodexMailRequest: Identifiable, Hashable, Sendable {
    var id: String
    var mailboxAccountID: String?
    var senderAddress: String
    var subject: String
    var capability: MailCapability
    var workspaceRoot: String
    var actionSummary: String
    var promptBody: String
    var replyToken: String?
    var receivedAt: Date

    static func preview(
        from preview: MailPolicyRequestPreview,
        matchedPolicy: SenderPolicy?,
        mailboxAccountID: String?
    ) -> CodexMailRequest {
        let trimmedAction = preview.actionSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAction = trimmedAction.isEmpty
            ? LT(
                "Describe the current workspace status.",
                "描述当前工作区状态。",
                "現在のワークスペース状態を説明する。"
            )
            : trimmedAction
        return CodexMailRequest(
            id: UUID().uuidString,
            mailboxAccountID: mailboxAccountID,
            senderAddress: preview.senderAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            subject: inferredSubject(from: normalizedAction),
            capability: preview.capability,
            workspaceRoot: preview.workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines),
            actionSummary: normalizedAction,
            promptBody: normalizedAction,
            replyToken: matchedPolicy?.requiresReplyToken == true && preview.replyTokenPresent ? "preview-token" : nil,
            receivedAt: Date()
        )
    }

    private static func inferredSubject(from actionSummary: String) -> String {
        let trimmed = actionSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return LT("Mailroom preview task", "Mailroom 预览任务", "Mailroom プレビュータスク")
        }

        if trimmed.count <= 72 {
            return trimmed
        }

        return String(trimmed.prefix(72)) + "..."
    }
}

struct CodexExecutionResult: Hashable, Sendable {
    var status: MailJobStatus
    var exitCode: Int
    var stdout: String
    var stderr: String
    var finalReply: String
    var mailResponse: MailroomAgentResponse
    var commandDescription: String
    var startedAt: Date
    var completedAt: Date

    var summary: String {
        if let summary = mailResponse.summary.nilIfBlank {
            return summary
        }

        switch status {
        case .succeeded:
            return LT("Codex completed the approved request and prepared a reply draft.", "Codex 已完成批准请求，并生成了回复草稿。", "Codex が承認済み要求を完了し、返信草稿を用意した。")
        case .waiting:
            return LT("Codex needs more information before it can continue.", "Codex 需要更多信息后才能继续。", "Codex は続行前に追加情報を必要としている。")
        case .failed:
            return LT("Codex stopped before it could prepare a successful reply.", "Codex 在生成成功回复前就已停止。", "Codex は成功した返信を準備する前に停止した。")
        default:
            return LT("Codex returned an unexpected execution state.", "Codex 返回了意外的执行状态。", "Codex が想定外の执行状态を返した。")
        }
    }
}

enum MailroomAgentResponseParser {
    private static let blockPattern = #"MAILROOM_RESPONSE_KIND:\s*(FINAL|NEED_INPUT)\s*\nMAILROOM_SUBJECT:\s*(.*)\s*\nMAILROOM_SUMMARY:\s*(.*)\s*\nMAILROOM_BODY:\s*\n([\s\S]*)"#

    static func parse(rawText: String, fallbackSubject: String, status: MailJobStatus) -> MailroomAgentResponse {
        guard let regex = try? NSRegularExpression(pattern: blockPattern, options: [.caseInsensitive]),
              let match = regex.matches(
                in: rawText,
                options: [],
                range: NSRange(rawText.startIndex..<rawText.endIndex, in: rawText)
              ).last,
              let kindRange = Range(match.range(at: 1), in: rawText),
              let subjectRange = Range(match.range(at: 2), in: rawText),
              let summaryRange = Range(match.range(at: 3), in: rawText),
              let bodyRange = Range(match.range(at: 4), in: rawText) else {
            return MailroomAgentResponse.fallback(subject: fallbackSubject, rawText: rawText, status: status)
        }

        let rawKind = rawText[kindRange].uppercased()
        let parsedKind: MailroomAgentResponseKind = rawKind == "NEED_INPUT" ? .needInput : .final
        let parsedSubject = rawText[subjectRange].trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedSummary = rawText[summaryRange].trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedBody = rawText[bodyRange].trimmingCharacters(in: .whitespacesAndNewlines)

        return MailroomAgentResponse(
            kind: parsedKind,
            subject: parsedSubject.isEmpty ? fallbackSubject : parsedSubject,
            summary: parsedSummary,
            body: parsedBody,
            rawText: rawText
        )
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
