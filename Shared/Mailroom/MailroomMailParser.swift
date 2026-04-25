import Foundation

enum MailroomMailParser {
    private static let tokenPattern = #"\[(?:patch-courier|codex-mailroom):([A-Z0-9-]+)\]"#
    private static let statusPrefixPattern = #"^\[((?:patch courier|mailroom) [^\]]+)\]\s*"#
    private static let replyPrefixes = ["re:", "fw:", "fwd:"]
    private static let fieldSeparators: [Character] = [":", "："]
    private static let ignoredHeaderKeys: Set<String> = [
        "thread",
        "thread token",
        "token",
        "reply token",
        "role",
        "线程",
        "线程令牌",
        "令牌",
        "身份",
        "角色"
    ]

    static func parseCommand(
        from message: InboundMailMessage,
        fallbackWorkspaceRoot: String
    ) -> MailroomParsedCommand {
        let token = extractReplyToken(subject: message.subject, body: message.plainBody)
        let strippedBody = stripQuotedReplyChain(from: message.plainBody)
        let parsedFields = parseFields(from: strippedBody)
        let cleanedSubject = normalizeSubject(message.subject)
        let contentBody = parsedFields.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceRoot = parsedFields.workspaceRoot?.nilIfBlank ?? fallbackWorkspaceRoot
        let capability = capability(from: parsedFields.capabilityRaw) ?? .writeWorkspace
        let explicitPromptBody = parsedFields.action?.nilIfBlank ?? contentBody.nilIfBlank

        let actionSummary: String
        if let action = parsedFields.action?.nilIfBlank {
            actionSummary = action
        } else if let firstLine = contentBody
            .split(whereSeparator: \.isNewline)
            .map({ String($0).trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            actionSummary = String(firstLine.prefix(120))
        } else if !cleanedSubject.isEmpty {
            actionSummary = cleanedSubject
        } else {
            actionSummary = LT(
                "Review the latest mail request.",
                "处理最新邮件请求。",
                "最新のメール要求を処理する。"
            )
        }

        let promptBody = explicitPromptBody ?? actionSummary

        return MailroomParsedCommand(
            cleanedSubject: cleanedSubject.isEmpty ? actionSummary : cleanedSubject,
            workspaceRoot: workspaceRoot,
            capability: capability,
            actionSummary: actionSummary,
            promptBody: promptBody,
            explicitPromptBody: explicitPromptBody,
            projectReference: parsedFields.projectReference?.nilIfBlank,
            detectedToken: token
        )
    }

    static func extractReplyToken(subject: String, body: String) -> String? {
        let haystack = subject + "\n" + body
        guard let regex = try? NSRegularExpression(pattern: tokenPattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
        guard let match = regex.firstMatch(in: haystack, options: [], range: range),
              let tokenRange = Range(match.range(at: 1), in: haystack) else {
            return nil
        }
        return haystack[tokenRange].uppercased()
    }

    static func parseEvoMapCommand(from message: InboundMailMessage) -> MailroomEvoMapCommand? {
        let strippedBody = stripQuotedReplyChain(from: message.plainBody)
        let fields = parseAutomationFields(from: strippedBody)
        let subject = normalizeSubject(message.subject)
        let commandValue = fields["PATCH_COURIER_COMMAND"]
            ?? fields["COMMAND"]
            ?? subjectEvoMapCommand(from: subject)

        guard let commandValue else {
            return nil
        }

        let kind: MailroomEvoMapCommandKind
        switch normalizeAutomationKey(commandValue) {
        case "EVOMAP_EXECUTE":
            kind = .execute
        case "EVOMAP_STATUS":
            kind = .status
        default:
            return nil
        }

        let requestID = fields["REQUEST_ID"]?.nilIfBlank
        let taskID = fields["TASK_ID"]?.nilIfBlank
            ?? taskIDFromRequestID(requestID)
            ?? taskIDFromSubject(subject)

        return MailroomEvoMapCommand(
            kind: kind,
            requestID: requestID,
            taskID: taskID,
            projectReference: fields["PROJECT"]?.nilIfBlank
                ?? fields["WORKSPACE"]?.nilIfBlank
                ?? "evomap-tasks",
            language: fields["LANGUAGE"]?.nilIfBlank,
            autoSubmitAllowed: boolField(fields["AUTO_SUBMIT_ALLOWED"]) ?? false,
            mode: fields["MODE"]?.nilIfBlank,
            rawBody: strippedBody
        )
    }

    static func normalizeSubject(_ rawSubject: String) -> String {
        var subject = rawSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        var didTrimPrefix = true
        while didTrimPrefix {
            didTrimPrefix = false
            let lowercased = subject.lowercased()
            if let prefix = replyPrefixes.first(where: { lowercased.hasPrefix($0) }) {
                subject = subject.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                didTrimPrefix = true
            }
        }

        if let regex = try? NSRegularExpression(pattern: tokenPattern, options: [.caseInsensitive]) {
            let range = NSRange(subject.startIndex..<subject.endIndex, in: subject)
            subject = regex.stringByReplacingMatches(in: subject, options: [], range: range, withTemplate: "")
        }

        var didTrimStatusPrefix = true
        while didTrimStatusPrefix {
            didTrimStatusPrefix = false
            if let regex = try? NSRegularExpression(pattern: statusPrefixPattern, options: [.caseInsensitive]) {
                let range = NSRange(subject.startIndex..<subject.endIndex, in: subject)
                let updated = regex.stringByReplacingMatches(in: subject, options: [], range: range, withTemplate: "")
                if updated != subject {
                    subject = updated.trimmingCharacters(in: .whitespacesAndNewlines)
                    didTrimStatusPrefix = true
                }
            }
        }

        return subject.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stripQuotedReplyChain(from rawBody: String) -> String {
        let lines = rawBody.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var kept: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = trimmed.lowercased()
            if trimmed.hasPrefix(">") {
                break
            }
            if lowercased.hasPrefix("on ") && lowercased.contains(" wrote:") {
                break
            }
            if lowercased == "-----original message-----" || lowercased == "---original message---" {
                break
            }
            if lowercased.hasPrefix("from:") && !kept.isEmpty {
                break
            }
            kept.append(line)
        }

        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseFields(
        from body: String
    ) -> (workspaceRoot: String?, capabilityRaw: String?, action: String?, projectReference: String?, body: String) {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var fields: [String: String] = [:]
        var contentLines: [String] = []
        var parsingHeader = true

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if parsingHeader && trimmed.isEmpty {
                if !fields.isEmpty {
                    parsingHeader = false
                    continue
                }
                contentLines.append(line)
                continue
            }

            if parsingHeader, let parsed = parseField(line) {
                fields[parsed.key] = parsed.value
                continue
            }

            if parsingHeader, isIgnorableHeaderField(line) {
                continue
            }

            parsingHeader = false
            contentLines.append(line)
        }

        return (
            workspaceRoot: fields["workspace"],
            capabilityRaw: fields["capability"],
            action: fields["action"],
            projectReference: fields["project"],
            body: contentLines.joined(separator: "\n")
        )
    }

    private static func parseAutomationFields(from body: String) -> [String: String] {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var fields: [String: String] = [:]
        var foundField = false

        for line in lines.prefix(80) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") {
                break
            }
            if trimmed.isEmpty {
                if foundField {
                    break
                }
                continue
            }
            guard let field = splitAutomationFieldLine(line) else {
                if foundField {
                    break
                }
                continue
            }
            foundField = true
            fields[normalizeAutomationKey(field.key)] = field.value
        }

        return fields
    }

