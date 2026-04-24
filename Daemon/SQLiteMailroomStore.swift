import Foundation
import SQLite3

struct SQLiteMailroomStore: Sendable {
    let databasePath: String

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(databasePath: String) throws {
        self.databasePath = databasePath
        let databaseURL = URL(fileURLWithPath: databasePath)
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try migrateIfNeeded()
    }
}

extension SQLiteMailroomStore: ThreadStore {
    func save(thread: MailroomThreadRecord) async throws {
        try withDatabase { database in
            let sql = """
            INSERT INTO mail_threads (
                id,
                mailbox_id,
                normalized_sender,
                subject,
                codex_thread_id,
                workspace_root,
                capability,
                status,
                pending_stage,
                pending_prompt_body,
                managed_project_id,
                last_inbound_message_id,
                last_outbound_message_id,
                created_at,
                updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                mailbox_id = excluded.mailbox_id,
                normalized_sender = excluded.normalized_sender,
                subject = excluded.subject,
                codex_thread_id = excluded.codex_thread_id,
                workspace_root = excluded.workspace_root,
                capability = excluded.capability,
                status = excluded.status,
                pending_stage = excluded.pending_stage,
                pending_prompt_body = excluded.pending_prompt_body,
                managed_project_id = excluded.managed_project_id,
                last_inbound_message_id = excluded.last_inbound_message_id,
                last_outbound_message_id = excluded.last_outbound_message_id,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at;
            """

            let statement = try prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }

            bind(thread.id, at: 1, in: statement)
            bind(thread.mailboxID, at: 2, in: statement)
            bind(thread.normalizedSender, at: 3, in: statement)
            bind(thread.subject, at: 4, in: statement)
            bind(thread.codexThreadID, at: 5, in: statement)
            bind(thread.workspaceRoot, at: 6, in: statement)
            bind(thread.capability.rawValue, at: 7, in: statement)
            bind(thread.status.rawValue, at: 8, in: statement)
            bind(thread.pendingStage?.rawValue, at: 9, in: statement)
            bind(thread.pendingPromptBody, at: 10, in: statement)
            bind(thread.managedProjectID, at: 11, in: statement)
            bind(thread.lastInboundMessageID, at: 12, in: statement)
            bind(thread.lastOutboundMessageID, at: 13, in: statement)
            bind(thread.createdAt.timeIntervalSince1970, at: 14, in: statement)
            bind(thread.updatedAt.timeIntervalSince1970, at: 15, in: statement)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteMailroomStoreError.statementFailed(message(from: database))
            }
        }
    }

    func thread(token: String) async throws -> MailroomThreadRecord? {
        try withDatabase { database in
            let sql = """
            SELECT
                id,
                mailbox_id,
                normalized_sender,
                subject,
                codex_thread_id,
                workspace_root,
                capability,
                status,
                pending_stage,
                pending_prompt_body,
                managed_project_id,
                last_inbound_message_id,
                last_outbound_message_id,
                created_at,
                updated_at
            FROM mail_threads
            WHERE id = ?
            LIMIT 1;
            """

            let statement = try prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }
            bind(token, at: 1, in: statement)

            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            return try decodeThread(from: statement)
        }
    }

    func thread(codexThreadID: String) async throws -> MailroomThreadRecord? {
        try withDatabase { database in
            let sql = """
            SELECT
                id,
                mailbox_id,
                normalized_sender,
                subject,
                codex_thread_id,
                workspace_root,
                capability,
                status,
                pending_stage,
                pending_prompt_body,
                managed_project_id,
                last_inbound_message_id,
                last_outbound_message_id,
                created_at,
                updated_at
            FROM mail_threads
            WHERE codex_thread_id = ?
            LIMIT 1;
            """

            let statement = try prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }
            bind(codexThreadID, at: 1, in: statement)

            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            return try decodeThread(from: statement)
        }
    }

    func allThreads() async throws -> [MailroomThreadRecord] {
        try withDatabase { database in
            let sql = """
            SELECT
                id,
                mailbox_id,
                normalized_sender,
                subject,
                codex_thread_id,
                workspace_root,
                capability,
                status,
                pending_stage,
                pending_prompt_body,
                managed_project_id,
                last_inbound_message_id,
                last_outbound_message_id,
                created_at,
                updated_at
            FROM mail_threads
            ORDER BY updated_at DESC;
            """

            let statement = try prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }

            var rows: [MailroomThreadRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(try decodeThread(from: statement))
            }
            return rows
        }
    }
}

