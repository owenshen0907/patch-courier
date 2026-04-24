import Foundation
import SQLite3

struct SQLiteJobStore: Sendable {
    let databaseURL: URL

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func makeDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try migrateIfNeeded()
    }

    func loadRecentJobs(limit: Int = 20) throws -> [ExecutionJobRecord] {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        let sql = """
        SELECT
            id,
            account_id,
            sender_address,
            requested_role,
            capability,
            approval_requirement,
            action,
            subject,
            status,
            workspace_root,
            summary,
            prompt_body,
            reply_body,
            error_details,
            codex_command,
            exit_code,
            received_at,
            started_at,
            completed_at,
            updated_at
        FROM jobs
        ORDER BY updated_at DESC
        LIMIT ?;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteJobStoreError.statementFailed(message(from: database))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, Int64(limit))

        var rows: [ExecutionJobRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let role = MailboxRole(rawValue: string(at: 3, from: statement) ?? "") ?? .operator
            let capability = MailCapability(rawValue: string(at: 4, from: statement) ?? "") ?? .readOnly
            let requirement = ApprovalRequirement(rawValue: string(at: 5, from: statement) ?? "") ?? .automatic
            let status = MailJobStatus(rawValue: string(at: 8, from: statement) ?? "") ?? .received
            rows.append(
                ExecutionJobRecord(
                    id: string(at: 0, from: statement) ?? UUID().uuidString,
                    accountID: string(at: 1, from: statement),
                    senderAddress: string(at: 2, from: statement) ?? "unknown@example.com",
                    requestedRole: role,
                    capability: capability,
                    approvalRequirement: requirement,
                    action: string(at: 6, from: statement) ?? "unknown-action",
                    subject: string(at: 7, from: statement) ?? "",
                    status: status,
                    workspaceRoot: string(at: 9, from: statement) ?? "",
                    summary: string(at: 10, from: statement) ?? "",
                    promptBody: string(at: 11, from: statement) ?? "",
                    replyBody: string(at: 12, from: statement),
                    errorDetails: string(at: 13, from: statement),
                    codexCommand: string(at: 14, from: statement),
                    exitCode: int(at: 15, from: statement),
                    receivedAt: parsedDate(from: string(at: 16, from: statement)),
                    startedAt: optionalParsedDate(from: string(at: 17, from: statement)),
                    completedAt: optionalParsedDate(from: string(at: 18, from: statement)),
                    updatedAt: parsedDate(from: string(at: 19, from: statement))
                )
            )
        }

        return rows
    }

    func insert(_ job: ExecutionJobRecord) throws {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        let sql = """
        INSERT OR REPLACE INTO jobs (
            id,
            account_id,
            sender_address,
            requested_role,
            capability,
            approval_requirement,
            action,
            subject,
            status,
            workspace_root,
            summary,
            prompt_body,
            reply_body,
            error_details,
            codex_command,
            exit_code,
            received_at,
            started_at,
            completed_at,
            updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteJobStoreError.statementFailed(message(from: database))
        }
        defer { sqlite3_finalize(statement) }

        bind(job.id, at: 1, in: statement)
        bind(job.accountID, at: 2, in: statement)
        bind(job.senderAddress, at: 3, in: statement)
        bind(job.requestedRole.rawValue, at: 4, in: statement)
        bind(job.capability.rawValue, at: 5, in: statement)
        bind(job.approvalRequirement.rawValue, at: 6, in: statement)
        bind(job.action, at: 7, in: statement)
        bind(job.subject, at: 8, in: statement)
        bind(job.status.rawValue, at: 9, in: statement)
        bind(job.workspaceRoot, at: 10, in: statement)
        bind(job.summary, at: 11, in: statement)
        bind(job.promptBody, at: 12, in: statement)
        bind(job.replyBody, at: 13, in: statement)
        bind(job.errorDetails, at: 14, in: statement)
        bind(job.codexCommand, at: 15, in: statement)
        bind(job.exitCode, at: 16, in: statement)
        bind(Self.makeDateFormatter().string(from: job.receivedAt), at: 17, in: statement)
        bind(job.startedAt.map { Self.makeDateFormatter().string(from: $0) }, at: 18, in: statement)
        bind(job.completedAt.map { Self.makeDateFormatter().string(from: $0) }, at: 19, in: statement)
        bind(Self.makeDateFormatter().string(from: job.updatedAt), at: 20, in: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteJobStoreError.statementFailed(message(from: database))
        }
    }

    func count() throws -> Int {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        let sql = "SELECT COUNT(*) FROM jobs;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteJobStoreError.statementFailed(message(from: database))
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }

        return Int(sqlite3_column_int64(statement, 0))
    }

    private func migrateIfNeeded() throws {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try execute(
            """
            CREATE TABLE IF NOT EXISTS jobs (
                id TEXT PRIMARY KEY,
                account_id TEXT,
                sender_address TEXT NOT NULL,
                requested_role TEXT NOT NULL,
                capability TEXT NOT NULL DEFAULT 'readOnly',
                approval_requirement TEXT NOT NULL DEFAULT 'automatic',
                action TEXT NOT NULL,
                subject TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL,
                workspace_root TEXT NOT NULL,
                summary TEXT NOT NULL,
                prompt_body TEXT NOT NULL DEFAULT '',
                reply_body TEXT,
                error_details TEXT,
                codex_command TEXT,
                exit_code INTEGER,
                received_at TEXT NOT NULL,
                started_at TEXT,
                completed_at TEXT,
                updated_at TEXT NOT NULL
            );
            """,
            in: database
        )

        try ensureColumn(named: "capability", definition: "TEXT NOT NULL DEFAULT 'readOnly'", in: database)
        try ensureColumn(named: "approval_requirement", definition: "TEXT NOT NULL DEFAULT 'automatic'", in: database)
        try ensureColumn(named: "subject", definition: "TEXT NOT NULL DEFAULT ''", in: database)
        try ensureColumn(named: "prompt_body", definition: "TEXT NOT NULL DEFAULT ''", in: database)
        try ensureColumn(named: "reply_body", definition: "TEXT", in: database)
        try ensureColumn(named: "error_details", definition: "TEXT", in: database)
        try ensureColumn(named: "codex_command", definition: "TEXT", in: database)
        try ensureColumn(named: "exit_code", definition: "INTEGER", in: database)
        try ensureColumn(named: "started_at", definition: "TEXT", in: database)
        try ensureColumn(named: "completed_at", definition: "TEXT", in: database)

        try execute(
            "CREATE INDEX IF NOT EXISTS idx_jobs_updated_at ON jobs(updated_at DESC);",
            in: database
        )
    }

    private func ensureColumn(named name: String, definition: String, in database: OpaquePointer?) throws {
        guard !existingColumns(in: database).contains(name) else {
            return
        }
        try execute("ALTER TABLE jobs ADD COLUMN \(name) \(definition);", in: database)
    }

    private func existingColumns(in database: OpaquePointer?) -> Set<String> {
        var columns: Set<String> = []
        let sql = "PRAGMA table_info(jobs);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return columns
        }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = string(at: 1, from: statement) {
                columns.insert(name)
            }
        }
        return columns
    }

    private func openDatabase() throws -> OpaquePointer? {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK else {
            let failureMessage = message(from: database)
            sqlite3_close(database)
            throw SQLiteJobStoreError.openFailed(failureMessage)
        }
        return database
    }

    private func execute(_ sql: String, in database: OpaquePointer?) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? self.message(from: database)
            sqlite3_free(errorMessage)
            throw SQLiteJobStoreError.statementFailed(message)
        }
    }

    private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, Self.sqliteTransient)
    }

    private func bind(_ value: Int?, at index: Int32, in statement: OpaquePointer?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, Int64(value))
    }

    private func string(at index: Int32, from statement: OpaquePointer?) -> String? {
        guard let rawText = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: rawText)
    }

    private func int(at index: Int32, from statement: OpaquePointer?) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return Int(sqlite3_column_int64(statement, index))
    }

    private func parsedDate(from rawValue: String?) -> Date {
        guard let rawValue else {
            return Date()
        }
        return Self.makeDateFormatter().date(from: rawValue) ?? Date()
    }

    private func optionalParsedDate(from rawValue: String?) -> Date? {
        guard let rawValue else {
            return nil
        }
        return Self.makeDateFormatter().date(from: rawValue)
    }

    private func message(from database: OpaquePointer?) -> String {
        guard let database else {
            return "Unknown SQLite error."
        }
        return String(cString: sqlite3_errmsg(database))
    }
}

enum SQLiteJobStoreError: LocalizedError, Sendable {
    case openFailed(String)
    case statementFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            return LT("Unable to open the SQLite job store: \(message)", "无法打开 SQLite job 存储：\(message)", "SQLite ジョブストアを開けない: \(message)")
        case .statementFailed(let message):
            return LT("SQLite could not complete the requested operation: \(message)", "SQLite 无法完成请求的操作：\(message)", "SQLite が要求された処理を完了できない: \(message)")
        }
    }
}