    private static func splitAutomationFieldLine(_ line: String) -> (key: String, value: String)? {
        guard let separatorIndex = line.firstIndex(where: { fieldSeparators.contains($0) }) else {
            return nil
        }

        let key = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !value.isEmpty else {
            return nil
        }
        return (key, value)
    }

    private static func normalizeAutomationKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func subjectEvoMapCommand(from subject: String) -> String? {
        let uppercased = subject.uppercased()
        if uppercased.contains("[EVOMAP]") && uppercased.contains("[EXECUTE]") {
            return "EVOMAP_EXECUTE"
        }
        if uppercased.contains("[EVOMAP]") && uppercased.contains("[STATUS]") {
            return "EVOMAP_STATUS"
        }
        return nil
    }

    private static func taskIDFromRequestID(_ requestID: String?) -> String? {
        guard let value = requestID?.nilIfBlank else {
            return nil
        }
        if let separatorIndex = value.lastIndex(of: ":") {
            return String(value[value.index(after: separatorIndex)...]).nilIfBlank
        }
        return value.nilIfBlank
    }

    private static func taskIDFromSubject(_ subject: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\[EvoMap\]\[(?:EXECUTE|STATUS)\]\[([^\]]+)\]"#, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(subject.startIndex..<subject.endIndex, in: subject)
        guard let match = regex.firstMatch(in: subject, options: [], range: range),
              let taskRange = Range(match.range(at: 1), in: subject) else {
            return nil
        }
        return String(subject[taskRange]).nilIfBlank
    }

    private static func boolField(_ rawValue: String?) -> Bool? {
        guard let rawValue = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !rawValue.isEmpty else {
            return nil
        }

        switch rawValue {
        case "true", "yes", "y", "1", "允许", "是":
            return true
        case "false", "no", "n", "0", "不允许", "否":
            return false
        default:
            return nil
        }
    }

    private static func parseField(_ line: String) -> (key: String, value: String)? {
        guard let field = splitFieldLine(line) else {
            return nil
        }

        switch field.key {
        case "workspace", "path", "root", "工作区", "目录":
            return ("workspace", field.value)
        case "capability", "mode", "权限", "能力":
            return ("capability", field.value)
        case "project", "repo", "repository", "项目", "工程":
            return ("project", field.value)
        case "action", "task", "command", "任务", "动作", "命令":
            return ("action", field.value)
        default:
            return nil
        }
    }

    private static func isIgnorableHeaderField(_ line: String) -> Bool {
        guard let field = splitFieldLine(line) else {
            return false
        }
        return ignoredHeaderKeys.contains(field.key)
    }

    private static func splitFieldLine(_ line: String) -> (key: String, value: String)? {
        guard let separatorIndex = line.firstIndex(where: { fieldSeparators.contains($0) }) else {
            return nil
        }

        let key = normalizeFieldKey(line[..<separatorIndex])
        let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !value.isEmpty else {
            return nil
        }
        return (key, value)
    }

    private static func normalizeFieldKey(_ rawKey: Substring) -> String {
        rawKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).lowercased() }
            .joined(separator: " ")
    }

    private static func capability(from rawValue: String?) -> MailCapability? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !rawValue.isEmpty else {
            return nil
        }

        switch rawValue {
        case "readonly", "read-only", "read", "只读", "读取":
            return .readOnly
        case "write", "workspace-write", "writeworkspace", "写入", "修改":
            return .writeWorkspace
        case "shell", "exec", "execute", "executeshell", "命令", "执行":
            return .executeShell
        case "network", "networked", "联网", "网络":
            return .networkedAccess
        case "secret", "config", "secretandconfig", "配置", "密钥":
            return .secretAndConfig
        case "destructive", "destroy", "危险", "破坏性":
            return .destructiveChange
        default:
            return MailCapability(rawValue: rawValue)
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