extension SQLiteMailroomStore: ApprovalStore {
    func save(approval: MailroomApprovalRequest) async throws {
        try withDatabase { database in
            let sql = """
            INSERT INTO approval_requests (
                id,
                rpc_id_kind,
                rpc_id_value,
                kind,
                mail_thread_token,
                codex_thread_id,
                codex_turn_id,
                item_id,
                summary,
                detail,
                available_decisions_json,
                raw_payload_json,
                status,
                resolved_decision,
                resolution_note,
                created_at,
                resolved_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                rpc_id_kind = excluded.rpc_id_kind,
                rpc_id_value = excluded.rpc_id_value,
                kind = excluded.kind,
                mail_thread_token = excluded.mail_thread_token,
                codex_thread_id = excluded.codex_thread_id,
                codex_turn_id = excluded.codex_turn_id,
                item_id = excluded.item_id,
                summary = excluded.summary,
                detail = excluded.detail,
                available_decisions_json = excluded.available_decisions_json,
                raw_payload_json = excluded.raw_payload_json,
                status = excluded.status,
                resolved_decision = excluded.resolved_decision,
                resolution_note = excluded.resolution_note,
                created_at = excluded.created_at,
                resolved_at = excluded.resolved_at;
            """

            let statement = try prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }

            bind(approval.id, at: 1, in: statement)
            bind(approval.rpcRequestID.persistedKind, at: 2, in: statement)
            bind(approval.rpcRequestID.persistedValue, at: 3, in: statement)
            bind(approval.kind.rawValue, at: 4, in: statement)
            bind(approval.mailThreadToken, at: 5, in: statement)
            bind(approval.codexThreadID, at: 6, in: statement)
            bind(approval.codexTurnID, at: 7, in: statement)
            bind(approval.itemID, at: 8, in: statement)
            bind(approval.summary, at: 9, in: statement)
            bind(approval.detail, at: 10, in: statement)
            bind(try encodeJSON(approval.availableDecisions), at: 11, in: statement)
            bind(try encodeJSON(approval.rawPayload), at: 12, in: statement)
            bind(approval.status.rawValue, at: 13, in: statement)
            bind(approval.resolvedDecision, at: 14, in: statement)
            bind(approval.resolutionNote, at: 15, in: statement)
            bind(approval.createdAt.timeIntervalSince1970, at: 16, in: statement)
            bind(approval.resolvedAt?.timeIntervalSince1970, at: 17, in: statement)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteMailroomStoreError.statementFailed(message(from: database))
            }
        }
    }

    func approval(id: String) async throws -> MailroomApprovalRequest? {
        try withDatabase { database in
            let sql = """
            SELECT
                id,
                rpc_id_kind,
                rpc_id_value,
                kind,
                mail_thread_token,
                codex_thread_id,
                codex_turn_id,
                item_id,
                summary,
                detail,
                available_decisions_json,
                raw_payload_json,
                status,
                resolved_decision,
                resolution_note,
                created_at,
                resolved_at
            FROM approval_requests
            WHERE id = ?
            LIMIT 1;
            """

            let statement = try prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }
            bind(id, at: 1, in: statement)

            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            return try decodeApproval(from: statement)
        }
    }

    func allApprovals() async throws -> [MailroomApprovalRequest] {
        try withDatabase { database in
            let sql = """
            SELECT
                id,
                rpc_id_kind,
                rpc_id_value,
                kind,
                mail_thread_token,
                codex_thread_id,
                codex_turn_id,
                item_id,
                summary,
                detail,
                available_decisions_json,
                raw_payload_json,
                status,
                resolved_decision,
                resolution_note,
                created_at,
                resolved_at
            FROM approval_requests
            ORDER BY CASE status WHEN 'pending' THEN 0 ELSE 1 END, created_at DESC;
            """

            let statement = try prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }

            var rows: [MailroomApprovalRequest] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(try decodeApproval(from: statement))
            }
            return rows
        }
    }
}

extension SQLiteMailroomStore: EventStore {
    func append(event: MailroomEventRecord) async throws {
        try withDatabase { database in
            let sql = """
            INSERT INTO event_log (
                id,
                source,
                method,
                codex_thread_id,
                codex_turn_id,
                payload_json,
                created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?);
            """

            let statement = try prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }

            bind(event.id, at: 1, in: statement)
            bind(event.source, at: 2, in: statement)
            bind(event.method, at: 3, in: statement)
            bind(event.codexThreadID, at: 4, in: statement)
            bind(event.codexTurnID, at: 5, in: statement)
            bind(try encodeJSON(event.payload), at: 6, in: statement)
            bind(event.createdAt.timeIntervalSince1970, at: 7, in: statement)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteMailroomStoreError.statementFailed(message(from: database))
            }
        }
    }

    func allEvents() async throws -> [MailroomEventRecord] {
        try withDatabase { database in
            let sql = """
            SELECT
                id,
                source,
                method,
                codex_thread_id,
                codex_turn_id,
                payload_json,
                created_at
            FROM event_log
            ORDER BY created_at ASC;
            """

            let statement = try prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }

            var rows: [MailroomEventRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(try decodeEvent(from: statement))
            }
            return rows
        }
    }
}

extension SQLiteMailroomStore: MailboxSyncStore {
    func save(syncCursor: MailroomMailboxSyncCursor) async throws {
        try withDatabase { database in
            let sql = """
            INSERT INTO mailbox_sync_state (
                account_id,
                last_seen_uid,
                last_processed_at
            ) VALUES (?, ?, ?)
            ON CONFLICT(account_id) DO UPDATE SET
                last_seen_uid = excluded.last_seen_uid,
                last_processed_at = excluded.last_processed_at;
            """

            let statement = try prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }

            bind(syncCursor.accountID, at: 1, in: statement)
            bind(syncCursor.lastSeenUID.flatMap { Int64(exactly: $0) }, at: 2, in: statement)
            bind(syncCursor.lastProcessedAt?.timeIntervalSince1970, at: 3, in: statement)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteMailroomStoreError.statementFailed(message(from: database))
            }
        }
    }

    func syncCursor(accountID: String) async throws -> MailroomMailboxSyncCursor? {
        try withDatabase { database in
            let sql = """
            SELECT
                account_id,
                last_seen_uid,
                last_processed_at
            FROM mailbox_sync_state
            WHERE account_id = ?
            LIMIT 1;
            """

            let statement = try prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }
            bind(accountID, at: 1, in: statement)

            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            return decodeSyncCursor(from: statement)
        }
    }

    func allSyncCursors() async throws -> [MailroomMailboxSyncCursor] {
        try withDatabase { database in
            let sql = """
            SELECT
                account_id,
                last_seen_uid,
                last_processed_at
            FROM mailbox_sync_state
            ORDER BY account_id ASC;
            """

            let statement = try prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }

            var rows: [MailroomMailboxSyncCursor] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(decodeSyncCursor(from: statement))
            }
            return rows
        }
    }
}

