import Dispatch
import Foundation

enum MailroomCLIError: LocalizedError {
    case missingValue(String)
    case invalidCapability(String)
    case missingPrompt

    var errorDescription: String? {
        switch self {
        case .missingValue(let flag):
            return "Missing value for \(flag)."
        case .invalidCapability(let rawValue):
            return "Unsupported capability '\(rawValue)'. Use readOnly, writeWorkspace, executeShell, or networkedAccess."
        case .missingPrompt:
            return "Provide --prompt or --prompt-file."
        }
    }
}

struct MailroomCLI {
    let arguments: [String]

    func has(_ flag: String) -> Bool {
        arguments.contains(flag)
    }

    func value(for flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    func requiredValue(for flag: String) throws -> String {
        guard let value = value(for: flag), !value.isEmpty else {
            throw MailroomCLIError.missingValue(flag)
        }
        return value
    }

    func promptText() throws -> String? {
        if let prompt = value(for: "--prompt") {
            return prompt
        }
        if let path = value(for: "--prompt-file") {
            return try String(contentsOfFile: path, encoding: .utf8)
        }
        return nil
    }

    func requiredPromptText() throws -> String {
        guard let prompt = try promptText(), !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MailroomCLIError.missingPrompt
        }
        return prompt
    }

    func capability(default fallback: MailroomCapability = .writeWorkspace) throws -> MailroomCapability {
        guard let rawValue = value(for: "--capability") else {
            return fallback
        }
        switch rawValue.lowercased() {
        case "readonly", "read-only":
            return .readOnly
        case "writeworkspace", "write-workspace":
            return .writeWorkspace
        case "executeshell", "execute-shell":
            return .executeShell
        case "networkedaccess", "networked-access":
            return .networkedAccess
        default:
            throw MailroomCLIError.invalidCapability(rawValue)
        }
    }

    func accountIDs() -> [String]? {
        guard let rawValue = value(for: "--account")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }

        let values = rawValue
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? nil : values
    }
}

private func makeJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let data = try makeJSONEncoder().encode(value)
    if let string = String(data: data, encoding: .utf8) {
        print(string)
    }
}

private func usage() -> String {
    """
    Usage:
      mailroomd --probe-codex
      mailroomd --probe-turn [--prompt "..."]
      mailroomd --once
      mailroomd --list-threads
      mailroomd --list-turns
      mailroomd --list-approvals
      mailroomd --list-events
      mailroomd --render-mail-fixtures [--output-dir .preview/mailroom-emails]
      mailroomd --sync-mailboxes [--account default]
      mailroomd --run-mail-loop [--account default]
      mailroomd --start-thread --sender you@example.com [--mailbox default] [--subject "Mailroom request"] [--workspace /path] [--capability writeWorkspace] [--prompt "..."] [--wait]
      mailroomd --continue-thread --token MRM-1234ABCD --prompt "..." [--wait]
      mailroomd --parse-approval-file /path/to/reply.txt

    Environment:
      CODEX_CLI_PATH
      MAILROOM_SUPPORT_ROOT
      MAILROOM_DATABASE_PATH
      MAILROOM_CODEX_HOME
      MAILROOM_CODEX_PROFILE_HOME
      MAILROOM_ACCOUNTS_PATH
      MAILROOM_POLICIES_PATH
      MAILROOM_TRANSPORT_SCRIPT_PATH
      MAILROOM_WORKDIR
      MAILROOM_WORKSPACE_ROOT
    """
}

let configuration = MailroomDaemonConfiguration.default()
let cli = MailroomCLI(arguments: Array(CommandLine.arguments.dropFirst()))

