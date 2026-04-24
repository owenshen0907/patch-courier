import Darwin
import Foundation

enum MailroomDaemonLifecycleState: String, Equatable, Sendable {
    case discovering
    case ready
    case starting
    case running
    case stopping
    case failed
}

struct MailroomDaemonRuntimeStatus: Equatable, Sendable {
    var lifecycle: MailroomDaemonLifecycleState
    var controlFilePath: String
    var logFilePath: String
    var executablePath: String?
    var pid: Int32?
    var startedAt: Date?
    var isManagedByApp: Bool
    var detail: String?
    var lastExitStatus: Int32?
    var launchAgentLabel: String?
    var launchAgentPlistPath: String?
    var isLaunchAgentInstalled: Bool
    var isLaunchAgentLoaded: Bool

    static let placeholder = MailroomDaemonRuntimeStatus(
        lifecycle: .discovering,
        controlFilePath: "",
        logFilePath: "",
        executablePath: nil,
        pid: nil,
        startedAt: nil,
        isManagedByApp: false,
        detail: nil,
        lastExitStatus: nil,
        launchAgentLabel: nil,
        launchAgentPlistPath: nil,
        isLaunchAgentInstalled: false,
        isLaunchAgentLoaded: false
    )

    var isTransitioning: Bool {
        lifecycle == .starting || lifecycle == .stopping
    }
}

enum MailroomDaemonSupervisorError: LocalizedError {
    case executableNotFound([String])
    case logFileUnavailable(String)
    case launchFailed(String)
    case launchAgentWriteFailed(String)
    case launchctlFailed(String)
    case startupTimedOut(String)
    case stopFailed(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let candidates):
            let detail = candidates.joined(separator: "\n")
            return LT(
                "Could not find a runnable `mailroomd`. Checked:\n\(detail)",
                "找不到可执行的 `mailroomd`。已检查：\n\(detail)",
                "実行可能な `mailroomd` が見つからない。確認した場所:\n\(detail)"
            )
        case .logFileUnavailable(let detail):
            return LT(
                "Could not prepare the daemon log file: \(detail)",
                "无法准备 daemon 日志文件：\(detail)",
                "daemon ログファイルを準備できない: \(detail)"
            )
        case .launchFailed(let detail):
            return LT(
                "Failed to launch `mailroomd`: \(detail)",
                "启动 `mailroomd` 失败：\(detail)",
                "`mailroomd` の起動に失敗した: \(detail)"
            )
        case .launchAgentWriteFailed(let detail):
            return LT(
                "Failed to install the background daemon service: \(detail)",
                "安装后台 daemon 服务失败：\(detail)",
                "バックグラウンド daemon サービスの登録に失敗した: \(detail)"
            )
        case .launchctlFailed(let detail):
            return LT(
                "launchctl could not manage the background daemon: \(detail)",
                "launchctl 无法管理后台 daemon：\(detail)",
                "launchctl がバックグラウンド daemon を管理できなかった: \(detail)"
            )
        case .startupTimedOut(let detail):
            return LT(
                "Timed out while waiting for `mailroomd` to publish its control file. \(detail)",
                "等待 `mailroomd` 发布控制文件超时。\(detail)",
                "`mailroomd` が制御ファイルを公開するまで待機したがタイムアウトした。\(detail)"
            )
        case .stopFailed(let detail):
            return LT(
                "Failed to stop `mailroomd`: \(detail)",
                "停止 `mailroomd` 失败：\(detail)",
                "`mailroomd` の停止に失敗した: \(detail)"
            )
        }
    }
}

private struct LaunchAgentStatus {
    var isInstalled: Bool
    var isLoaded: Bool
}

@MainActor
final class MailroomDaemonSupervisor {
    private let fileManager = FileManager.default
    private let supportRootURL: URL
    private let controlFileURL: URL
    private let logFileURL: URL
    private let launchAgentLabel = "io.github.patchcourier.mailroomd"
    private let decoder: JSONDecoder
    private var managedProcess: Process?
    private var logFileHandle: FileHandle?
    private var cachedExecutableURL: URL?
    private var lifecycle: MailroomDaemonLifecycleState = .discovering
    private var lastLaunchError: String?
    private var lastExitStatus: Int32?
    private var lastStartAttemptAt: Date?
    private let autoStartCooldown: TimeInterval = 8

    init(supportRootURL: URL) {
        self.supportRootURL = supportRootURL
        self.controlFileURL = supportRootURL.appendingPathComponent("daemon-control.json")
        self.logFileURL = supportRootURL
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("mailroomd.log")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    private var launchAgentPlistURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(launchAgentLabel).plist")
    }