extension SQLiteMailroomStore: MailboxMessageStore {
    func save(mailboxMessage: MailroomMailboxMessageRecord) async throws {
        try withDatabase { database in
            let sql = """
            INSERT INTO mail_messages (
                id,
                mailbox_id,
                uid,
                message_id,
                from_address,
                from_display_name,
                subject,
                plain_body,
                received_at,
                in_reply_to,
                references_json,
                thread_token,
                action,
                outbound_message_id,
                note,
                processed_at,
                updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                mailbox_id = excluded.mailbox_id,
                uid = excluded.uid,
                message_id = excluded.message_id,
                from_address = excluded.from_address,
                from_display_name = excluded.from_display_name,
                subject = excluded.subject,
                plain_body = excluded.plain_body,
                received_at = excluded.received_at,
                in_reply_to = excluded.in_reply_to,
                references_json = excluded.references_json,
                thread_token = excluded.thread_token,
                action = excluded.action,
                outbound_message_id = excluded.outbound_message_id,
                note = excluded.note,
                processed_at = excluded.processed_at,
                updated_at = excluded.updated_at;
            """

            let statement = try prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }

            bind(mailboxMessage.id, at: 1, in: statement)
            bind(mailboxMessage.mailboxID, at: 2, in: statement)
            bind(Int64(exactly: mailboxMessage.uid), at: 3, in: statement)
            bind(mailboxMessage.messageID, at: 4, in: statement)
            bind(mailboxMessage.fromAddress, at: 5, in: statement)
            bind(mailboxMessage.fromDisplayName, at: 6, in: statement)
            bind(mailboxMessage.subject, at: 7, in: statement)
            bind(mailboxMessage.plainBody, at: 8, in: statement)
            bind(mailboxMessage.receivedAt.timeIntervalSince1970, at: 9, in: statement)
            bind(mailboxMessage.inReplyTo, at: 10, in: statement)
            bind(try encodeJSON(mailboxMessage.references), at: 11, in: statement)
            bind(mailboxMessage.threadToken, at: 12, in: statement)
            bind(mailboxMessage.action.rawValue, at: 13, in: statement)
            bind(mailboxMessage.outboundMessageID, at: 14, in: statement)
            bind(mailboxMessage.note, at: 15, in: statement)
            bind(mailboxMessage.processedAt?.timeIntervalSince1970, at: 16, in: statement)
            bind(mailboxMessage.updatedAt.timeIntervalSince1970, at: 17, in: statement)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteMailroomStoreError.statementFailed(message(from: database))
            }
        }
    }

    func recentMailboxMessages(limit: Int, mailboxID: String?) async throws -> [MailroomMailboxMessageRecord] {
        guard limit > 0 else {
            return []
        }

        return try withDatabase { database in
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

            let statement = try prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }

            if let mailboxID {
                bind(mailboxID, at: 1, in: statement)
                bind(Int64(limit), at: 2, in: statement)
            } else {
                bind(Int64(limit), at: 1, in: statement)
            }

            var rows: [MailroomMailboxMessageRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(try decodeMailboxMessage(from: statement))
            }
            return rows
        }
    }
}

