import Foundation

struct CodexProfileBootstrapResult: Hashable, Sendable {
    var sourceHome: String?
    var mirroredFiles: [String]
    var loadedEnvironment: [String: String]
}

struct CodexProfileBootstrapConfiguration: Sendable {
    static let defaultMirroredFiles = [
        "config.toml",
        ".env",
        "auth.json",
        "installation_id",
        ".codex-global-state.json"
    ]

    var sourceHome: String?
    var destinationHome: String
    var mirroredFiles: [String]

    init(sourceHome: String?, destinationHome: String, mirroredFiles: [String] = Self.defaultMirroredFiles) {
        self.sourceHome = sourceHome
        self.destinationHome = destinationHome
        self.mirroredFiles = mirroredFiles
    }
}

enum CodexProfileBootstrapper {
    static func prepare(configuration: CodexProfileBootstrapConfiguration) throws -> CodexProfileBootstrapResult {
        let fileManager = FileManager.default
        let destinationHome = normalizedPath(configuration.destinationHome)
        try fileManager.createDirectory(atPath: destinationHome, withIntermediateDirectories: true, attributes: nil)

        guard let sourceHome = resolveSourceHome(explicitSourceHome: configuration.sourceHome, excluding: destinationHome) else {
            return CodexProfileBootstrapResult(sourceHome: nil, mirroredFiles: [], loadedEnvironment: [:])
        }

        let sourceURL = URL(fileURLWithPath: sourceHome, isDirectory: true)
        let destinationURL = URL(fileURLWithPath: destinationHome, isDirectory: true)

        var mirroredFiles: [String] = []
        var loadedEnvironment: [String: String] = [:]

        for fileName in configuration.mirroredFiles {
            let sourceFileURL = sourceURL.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: sourceFileURL.path) else { continue }

            let destinationFileURL = destinationURL.appendingPathComponent(fileName)
            try syncFile(from: sourceFileURL, to: destinationFileURL)
            mirroredFiles.append(fileName)

            if fileName == ".env" {
                loadedEnvironment.merge(try parseDotEnv(at: sourceFileURL), uniquingKeysWith: { _, new in new })
            }
        }

        return CodexProfileBootstrapResult(
            sourceHome: sourceHome,
            mirroredFiles: mirroredFiles,
            loadedEnvironment: loadedEnvironment
        )
    }

    private static func resolveSourceHome(explicitSourceHome: String?, excluding destinationHome: String) -> String? {
        let candidates: [String?] = [
            explicitSourceHome,
            ProcessInfo.processInfo.environment["CODEX_HOME"],
            URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(".codex", isDirectory: true)
                .path
        ]

        let fileManager = FileManager.default
        for candidate in candidates {
            guard let candidate else { continue }
            let normalizedCandidate = normalizedPath(candidate)
            guard normalizedCandidate != destinationHome else { continue }
            guard fileManager.fileExists(atPath: normalizedCandidate) else { continue }
            return normalizedCandidate
        }
        return nil
    }

    private static func syncFile(from sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        let parentDirectory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true, attributes: nil)

        if fileManager.fileExists(atPath: destinationURL.path) {
            if fileManager.contentsEqual(atPath: sourceURL.path, andPath: destinationURL.path) {
                return
            }
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private static func parseDotEnv(at fileURL: URL) throws -> [String: String] {
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        var environment: [String: String] = [:]

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            let assignment = line.hasPrefix("export ") ? String(line.dropFirst("export ".count)) : line
            guard let separatorIndex = assignment.firstIndex(of: "=") else { continue }

            let key = assignment[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }

            let rawValue = assignment[assignment.index(after: separatorIndex)...]
            environment[key] = unquote(String(rawValue).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return environment
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }
}