    private var launchAgentDomainTarget: String {
        "gui/\(getuid())"
    }

    private var launchAgentServiceTarget: String {
        "\(launchAgentDomainTarget)/\(launchAgentLabel)"
    }

    func currentRuntimeStatus(
        connectionState: MailroomDaemonConnectionState,
        controlFile: MailroomDaemonControlFile? = nil
    ) -> MailroomDaemonRuntimeStatus {
        let controlFile = controlFile ?? currentControlFile()
        let executableURL = try? resolveExecutableURL()
        let launchAgentStatus = currentLaunchAgentStatus()

        let effectiveLifecycle: MailroomDaemonLifecycleState
        let detail: String?

        if lifecycle == .stopping {
            effectiveLifecycle = .stopping
            detail = lastLaunchError
        } else {
            switch connectionState {
            case .connected:
                effectiveLifecycle = .running
                detail = nil
            case .unavailable(let message):
                switch lifecycle {
                case .starting:
                    effectiveLifecycle = .starting
                    detail = lastLaunchError ?? message
                case .failed:
                    if let controlFile, isProcessAlive(controlFile.pid) {
                        effectiveLifecycle = .running
                        detail = message
                    } else {
                        effectiveLifecycle = .failed
                        detail = lastLaunchError ?? message
                    }
                case .discovering, .ready, .running, .stopping:
                    if let controlFile, isProcessAlive(controlFile.pid) {
                        effectiveLifecycle = .running
                        detail = message
                    } else {
                        effectiveLifecycle = executableURL == nil ? .failed : .ready
                        detail = lastLaunchError ?? message
                    }
                }
            case .unknown:
                switch lifecycle {
                case .starting:
                    effectiveLifecycle = .starting
                    detail = lastLaunchError
                case .failed:
                    if let controlFile, isProcessAlive(controlFile.pid) {
                        effectiveLifecycle = .running
                        detail = nil
                    } else {
                        effectiveLifecycle = .failed
                        detail = lastLaunchError
                    }
                case .discovering, .ready, .running, .stopping:
                    if let controlFile, isProcessAlive(controlFile.pid) {
                        effectiveLifecycle = .running
                        detail = nil
                    } else {
                        effectiveLifecycle = executableURL == nil ? .failed : .ready
                        detail = lastLaunchError
                    }
                }
            }
        }

        return MailroomDaemonRuntimeStatus(
            lifecycle: effectiveLifecycle,
            controlFilePath: controlFileURL.path,
            logFilePath: logFileURL.path,
            executablePath: executableURL?.path,
            pid: controlFile?.pid,
            startedAt: controlFile?.startedAt,
            isManagedByApp: launchAgentStatus.isInstalled || launchAgentStatus.isLoaded || (controlFile.map(isManagedProcess(controlFile:)) ?? false),
            detail: detail,
            lastExitStatus: lastExitStatus,
            launchAgentLabel: launchAgentLabel,
            launchAgentPlistPath: launchAgentPlistURL.path,
            isLaunchAgentInstalled: launchAgentStatus.isInstalled,
            isLaunchAgentLoaded: launchAgentStatus.isLoaded
        )
    }

    func currentControlFile() -> MailroomDaemonControlFile? {
        guard fileManager.fileExists(atPath: controlFileURL.path),
              let data = try? Data(contentsOf: controlFileURL) else {
            return nil
        }
        return try? decoder.decode(MailroomDaemonControlFile.self, from: data)
    }

    func autoStartIfNeeded() async throws -> Bool {
        if lifecycle == .starting || lifecycle == .stopping {
            return false
        }

        if let controlFile = currentControlFile() {
            if isProcessAlive(controlFile.pid) {
                lifecycle = .running
                return false
            }
            removeControlFileIfOwned(by: controlFile.pid)
        }

        if let lastStartAttemptAt,
           Date().timeIntervalSince(lastStartAttemptAt) < autoStartCooldown {
            return false
        }

        _ = try await startDaemon()
        return true
    }

    func startDaemon() async throws -> MailroomDaemonControlFile {
        if let controlFile = currentControlFile(),
           isProcessAlive(controlFile.pid) {
            lifecycle = .running
            return controlFile
        }

        let executableURL = try resolveExecutableURL()
        lastStartAttemptAt = Date()
        lifecycle = .starting
        lastLaunchError = nil
        try removeStaleControlFile()
        do {
            let controlFile = try await startDaemonViaLaunchAgent(executableURL: executableURL)
            lifecycle = .running
            return controlFile
        } catch {
            lifecycle = .failed
            lastLaunchError = error.localizedDescription
            throw error
        }
    }