extension SQLiteMailroomStore: TurnStore {
    func save(turn: MailroomTurnRecord) async throws {
        try withDatabase { database in
            let sql = """
            INSERT INTO codex_turns (
                id,
                mail_thread_token,
                codex_thread_id,
                origin,
                status,
                prompt_preview,
                last_notified_state,
                last_notified_approval_id,
                last_notification_message_id,
                started_at,
                completed_at,
                updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                mail_thread_token = excluded.mail_thread_token,
                codex_thread_id = excluded.codex_thread_id,
                origin = excluded.origin,
                status = excluded.status,
                prompt_preview = excluded.prompt_preview,
                last_notified_state = excluded.last_notified_state,
                last_notified_approval_id = excluded.last_notified_approval_id,
                last_notification_message_id = excluded.last_notification_message_id,
                started_at = excluded.started_at,
                completed_at = excluded.completed_at,
                updated_at = excluded.updated_at;
            """

            let statement = try prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }

            bind(turn.id, at: 1, in: statement)
            bind(turn.mailThreadToken, at: 2, in: statement)
            bind(turn.codexThreadID, at: 3, in: statement)
            bind(turn.origin.rawValue, at: 4, in: statement)
            bind(turn.status.rawValue, at: 5, in: statement)
            bind(turn.promptPreview, at: 6, in: statement)
            bind(turn.lastNotifiedState?.rawValue, at: 7, in: statement)
            bind(turn.lastNotifiedApprovalID, at: 8, in: statement)
            bind(turn.lastNotificationMessageID, at: 9, in: statement)
            bind(turn.startedAt.timeIntervalSince1970, at: 10, in: statement)
            bind(turn.completedAt?.timeIntervalSince1970, at: 11, in: statement)
            bind(turn.updatedAt.timeIntervalSince1970, at: 12, in: statement)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteMailroomStoreError.statementFailed(message(from: database))
            }
        }
    }

    func turn(id: String) async throws -> MailroomTurnRecord? {
        try withDatabase { database in
            let sql = """
            SELECT
                id,
                mail_thread_token,
                codex_thread_id,
                origin,
                status,
                prompt_preview,
                last_notified_state,
                last_notified_approval_id,
                last_notification_message_id,
                started_at,
                completed_at,
                updated_at
            FROM codex_turns
            WHERE id = ?
            LIMIT 1;
            """

            let statement = try prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }
            bind(id, at: 1, in: statement)

            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }
            return decodeTurn(from: statement)
        }
    }

    func allTurns() async throws -> [MailroomTurnRecord] {
        try withDatabase { database in
            let sql = """
            SELECT
                id,
                mail_thread_token,
                codex_thread_id,
                origin,
                status,
                prompt_preview,
                last_notified_state,
                last_notified_approval_id,
                last_notification_message_id,
                started_at,
                completed_at,
                updated_at
            FROM codex_turns
            ORDER BY updated_at DESC;
            """

            let statement = try prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }

            var rows: [MailroomTurnRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(decodeTurn(from: statement))
            }
            return rows
        }
    }
}

extension SQLiteMailroomStore: MailboxAccountConfigStore {
    func allMailboxAccounts() async throws -> [MailboxAccount] {
        try withDatabase { database in
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
            ORDER BY label COLLATE NOCASE ASC, email_address COLLATE NOCASE ASC;
            """

            let statement = try prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }

            var rows: [MailboxAccount] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(decodeMailboxAccount(from: statement))
            }
            return rows
        }
    }

    func upsertMailboxAccount(_ account: MailboxAccount) async throws {
        try withDatabase { database in
            let sql = """
            INSERT INTO mailbox_accounts (
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
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                label = excluded.label,
                email_address = excluded.email_address,
                role = excluded.role,
                workspace_root = excluded.workspace_root,
                imap_host = excluded.imap_host,
                imap_port = excluded.imap_port,
                imap_security = excluded.imap_security,
                smtp_host = excluded.smtp_host,
                smtp_port = excluded.smtp_port,
                smtp_security = excluded.smtp_security,
                polling_interval_seconds = excluded.polling_interval_seconds,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at;
            """

            let statement = try prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }

            bind(account.id, at: 1, in: statement)
            bind(account.label, at: 2, in: statement)
            bind(account.emailAddress, at: 3, in: statement)
            bind(account.role.rawValue, at: 4, in: statement)
            bind(account.workspaceRoot, at: 5, in: statement)
            bind(account.imap.host, at: 6, in: statement)
            bind(Int64(account.imap.port), at: 7, in: statement)
            bind(account.imap.security.rawValue, at: 8, in: statement)
            bind(account.smtp.host, at: 9, in: statement)
            bind(Int64(account.smtp.port), at: 10, in: statement)
            bind(account.smtp.security.rawValue, at: 11, in: statement)
            bind(Int64(account.pollingIntervalSeconds), at: 12, in: statement)
            bind(account.createdAt.timeIntervalSince1970, at: 13, in: statement)
            bind(account.updatedAt.timeIntervalSince1970, at: 14, in: statement)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteMailroomStoreError.statementFailed(message(from: database))
            }
        }
    }

    func deleteMailboxAccount(accountID: String) async throws {
        try withDatabase { database in
            let sql = "DELETE FROM mailbox_accounts WHERE id = ?;"
            let statement = try prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }

            bind(accountID, at: 1, in: statement)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteMailroomStoreError.statementFailed(message(from: database))
            }
        }
    }
}

extension SQLiteMailroomStore: SenderPolicyConfigStore {
    func allSenderPolicies() async throws -> [SenderPolicy] {
        try withDatabase { database in
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
            ORDER BY sender_address COLLATE NOCASE ASC;
            """

            let statement = try prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }

            var rows: [SenderPolicy] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(try decodeSenderPolicy(from: statement))
            }
            return rows
        }
    }

    func upsertSenderPolicy(_ policy: SenderPolicy) async throws {
        try withDatabase { database in
            let sql = """
            INSERT INTO sender_policies (
                id,
                display_name,
                sender_address,
                assigned_role,
                allowed_workspace_roots_json,
                requires_reply_token,
                is_enabled,
                created_at,
                updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                display_name = excluded.display_name,
                sender_address = excluded.sender_address,
                assigned_role = excluded.assigned_role,
                allowed_workspace_roots_json = excluded.allowed_workspace_roots_json,
                requires_reply_token = excluded.requires_reply_token,
                is_enabled = excluded.is_enabled,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at;
            """

            let statement = try prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }

            bind(policy.id, at: 1, in: statement)
            bind(policy.displayName, at: 2, in: statement)
            bind(policy.senderAddress, at: 3, in: statement)
            bind(policy.assignedRole.rawValue, at: 4, in: statement)
            bind(try encodeJSON(policy.allowedWorkspaceRoots), at: 5, in: statement)
            bind(policy.requiresReplyToken ? Int64(1) : Int64(0), at: 6, in: statement)
            bind(policy.isEnabled ? Int64(1) : Int64(0), at: 7, in: statement)
            bind(policy.createdAt.timeIntervalSince1970, at: 8, in: statement)
            bind(policy.updatedAt.timeIntervalSince1970, at: 9, in: statement)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteMailroomStoreError.statementFailed(message(from: database))
            }
        }
    }

    func deleteSenderPolicy(policyID: String) async throws {
        try withDatabase { database in
            let sql = "DELETE FROM sender_policies WHERE id = ?;"
            let statement = try prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }

            bind(policyID, at: 1, in: statement)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteMailroomStoreError.statementFailed(message(from: database))
            }
        }
    }
}

