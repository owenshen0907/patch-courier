import Foundation
import SQLite3

struct SQLiteMailroomLocalStore: Sendable {
    let databaseURL: URL

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    func loadMailboxAccounts(secretStore: KeychainSecretStore) throws -> [ConfiguredMailboxAccount] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return []
        }

        let database = try openDatabase()
        defer { sqlite3_close(database) }

        let sql = """
        SELECT
            id,
            label,
            email_address,
            role,
            workspace_root,
            imap_host,
            imap_port,
            imap_security,
            smtp_host,
            smtp_port,
            smtp_security,
            polling_interval_seconds,
            created_at,
            updated_at
        FROM mailbox_accounts
        ORDER BY updated_at DESC;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            let details = message(from: database!)
            if details.localizedCaseInsensitiveContains("no such table: mail_messages") {
                return []
            }
            throw SQLiteMailroomLocalStoreError.statementFailed(details)
        }
        defer { sqlite3_finalize(statement) }

        var rows: [ConfiguredMailboxAccount] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let role = MailboxRole(rawValue: string(at: 3, from: statement) ?? "") ?? .operator
            let imapSecurity = MailTransportSecurity(rawValue: string(at: 7, from: statement) ?? "") ?? .sslTLS
            let smtpSecurity = MailTransportSecurity(rawValue: string(at: 10, from: statement) ?? "") ?? .sslTLS
            let accountID = string(at: 0, from: statement) ?? UUID().uuidString

            let account = MailboxAccount(
                id: accountID,
                label: string(at: 1, from: statement) ?? "",
                emailAddress: string(at: 2, from: statement) ?? "",
                role: role,
                workspaceRoot: string(at: 4, from: statement) ?? "",
                imap: MailServerEndpoint(
                    host: string(at: 5, from: statement) ?? "",
                    port: Int(sqlite3_column_int64(statement, 6)),
                    security: imapSecurity
                ),
                smtp: MailServerEndpoint(
                    host: string(at: 8, from: statement) ?? "",
                    port: Int(sqlite3_column_int64(statement, 9)),
                    security: smtpSecurity
                ),
                pollingIntervalSeconds: Int(sqlite3_column_int64(statement, 11)),
                createdAt: date(at: 12, from: statement),
                updatedAt: date(at: 13, from: statement)
            )

            rows.append(
                ConfiguredMailboxAccount(
                    account: account,
                    hasPasswordStored: secretStore.containsPassword(for: accountID)
                )
            )
        }

        return rows
    }

    func loadSenderPolicies() throws -> [SenderPolicy] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return []
        }

        let database = try openDatabase()
        defer { sqlite3_close(database) }

        let sql = """
        SELECT
            id,
            display_name,
            sender_address,
            assigned_role,
            allowed_workspace_roots_json,
            requires_reply_token,
            is_enabled,
            created_at,
            updated_at
        FROM sender_policies
        ORDER BY updated_at DESC;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteMailroomLocalStoreError.statementFailed(message(from: database!))
        }
        defer { sqlite3_finalize(statement) }

        var rows: [SenderPolicy] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let role = MailboxRole(rawValue: string(at: 3, from: statement) ?? "") ?? .operator
            let allowedRoots = decodeStringArray(from: string(at: 4, from: statement))

            rows.append(
                SenderPolicy(
                    id: string(at: 0, from: statement) ?? UUID().uuidString,
                    displayName: string(at: 1, from: statement) ?? "",
                    senderAddress: string(at: 2, from: statement) ?? "",
                    assignedRole: role,
                    allowedWorkspaceRoots: allowedRoots,
                    requiresReplyToken: sqlite3_column_int(statement, 5) != 0,
                    isEnabled: sqlite3_column_int(statement, 6) != 0,
                    createdAt: date(at: 7, from: statement),
                    updatedAt: date(at: 8, from: statement)
                )
            )
        }

        return rows
    }

    func loadManagedProjects() throws -> [ManagedProject] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return []
        }

        let database = try openDatabase()
        defer { sqlite3_close(database) }

        let sql = """
        SELECT
            id,
            display_name,
            slug,
            root_path,
            summary,
            default_capability,
            is_enabled,
            created_at,
            updated_at
        FROM managed_projects
        ORDER BY is_enabled DESC, display_name COLLATE NOCASE ASC, updated_at DESC;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            let details = message(from: database!)
            if details.localizedCaseInsensitiveContains("no such table: managed_projects") {
                return []
            }
            throw SQLiteMailroomLocalStoreError.statementFailed(details)
        }
        defer { sqlite3_finalize(statement) }

        var rows: [ManagedProject] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                ManagedProject(
                    id: string(at: 0, from: statement) ?? UUID().uuidString,
                    displayName: string(at: 1, from: statement) ?? "",
                    slug: string(at: 2, from: statement) ?? "",
                    rootPath: string(at: 3, from: statement) ?? "",
                    summary: string(at: 4, from: statement) ?? "",
                    defaultCapability: MailCapability(rawValue: string(at: 5, from: statement) ?? "") ?? .writeWorkspace,
                    isEnabled: sqlite3_column_int(statement, 6) != 0,
                    createdAt: date(at: 7, from: statement),
                    updatedAt: date(at: 8, from: statement)
                )
            )
        }

        return rows
    }

    func lastSeenUID(for accountID: String) throws -> UInt64? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return nil
        }

        let database = try openDatabase()
        defer { sqlite3_close(database) }

        let sql = """
        SELECT last_seen_uid
        FROM mailbox_sync_state
        WHERE account_id = ?
        LIMIT 1;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteMailroomLocalStoreError.statementFailed(message(from: database!))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, accountID, -1, Self.sqliteTransient)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : UInt64(sqlite3_column_int64(statement, 0))
    }

    func loadRecentMailboxMessages(limit: Int = 200, mailboxID: String? = nil) throws -> [MailroomMailboxMessageRecord] {
        guard FileManager.default.fileExists(atPath: databaseURL.path), limit > 0 else {
            return []
        }

        let database = try openDatabase()
        defer { sqlite3_close(database) }

        let sql: String
        if mailboxID == nil {
            sql = """
            SELECT
                messages.id,
                messages.mailbox_id,
                accounts.label,
                accounts.email_address,
                messages.uid,
                messages.message_id,
                messages.from_address,
                messages.from_display_name,
                messages.subject,
                messages.plain_body,
                messages.received_at,
                messages.in_reply_to,
                messages.references_json,
                messages.thread_token,
                messages.action,
                messages.outbound_message_id,
                messages.note,
                messages.processed_at,
                messages.updated_at
            FROM mail_messages AS messages
            LEFT JOIN mailbox_accounts AS accounts
                ON accounts.id = messages.mailbox_id
            ORDER BY messages.received_at DESC, messages.updated_at DESC
            LIMIT ?;
            """
        } else {
            sql = """
            SELECT
                messages.id,
                messages.mailbox_id,
                accounts.label,
                accounts.email_address,
                messages.uid,
                messages.message_id,
                messages.from_address,
                messages.from_display_name,
                messages.subject,
                messages.plain_body,
                messages.received_at,
                messages.in_reply_to,
                messages.references_json,
                messages.thread_token,
                messages.action,
                messages.outbound_message_id,
                messages.note,
                messages.processed_at,
                messages.updated_at
            FROM mail_messages AS messages
            LEFT JOIN mailbox_accounts AS accounts
                ON accounts.id = messages.mailbox_id
            WHERE messages.mailbox_id = ?
            ORDER BY messages.received_at DESC, messages.updated_at DESC
            LIMIT ?;
            """
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteMailroomLocalStoreError.statementFailed(message(from: database!))
        }
        defer { sqlite3_finalize(statement) }

        if let mailboxID {
            sqlite3_bind_text(statement, 1, mailboxID, -1, Self.sqliteTransient)
            sqlite3_bind_int64(statement, 2, Int64(limit))
        } else {
            sqlite3_bind_int64(statement, 1, Int64(limit))
        }

        var rows: [MailroomMailboxMessageRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(try decodeMailboxMessage(from: statement))
        }
        return rows
    }

    private func openDatabase() throws -> OpaquePointer? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let details = database.flatMap { message(from: $0) } ?? "Could not open database."
            sqlite3_close(database)
            throw SQLiteMailroomLocalStoreError.openFailed(details)
        }
        return database
    }

    private func string(at column: Int32, from statement: OpaquePointer?) -> String? {
        guard let value = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: value)
    }

    private func date(at column: Int32, from statement: OpaquePointer?) -> Date {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return Date()
        }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    private func uint64(at column: Int32, from statement: OpaquePointer?) -> UInt64? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return nil
        }
        return UInt64(sqlite3_column_int64(statement, column))
    }

    private func decodeMailboxMessage(from statement: OpaquePointer?) throws -> MailroomMailboxMessageRecord {
        MailroomMailboxMessageRecord(
            id: string(at: 0, from: statement) ?? UUID().uuidString,
            mailboxID: string(at: 1, from: statement) ?? "",
            mailboxLabel: string(at: 2, from: statement),
            mailboxEmailAddress: string(at: 3, from: statement),
            uid: uint64(at: 4, from: statement) ?? 0,
            messageID: string(at: 5, from: statement) ?? "",
            fromAddress: string(at: 6, from: statement) ?? "",
            fromDisplayName: string(at: 7, from: statement),
            subject: string(at: 8, from: statement) ?? "",
            plainBody: string(at: 9, from: statement) ?? "",
            receivedAt: date(at: 10, from: statement),
            inReplyTo: string(at: 11, from: statement),
            references: decodeStringArray(from: string(at: 12, from: statement)),
            threadToken: string(at: 13, from: statement),
            action: MailroomMailboxMessageAction(rawValue: string(at: 14, from: statement) ?? "") ?? .received,
            outboundMessageID: string(at: 15, from: statement),
            note: string(at: 16, from: statement) ?? "",
            processedAt: sqlite3_column_type(statement, 17) == SQLITE_NULL ? nil : date(at: 17, from: statement),
            updatedAt: date(at: 18, from: statement)
        )
    }

    private func decodeStringArray(from json: String?) -> [String] {
        guard let json,
              let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return values
    }

    private func message(from database: OpaquePointer) -> String {
        guard let error = sqlite3_errmsg(database) else {
            return "Unknown SQLite error."
        }
        return String(cString: error)
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

enum SQLiteMailroomLocalStoreError: LocalizedError {
    case openFailed(String)
    case statementFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message), .statementFailed(let message):
            return message
        }
    }
}