    func stopDaemon(using controlFile: MailroomDaemonControlFile? = nil) async throws {
        lifecycle = .stopping
        defer {
            if lifecycle == .stopping {
                lifecycle = .ready
            }
        }

        let launchAgentStatus = currentLaunchAgentStatus()
        if launchAgentStatus.isInstalled || launchAgentStatus.isLoaded {
            let targetPID = controlFile?.pid ?? currentControlFile()?.pid

            do {
                try bootoutLaunchAgent()
            } catch {
                if launchAgentStatus.isLoaded {
                    lifecycle = .failed
                    lastLaunchError = error.localizedDescription
                    throw error
                }
            }

            if let targetPID {
                try await waitForProcessExit(pid: targetPID, timeout: 4)
                removeControlFileIfOwned(by: targetPID)
            } else {
                try? removeStaleControlFile()
            }

            managedProcess = nil
            try? logFileHandle?.close()
            logFileHandle = nil
            lifecycle = .ready
            lastLaunchError = nil
            return
        }

        let targetPID = controlFile?.pid ?? currentControlFile()?.pid ?? managedProcess?.processIdentifier
        guard let targetPID else {
            try removeStaleControlFile()
            managedProcess = nil
            try? logFileHandle?.close()
            logFileHandle = nil
            return
        }

        if isManagedProcess(pid: targetPID), let managedProcess, managedProcess.isRunning {
            managedProcess.terminate()
        } else if isProcessAlive(targetPID) {
            guard kill(targetPID, SIGTERM) == 0 else {
                lifecycle = .failed
                lastLaunchError = String(cString: strerror(errno))
                throw MailroomDaemonSupervisorError.stopFailed(lastLaunchError ?? "SIGTERM failed")
            }
        }

        try await waitForProcessExit(pid: targetPID, timeout: 4)
        removeControlFileIfOwned(by: targetPID)
        managedProcess = nil
        try? logFileHandle?.close()
        logFileHandle = nil
        lifecycle = .ready
    }

    func restartDaemon(using controlFile: MailroomDaemonControlFile? = nil) async throws -> MailroomDaemonControlFile {
        try await stopDaemon(using: controlFile)
        return try await startDaemon()
    }

    func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else {
            return false
        }
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private func startDaemonViaLaunchAgent(executableURL: URL) async throws -> MailroomDaemonControlFile {
        try installLaunchAgent(executableURL: executableURL)

        let launchAgentStatus = currentLaunchAgentStatus()
        if launchAgentStatus.isLoaded {
            try kickstartLaunchAgent()
        } else {
            try bootstrapLaunchAgent()
        }

        return try await waitForControlFile(expectedPID: nil)
    }

    private func waitForControlFile(expectedPID: Int32?) async throws -> MailroomDaemonControlFile {
        let deadline = Date().addingTimeInterval(8)

        while Date() < deadline {
            if let controlFile = currentControlFile(),
               (expectedPID == nil || controlFile.pid == expectedPID),
               isProcessAlive(controlFile.pid) {
                return controlFile
            }

            if let managedProcess, !managedProcess.isRunning {
                let tail = readLogTail()
                let suffix = tail == nil ? "" : LT("Last log:\n\(tail!)", "最后日志：\n\(tail!)", "直近ログ:\n\(tail!)")
                throw MailroomDaemonSupervisorError.startupTimedOut(suffix)
            }

            try? await Task.sleep(for: .milliseconds(150))
        }

        let launchAgentDetail = readLaunchAgentSummary()
        throw MailroomDaemonSupervisorError.startupTimedOut(
            LT(
                "Check \(logFileURL.path) for startup output.\(launchAgentDetail.map { "\n\($0)" } ?? "")",
                "请查看 \(logFileURL.path) 里的启动日志。\(launchAgentDetail.map { "\n\($0)" } ?? "")",
                "起動ログは \(logFileURL.path) を確認してください。\(launchAgentDetail.map { "\n\($0)" } ?? "")"
            )
        )
    }

    private func waitForProcessExit(pid: Int32, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isProcessAlive(pid) {
                return
            }
            try? await Task.sleep(for: .milliseconds(120))
        }