extension SQLiteMailroomStore: ManagedProjectConfigStore {
    func allManagedProjects() async throws -> [ManagedProject] {
        try withDatabase { database in
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

            let statement = try prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }

            var rows: [ManagedProject] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(decodeManagedProject(from: statement))
            }
            return rows
        }
    }

    func upsertManagedProject(_ project: ManagedProject) async throws {
        try withDatabase { database in
            let sql = """
            INSERT INTO managed_projects (
                id,
                display_name,
                slug,
                root_path,
                summary,
                default_capability,
                is_enabled,
                created_at,
                updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                display_name = excluded.display_name,
                slug = excluded.slug,
                root_path = excluded.root_path,
                summary = excluded.summary,
                default_capability = excluded.default_capability,
                is_enabled = excluded.is_enabled,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at;
            """

            let statement = try prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }

            bind(project.id, at: 1, in: statement)
            bind(project.displayName, at: 2, in: statement)
            bind(project.slug, at: 3, in: statement)
            bind(project.rootPath, at: 4, in: statement)
            bind(project.summary, at: 5, in: statement)
            bind(project.defaultCapability.rawValue, at: 6, in: statement)
            bind(project.isEnabled ? Int64(1) : Int64(0), at: 7, in: statement)
            bind(project.createdAt.timeIntervalSince1970, at: 8, in: statement)
            bind(project.updatedAt.timeIntervalSince1970, at: 9, in: statement)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteMailroomStoreError.statementFailed(message(from: database))
            }
        }
    }

    func deleteManagedProject(projectID: String) async throws {
        try withDatabase { database in
            let sql = "DELETE FROM managed_projects WHERE id = ?;"
            let statement = try prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }

            bind(projectID, at: 1, in: statement)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteMailroomStoreError.statementFailed(message(from: database))
            }
        }
    }
}