Task {
    var daemon: MailroomDaemon?
    do {
        if cli.has("--help") {
            print(usage())
            exit(0)
        }

        if let approvalPath = cli.value(for: "--parse-approval-file") {
            let body = try String(contentsOfFile: approvalPath, encoding: .utf8)
            guard let parsed = ApprovalReplyParser.parse(body) else {
                throw MailroomDaemonError.approvalReplyParseFailed
            }
            try printJSON(parsed)
            exit(0)
        }

        let store = try SQLiteMailroomStore(databasePath: configuration.databasePath)
        let instance = MailroomDaemon(
            configuration: configuration,
            threadStore: store,
            turnStore: store,
            approvalStore: store,
            eventStore: store,
            syncStore: store,
            mailboxMessageStore: store,
            pollIncidentStore: store,
            accountStore: store,
            senderPolicyStore: store,
            managedProjectStore: store
        )
        daemon = instance

        if cli.has("--probe-codex") {
            try printJSON(try await instance.probeCodex())
            await instance.shutdown()
            exit(0)
        }

        if cli.has("--probe-turn") {
            let prompt = try cli.promptText() ?? "Reply with exactly hello and nothing else."
            try printJSON(try await instance.probeTurn(prompt: prompt))
            await instance.shutdown()
            exit(0)
        }

        if cli.has("--once") {
            try printJSON(try await instance.boot())
            await instance.shutdown()
            exit(0)
        }

        if cli.has("--list-threads") {
            try printJSON(try await instance.listThreads())
            await instance.shutdown()
            exit(0)
        }

        if cli.has("--list-turns") {
            try printJSON(try await instance.listTurns())
            await instance.shutdown()
            exit(0)
        }

        if cli.has("--list-approvals") {
            try printJSON(try await instance.listApprovals())
            await instance.shutdown()
            exit(0)
        }

        if cli.has("--list-events") {
            try printJSON(try await instance.listEvents())
            await instance.shutdown()
            exit(0)
        }

        if cli.has("--render-mail-fixtures") {
            let outputDirectory = cli.value(for: "--output-dir") ?? ".preview/mailroom-emails"
            let outputURL: URL
            if outputDirectory.hasPrefix("/") {
                outputURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
            } else {
                outputURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                    .appendingPathComponent(outputDirectory, isDirectory: true)
            }
            try printJSON(try await instance.renderMailPreviewFixtures(outputDirectory: outputURL.standardizedFileURL))
            await instance.shutdown()
            exit(0)
        }

        if cli.has("--sync-mailboxes") {
            try printJSON(try await instance.syncMailboxes(accountIDs: cli.accountIDs()))
            await instance.shutdown()
            exit(0)
        }

        if cli.has("--run-mail-loop") {
            try await instance.runMailLoop(accountIDs: cli.accountIDs())
            await instance.shutdown()
            exit(0)
        }

        if cli.has("--start-thread") {
            let seed = MailroomThreadSeed(
                mailboxID: cli.value(for: "--mailbox") ?? "default",
                normalizedSender: try cli.requiredValue(for: "--sender"),
                subject: cli.value(for: "--subject") ?? "Mailroom request",
                workspaceRoot: cli.value(for: "--workspace") ?? configuration.defaultWorkspaceRoot,
                capability: try cli.capability()
            )
            let prompt = try cli.promptText()
            let started = try await instance.startMailWorkflow(seed: seed, prompt: prompt)
            if cli.has("--wait"), let turn = started.turn {
                try printJSON(try await instance.waitForTurnOutcome(token: started.thread.id, turnID: turn.id))
            } else {
                try printJSON(started)
            }
            await instance.shutdown()
            exit(0)
        }

        if cli.has("--continue-thread") {
            let token = try cli.requiredValue(for: "--token")
            let prompt = try cli.requiredPromptText()
            if cli.has("--wait") {
                try printJSON(try await instance.continueMailThreadAndWait(token: token, prompt: prompt))
            } else {
                try printJSON(try await instance.continueMailThread(token: token, prompt: prompt))
            }
            await instance.shutdown()
            exit(0)
        }

        try await instance.runSkeleton()
    } catch {
        fputs("mailroomd failed: \(error.localizedDescription)\n", stderr)
        if let daemon {
            await daemon.shutdown()
        }
        exit(1)
    }
}

dispatchMain()