        if kill(pid, SIGKILL) == 0 {
            let killDeadline = Date().addingTimeInterval(2)
            while Date() < killDeadline {
                if !isProcessAlive(pid) {
                    return
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }

        lifecycle = .failed
        lastLaunchError = LT(
            "The daemon process did not exit in time.",
            "daemon 进程没有按时退出。",
            "daemon プロセスが時間内に終了しなかった。"
        )
        throw MailroomDaemonSupervisorError.stopFailed(lastLaunchError ?? "Timed out")
    }

    private func currentLaunchAgentStatus() -> LaunchAgentStatus {
        let isInstalled = fileManager.fileExists(atPath: launchAgentPlistURL.path)
        guard isInstalled else {
            return LaunchAgentStatus(isInstalled: false, isLoaded: false)
        }

        let isLoaded: Bool
        do {
            _ = try runLaunchctl(["print", launchAgentServiceTarget])
            isLoaded = true
        } catch {
            isLoaded = false
        }

        return LaunchAgentStatus(isInstalled: true, isLoaded: isLoaded)
    }

    private func installLaunchAgent(executableURL: URL) throws {
        do {
            try fileManager.createDirectory(
                at: launchAgentPlistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try fileManager.createDirectory(
                at: logFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            if !fileManager.fileExists(atPath: logFileURL.path) {
                fileManager.createFile(atPath: logFileURL.path, contents: nil)
            }

            let propertyList: [String: Any] = [
                "Label": launchAgentLabel,
                "ProgramArguments": [executableURL.path, "--run-mail-loop"],
                "RunAtLoad": true,
                "KeepAlive": true,
                "ProcessType": "Background",
                "WorkingDirectory": defaultWorkingDirectoryURL().path,
                "StandardOutPath": logFileURL.path,
                "StandardErrorPath": logFileURL.path,
                "EnvironmentVariables": launchAgentEnvironment(executableURL: executableURL)
            ]

            let data = try PropertyListSerialization.data(
                fromPropertyList: propertyList,
                format: .xml,
                options: 0
            )
            try data.write(to: launchAgentPlistURL, options: .atomic)
        } catch {
            throw MailroomDaemonSupervisorError.launchAgentWriteFailed(error.localizedDescription)
        }
    }

    private func launchAgentEnvironment(executableURL: URL) -> [String: String] {
        let processEnvironment = ProcessInfo.processInfo.environment
        var environment: [String: String] = [
            "MAILROOM_SUPPORT_ROOT": supportRootURL.path,
            "MAILROOM_WORKDIR": defaultWorkingDirectoryURL().path,
            "MAILROOM_WORKSPACE_ROOT": defaultWorkspaceRootURL().path,
            "MAILROOM_DAEMON_EXECUTABLE_PATH": executableURL.path,
            "PATH": processEnvironment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        ]

        for key in ["HOME", "USER", "LOGNAME", "LANG", "SHELL", "CODEX_CLI_PATH", "CODEX_HOME", "MAILROOM_CODEX_PROFILE_HOME"] {
            if let value = processEnvironment[key],
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                environment[key] = value
            }
        }

        return environment
    }

    private func bootstrapLaunchAgent() throws {
        do {
            _ = try runLaunchctl(["bootstrap", launchAgentDomainTarget, launchAgentPlistURL.path])
        } catch {
            _ = try? runLaunchctl(["bootout", launchAgentServiceTarget])
            do {
                _ = try runLaunchctl(["bootstrap", launchAgentDomainTarget, launchAgentPlistURL.path])
            } catch {
                throw error
            }
        }
        try kickstartLaunchAgent()
    }

    private func kickstartLaunchAgent() throws {
        _ = try runLaunchctl(["kickstart", "-k", launchAgentServiceTarget])
    }

    private func bootoutLaunchAgent() throws {
        _ = try runLaunchctl(["bootout", launchAgentServiceTarget])
    }

    private func readLaunchAgentSummary() -> String? {
        guard currentLaunchAgentStatus().isInstalled else {
            return nil
        }

        if let output = try? runLaunchctl(["print", launchAgentServiceTarget]) {
            let lines = output
                .split(separator: "\n", omittingEmptySubsequences: false)
                .prefix(10)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lines.isEmpty else {
                return nil
            }
            return LT(
                "launchd service:\n\(lines)",
                "launchd 服务：\n\(lines)",
                "launchd サービス:\n\(lines)"
            )
        }

        return LT(
            "Launch agent plist: \(launchAgentPlistURL.path)",
            "LaunchAgent plist：\(launchAgentPlistURL.path)",
            "LaunchAgent plist: \(launchAgentPlistURL.path)"
        )
    }

    private func runLaunchctl(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = try resolveLaunchctlURL()
        process.arguments = arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            throw MailroomDaemonSupervisorError.launchctlFailed(error.localizedDescription)
        }

        process.waitUntilExit()
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            let detail = output.isEmpty
                ? LT("exit status \(process.terminationStatus)", "退出状态 \(process.terminationStatus)", "終了コード \(process.terminationStatus)")
                : output
            throw MailroomDaemonSupervisorError.launchctlFailed(detail)
        }

        return output
    }