private extension SQLiteMailroomStore {
    func migrateIfNeeded() throws {
        try withDatabase { database in
            try execute("PRAGMA journal_mode = WAL;", in: database)
            try execute(
                """
                CREATE TABLE IF NOT EXISTS mail_threads (
                    id TEXT PRIMARY KEY,
                    mailbox_id TEXT NOT NULL,
                    normalized_sender TEXT NOT NULL,
                    subject TEXT NOT NULL,
                    codex_thread_id TEXT,
                    workspace_root TEXT NOT NULL,
                    capability TEXT NOT NULL,
                    status TEXT NOT NULL,
                    pending_stage TEXT,
                    pending_prompt_body TEXT,
                    managed_project_id TEXT,
                    last_inbound_message_id TEXT,
                    last_outbound_message_id TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                """,
                in: database
            )
            try ensureColumn(
                table: "mail_threads",
                named: "pending_prompt_body",
                definition: "TEXT",
                in: database
            )
            try ensureColumn(
                table: "mail_threads",
                named: "pending_stage",
                definition: "TEXT",
                in: database
            )
            try ensureColumn(
                table: "mail_threads",
                named: "managed_project_id",
                definition: "TEXT",
                in: database
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS approval_requests (
                    id TEXT PRIMARY KEY,
                    rpc_id_kind TEXT NOT NULL,
                    rpc_id_value TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    mail_thread_token TEXT,
                    codex_thread_id TEXT NOT NULL,
                    codex_turn_id TEXT NOT NULL,
                    item_id TEXT NOT NULL,
                    summary TEXT NOT NULL,
                    detail TEXT,
                    available_decisions_json TEXT NOT NULL,
                    raw_payload_json TEXT NOT NULL,
                    status TEXT NOT NULL,
                    resolved_decision TEXT,
                    resolution_note TEXT,
                    created_at REAL NOT NULL,
                    resolved_at REAL
                );
                """,
                in: database
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS event_log (
                    id TEXT PRIMARY KEY,
                    source TEXT NOT NULL,
                    method TEXT NOT NULL,
                    codex_thread_id TEXT,
                    codex_turn_id TEXT,
                    payload_json TEXT NOT NULL,
                    created_at REAL NOT NULL
                );
                """,
                in: database
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS mailbox_accounts (
                    id TEXT PRIMARY KEY,
                    label TEXT NOT NULL,
                    email_address TEXT NOT NULL,
                    role TEXT NOT NULL,
                    workspace_root TEXT NOT NULL,
                    imap_host TEXT NOT NULL,
                    imap_port INTEGER NOT NULL,
                    imap_security TEXT NOT NULL,
                    smtp_host TEXT NOT NULL,
                    smtp_port INTEGER NOT NULL,
                    smtp_security TEXT NOT NULL,
                    polling_interval_seconds INTEGER NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                """,
                in: database
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS sender_policies (
                    id TEXT PRIMARY KEY,
                    display_name TEXT NOT NULL,
                    sender_address TEXT NOT NULL,
                    assigned_role TEXT NOT NULL,
                    allowed_workspace_roots_json TEXT NOT NULL,
                    requires_reply_token INTEGER NOT NULL,
                    is_enabled INTEGER NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                """,
                in: database
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS managed_projects (
                    id TEXT PRIMARY KEY,
                    display_name TEXT NOT NULL,
                    slug TEXT NOT NULL,
                    root_path TEXT NOT NULL,
                    summary TEXT NOT NULL,
                    default_capability TEXT NOT NULL,
                    is_enabled INTEGER NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                """,
                in: database
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS mailbox_sync_state (
                    account_id TEXT PRIMARY KEY,
                    last_seen_uid INTEGER,
                    last_processed_at REAL
                );
                """,
                in: database
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS mail_messages (
                    id TEXT PRIMARY KEY,
                    mailbox_id TEXT NOT NULL,
                    uid INTEGER NOT NULL,
                    message_id TEXT NOT NULL,
                    from_address TEXT NOT NULL,
                    from_display_name TEXT,
                    subject TEXT NOT NULL,
                    plain_body TEXT NOT NULL,
                    received_at REAL NOT NULL,
                    in_reply_to TEXT,
                    references_json TEXT NOT NULL,
                    thread_token TEXT,
                    action TEXT NOT NULL,
                    outbound_message_id TEXT,
                    note TEXT NOT NULL,
                    processed_at REAL,
                    updated_at REAL NOT NULL
                );
                """,
                in: database
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS codex_turns (
                    id TEXT PRIMARY KEY,
                    mail_thread_token TEXT,
                    codex_thread_id TEXT NOT NULL,
                    origin TEXT NOT NULL,
                    status TEXT NOT NULL,
                    prompt_preview TEXT,
                    last_notified_state TEXT,
                    last_notified_approval_id TEXT,
                    last_notification_message_id TEXT,
                    started_at REAL NOT NULL,
                    completed_at REAL,
                    updated_at REAL NOT NULL
                );
                """,
                in: database
            )
            try ensureColumn(
                table: "codex_turns",
                named: "last_notified_approval_id",
                definition: "TEXT",
                in: database
            )
            try execute("CREATE INDEX IF NOT EXISTS idx_mail_threads_updated_at ON mail_threads(updated_at DESC);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_mail_threads_codex_thread_id ON mail_threads(codex_thread_id);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_mailbox_accounts_label ON mailbox_accounts(label COLLATE NOCASE);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_mailbox_accounts_email ON mailbox_accounts(email_address COLLATE NOCASE);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_sender_policies_sender ON sender_policies(sender_address COLLATE NOCASE);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_managed_projects_slug ON managed_projects(slug COLLATE NOCASE);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_managed_projects_root_path ON managed_projects(root_path COLLATE NOCASE);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_approval_requests_created_at ON approval_requests(created_at DESC);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_approval_requests_status ON approval_requests(status);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_event_log_created_at ON event_log(created_at ASC);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_codex_turns_status ON codex_turns(status);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_codex_turns_thread_id ON codex_turns(codex_thread_id);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_codex_turns_mail_thread_token ON codex_turns(mail_thread_token);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_mail_messages_mailbox_received_at ON mail_messages(mailbox_id, received_at DESC);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_mail_messages_received_at ON mail_messages(received_at DESC);", in: database)
            try execute("CREATE INDEX IF NOT EXISTS idx_mail_messages_message_id ON mail_messages(message_id);", in: database)
        }
    }

    func withDatabase<T>(_ body: (OpaquePointer?) throws -> T) throws -> T {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        return try body(database)
    }

    func openDatabase() throws -> OpaquePointer? {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databasePath, &database, flags, nil) == SQLITE_OK else {
            let failureMessage = message(from: database)
            sqlite3_close(database)
            throw SQLiteMailroomStoreError.openFailed(failureMessage)
        }
        sqlite3_busy_timeout(database, 5_000)
        return database
    }

    func prepare(_ sql: String, in database: OpaquePointer?) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteMailroomStoreError.statementFailed(message(from: database))
        }
        return statement
    }

    func execute(_ sql: String, in database: OpaquePointer?) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? self.message(from: database)
            sqlite3_free(errorMessage)
            throw SQLiteMailroomStoreError.statementFailed(message)
        }
    }

    func bind(_ value: String?, at index: Int32, in statement: OpaquePointer?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, Self.sqliteTransient)
    }

    func bind(_ value: Double?, at index: Int32, in statement: OpaquePointer?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, value)
    }

    func bind(_ value: Int64?, at index: Int32, in statement: OpaquePointer?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, value)
    }

    func string(at index: Int32, from statement: OpaquePointer?) -> String? {
        guard let rawText = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: rawText)
    }

    func double(at index: Int32, from statement: OpaquePointer?) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return sqlite3_column_double(statement, index)
    }

    func int64(at index: Int32, from statement: OpaquePointer?) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return sqlite3_column_int64(statement, index)
    }

    func date(at index: Int32, from statement: OpaquePointer?) -> Date? {
        guard let interval = double(at: index, from: statement) else {
            return nil
        }
        return Date(timeIntervalSince1970: interval)
    }

    func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    func decodeJSON<T: Decodable>(_ type: T.Type, from rawValue: String?) throws -> T {
        guard let rawValue else {
            throw SQLiteMailroomStoreError.decodeFailed("Missing JSON payload for \(type).")
        }
        guard let data = rawValue.data(using: .utf8) else {
            throw SQLiteMailroomStoreError.decodeFailed("Invalid UTF-8 payload for \(type).")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw SQLiteMailroomStoreError.decodeFailed(error.localizedDescription)
        }
    }

    func decodeThread(from statement: OpaquePointer?) throws -> MailroomThreadRecord {
        MailroomThreadRecord(
            id: string(at: 0, from: statement) ?? UUID().uuidString,
            mailboxID: string(at: 1, from: statement) ?? "default",
            normalizedSender: string(at: 2, from: statement) ?? "unknown@example.com",
            subject: string(at: 3, from: statement) ?? "",
            codexThreadID: string(at: 4, from: statement),
            workspaceRoot: string(at: 5, from: statement) ?? "",
            capability: MailroomCapability(rawValue: string(at: 6, from: statement) ?? "") ?? .writeWorkspace,
            status: MailroomThreadStatus(rawValue: string(at: 7, from: statement) ?? "") ?? .pending,
            pendingStage: string(at: 8, from: statement).flatMap(MailroomPendingThreadStage.init(rawValue:)),
            pendingPromptBody: string(at: 9, from: statement),
            managedProjectID: string(at: 10, from: statement),
            lastInboundMessageID: string(at: 11, from: statement),
            lastOutboundMessageID: string(at: 12, from: statement),
            createdAt: date(at: 13, from: statement) ?? Date(),
            updatedAt: date(at: 14, from: statement) ?? Date()
        )
    }

    func decodeApproval(from statement: OpaquePointer?) throws -> MailroomApprovalRequest {
        let rpcKind = string(at: 1, from: statement) ?? "string"
        let rpcValue = string(at: 2, from: statement) ?? ""
        return MailroomApprovalRequest(
            id: string(at: 0, from: statement) ?? UUID().uuidString,
            rpcRequestID: JSONRPCID.persisted(kind: rpcKind, value: rpcValue),
            kind: MailroomApprovalKind(rawValue: string(at: 3, from: statement) ?? "") ?? .other,
            mailThreadToken: string(at: 4, from: statement),
            codexThreadID: string(at: 5, from: statement) ?? "unknown",
            codexTurnID: string(at: 6, from: statement) ?? "unknown",
            itemID: string(at: 7, from: statement) ?? "unknown",
            summary: string(at: 8, from: statement) ?? "",
            detail: string(at: 9, from: statement),
            availableDecisions: try decodeJSON([String].self, from: string(at: 10, from: statement)),
            rawPayload: try decodeJSON(JSONValue.self, from: string(at: 11, from: statement)),
            status: MailroomApprovalStatus(rawValue: string(at: 12, from: statement) ?? "") ?? .pending,
            resolvedDecision: string(at: 13, from: statement),
            resolutionNote: string(at: 14, from: statement),
            createdAt: date(at: 15, from: statement) ?? Date(),
            resolvedAt: date(at: 16, from: statement)
        )
    }

    func decodeEvent(from statement: OpaquePointer?) throws -> MailroomEventRecord {
        MailroomEventRecord(
            id: string(at: 0, from: statement) ?? UUID().uuidString,
            source: string(at: 1, from: statement) ?? "unknown",
            method: string(at: 2, from: statement) ?? "unknown",
            codexThreadID: string(at: 3, from: statement),
            codexTurnID: string(at: 4, from: statement),
            payload: try decodeJSON(JSONValue.self, from: string(at: 5, from: statement)),
            createdAt: date(at: 6, from: statement) ?? Date()
        )
    }

    func decodeSyncCursor(from statement: OpaquePointer?) -> MailroomMailboxSyncCursor {
        MailroomMailboxSyncCursor(
            accountID: string(at: 0, from: statement) ?? "",
            lastSeenUID: int64(at: 1, from: statement).flatMap(UInt64.init),
            lastProcessedAt: date(at: 2, from: statement)
        )
    }

    func decodeTurn(from statement: OpaquePointer?) -> MailroomTurnRecord {
        MailroomTurnRecord(
            id: string(at: 0, from: statement) ?? UUID().uuidString,
            mailThreadToken: string(at: 1, from: statement),
            codexThreadID: string(at: 2, from: statement) ?? "unknown",
            origin: MailroomTurnOrigin(rawValue: string(at: 3, from: statement) ?? "") ?? .localConsole,
            status: MailroomTurnStatus(rawValue: string(at: 4, from: statement) ?? "") ?? .active,
            promptPreview: string(at: 5, from: statement),
            lastNotifiedState: string(at: 6, from: statement).flatMap(MailroomTurnOutcomeState.init(rawValue:)),
            lastNotifiedApprovalID: string(at: 7, from: statement),
            lastNotificationMessageID: string(at: 8, from: statement),
            startedAt: date(at: 9, from: statement) ?? Date(),
            completedAt: date(at: 10, from: statement),
            updatedAt: date(at: 11, from: statement) ?? Date()
        )
    }

    func decodeMailboxMessage(from statement: OpaquePointer?) throws -> MailroomMailboxMessageRecord {
        MailroomMailboxMessageRecord(
            id: string(at: 0, from: statement) ?? UUID().uuidString,
            mailboxID: string(at: 1, from: statement) ?? "",
            mailboxLabel: string(at: 2, from: statement),
            mailboxEmailAddress: string(at: 3, from: statement),
            uid: int64(at: 4, from: statement).flatMap(UInt64.init) ?? 0,
            messageID: string(at: 5, from: statement) ?? "",
            fromAddress: string(at: 6, from: statement) ?? "",
            fromDisplayName: string(at: 7, from: statement),
            subject: string(at: 8, from: statement) ?? "",
            plainBody: string(at: 9, from: statement) ?? "",
            receivedAt: date(at: 10, from: statement) ?? Date(),
            inReplyTo: string(at: 11, from: statement),
            references: try decodeJSON([String].self, from: string(at: 12, from: statement)),
            threadToken: string(at: 13, from: statement),
            action: MailroomMailboxMessageAction(rawValue: string(at: 14, from: statement) ?? "") ?? .received,
            outboundMessageID: string(at: 15, from: statement),
            note: string(at: 16, from: statement) ?? "",
            processedAt: date(at: 17, from: statement),
            updatedAt: date(at: 18, from: statement) ?? Date()
        )
    }

    func decodeMailboxAccount(from statement: OpaquePointer?) -> MailboxAccount {
        MailboxAccount(
            id: string(at: 0, from: statement) ?? UUID().uuidString,
            label: string(at: 1, from: statement) ?? "",
            emailAddress: string(at: 2, from: statement) ?? "",
            role: MailboxRole(rawValue: string(at: 3, from: statement) ?? "") ?? .operator,
            workspaceRoot: string(at: 4, from: statement) ?? "",
            imap: MailServerEndpoint(
                host: string(at: 5, from: statement) ?? "",
                port: Int(int64(at: 6, from: statement) ?? 993),
                security: MailTransportSecurity(rawValue: string(at: 7, from: statement) ?? "") ?? .sslTLS
            ),
            smtp: MailServerEndpoint(
                host: string(at: 8, from: statement) ?? "",
                port: Int(int64(at: 9, from: statement) ?? 465),
                security: MailTransportSecurity(rawValue: string(at: 10, from: statement) ?? "") ?? .sslTLS
            ),
            pollingIntervalSeconds: Int(int64(at: 11, from: statement) ?? 60),
            createdAt: date(at: 12, from: statement) ?? Date(),
            updatedAt: date(at: 13, from: statement) ?? Date()
        )
    }

    func decodeSenderPolicy(from statement: OpaquePointer?) throws -> SenderPolicy {
        SenderPolicy(
            id: string(at: 0, from: statement) ?? UUID().uuidString,
            displayName: string(at: 1, from: statement) ?? "",
            senderAddress: string(at: 2, from: statement) ?? "",
            assignedRole: MailboxRole(rawValue: string(at: 3, from: statement) ?? "") ?? .operator,
            allowedWorkspaceRoots: try decodeJSON([String].self, from: string(at: 4, from: statement)),
            requiresReplyToken: (int64(at: 5, from: statement) ?? 0) != 0,
            isEnabled: (int64(at: 6, from: statement) ?? 0) != 0,
            createdAt: date(at: 7, from: statement) ?? Date(),
            updatedAt: date(at: 8, from: statement) ?? Date()
        )
    }

    func decodeManagedProject(from statement: OpaquePointer?) -> ManagedProject {
        ManagedProject(
            id: string(at: 0, from: statement) ?? UUID().uuidString,
            displayName: string(at: 1, from: statement) ?? "",
            slug: string(at: 2, from: statement) ?? "",
            rootPath: string(at: 3, from: statement) ?? "",
            summary: string(at: 4, from: statement) ?? "",
            defaultCapability: MailCapability(rawValue: string(at: 5, from: statement) ?? "") ?? .writeWorkspace,
            isEnabled: (int64(at: 6, from: statement) ?? 0) != 0,
            createdAt: date(at: 7, from: statement) ?? Date(),
            updatedAt: date(at: 8, from: statement) ?? Date()
        )
    }

    func message(from database: OpaquePointer?) -> String {
        guard let database else {
            return "Unknown SQLite error."
        }
        return String(cString: sqlite3_errmsg(database))
    }

    func ensureColumn(
        table: String,
        named name: String,
        definition: String,
        in database: OpaquePointer?
    ) throws {
        guard !existingColumns(in: table, database: database).contains(name) else {
            return
        }
        try execute("ALTER TABLE \(table) ADD COLUMN \(name) \(definition);", in: database)
    }

    func existingColumns(in table: String, database: OpaquePointer?) -> Set<String> {
        var columns: Set<String> = []
        let sql = "PRAGMA table_info(\(table));"
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
}

enum SQLiteMailroomStoreError: LocalizedError, Sendable {
    case openFailed(String)
    case statementFailed(String)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            return "Unable to open the Mailroom SQLite store: \(message)"
        case .statementFailed(let message):
            return "SQLite could not complete the requested Mailroom operation: \(message)"
        case .decodeFailed(let message):
            return "Stored Mailroom data could not be decoded: \(message)"
        }
    }
}