    private func resolveLaunchctlURL() throws -> URL {
        let candidates = ["/bin/launchctl", "/usr/bin/launchctl"]
        if let resolved = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: resolved)
        }
        throw MailroomDaemonSupervisorError.launchctlFailed(
            LT(
                "No launchctl executable was found.",
                "没有找到 launchctl 可执行文件。",
                "launchctl 実行ファイルが見つからない。"
            )
        )
    }

    private func resolveExecutableURL() throws -> URL {
        if let cachedExecutableURL,
           fileManager.isExecutableFile(atPath: cachedExecutableURL.path) {
            return cachedExecutableURL
        }

        let bundle = Bundle.main
        let currentDirectory = fileManager.currentDirectoryPath
        let candidates = [
            ProcessInfo.processInfo.environment["MAILROOM_DAEMON_EXECUTABLE_PATH"],
            bundle.bundleURL.appendingPathComponent("Contents/Helpers/mailroomd").path(),
            bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("mailroomd").path(),
            URL(fileURLWithPath: currentDirectory, isDirectory: true).appendingPathComponent("mailroomd").path()
        ].compactMap { $0 }

        if let resolved = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            let url = URL(fileURLWithPath: resolved)
            cachedExecutableURL = url
            if lifecycle == .discovering {
                lifecycle = .ready
            }
            return url
        }

        lifecycle = .failed
        throw MailroomDaemonSupervisorError.executableNotFound(candidates)
    }

    private func prepareLogFileHandle() throws -> FileHandle {
        do {
            try fileManager.createDirectory(
                at: logFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            if !fileManager.fileExists(atPath: logFileURL.path) {
                fileManager.createFile(atPath: logFileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logFileURL)
            try handle.seekToEnd()
            return handle
        } catch {
            throw MailroomDaemonSupervisorError.logFileUnavailable(error.localizedDescription)
        }
    }

    private func launchEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["MAILROOM_SUPPORT_ROOT"] = supportRootURL.path
        environment["MAILROOM_WORKDIR"] = defaultWorkingDirectoryURL().path
        environment["MAILROOM_WORKSPACE_ROOT"] = defaultWorkspaceRootURL().path
        return environment
    }

    private func defaultWorkingDirectoryURL() -> URL {
        defaultWorkspaceRootURL()
    }

    private func defaultWorkspaceRootURL() -> URL {
        let homeURL = fileManager.homeDirectoryForCurrentUser
        let workspaceURL = homeURL.appendingPathComponent("Workspace", isDirectory: true)
        if fileManager.fileExists(atPath: workspaceURL.path) {
            return workspaceURL
        }
        return homeURL
    }

    private func handleTermination(of process: Process) {
        guard let managedProcess,
              managedProcess.processIdentifier == process.processIdentifier else {
            return
        }

        lastExitStatus = process.terminationStatus
        if process.terminationReason == .uncaughtSignal {
            lastLaunchError = LT(
                "The daemon stopped after receiving a signal.",
                "daemon 收到信号后停止了。",
                "daemon はシグナル受信後に停止した。"
            )
        } else if process.terminationStatus != 0 {
            lastLaunchError = LT(
                "The daemon exited with status \(process.terminationStatus).",
                "daemon 以状态码 \(process.terminationStatus) 退出了。",
                "daemon は終了コード \(process.terminationStatus) で停止した。"
            )
        }

        removeControlFileIfOwned(by: process.processIdentifier)
        self.managedProcess = nil
        try? logFileHandle?.close()
        logFileHandle = nil
        if lifecycle != .failed {
            lifecycle = .ready
        }
    }

    private func readLogTail() -> String? {
        guard let content = try? String(contentsOf: logFileURL, encoding: .utf8) else {
            return nil
        }
        let lines = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(12)
        let result = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private func isManagedProcess(controlFile: MailroomDaemonControlFile) -> Bool {
        isManagedProcess(pid: controlFile.pid)
    }

    private func isManagedProcess(pid: Int32) -> Bool {
        managedProcess?.processIdentifier == pid
    }

    private func removeControlFileIfOwned(by pid: Int32) {
        guard let controlFile = currentControlFile(),
              controlFile.pid == pid else {
            return
        }
        try? fileManager.removeItem(at: controlFileURL)
    }

    private func removeStaleControlFile() throws {
        guard let controlFile = currentControlFile() else {
            return
        }
        if !isProcessAlive(controlFile.pid) {
            try? fileManager.removeItem(at: controlFileURL)
        }
    }
}
