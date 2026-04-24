import Foundation

actor InMemoryThreadStore: ThreadStore {
    private var threadsByToken: [String: MailroomThreadRecord] = [:]
    private var tokensByCodexThreadID: [String: String] = [:]

    func save(thread: MailroomThreadRecord) async throws {
        threadsByToken[thread.id] = thread
        if let codexThreadID = thread.codexThreadID {
            tokensByCodexThreadID[codexThreadID] = thread.id
        }
    }

    func thread(token: String) async throws -> MailroomThreadRecord? {
        threadsByToken[token]
    }

    func thread(codexThreadID: String) async throws -> MailroomThreadRecord? {
        guard let token = tokensByCodexThreadID[codexThreadID] else { return nil }
        return threadsByToken[token]
    }

    func allThreads() async throws -> [MailroomThreadRecord] {
        threadsByToken.values.sorted { $0.updatedAt < $1.updatedAt }
    }
}

actor InMemoryApprovalStore: ApprovalStore {
    private var approvals: [String: MailroomApprovalRequest] = [:]

    func save(approval: MailroomApprovalRequest) async throws {
        approvals[approval.id] = approval
    }

    func approval(id: String) async throws -> MailroomApprovalRequest? {
        approvals[id]
    }

    func allApprovals() async throws -> [MailroomApprovalRequest] {
        approvals.values.sorted { $0.createdAt < $1.createdAt }
    }
}

actor InMemoryEventStore: EventStore {
    private var events: [MailroomEventRecord] = []

    func append(event: MailroomEventRecord) async throws {
        events.append(event)
    }

    func allEvents() async throws -> [MailroomEventRecord] {
        events
    }
}

actor InMemoryMailboxSyncStore: MailboxSyncStore {
    private var cursors: [String: MailroomMailboxSyncCursor] = [:]

    func save(syncCursor: MailroomMailboxSyncCursor) async throws {
        cursors[syncCursor.accountID] = syncCursor
    }

    func syncCursor(accountID: String) async throws -> MailroomMailboxSyncCursor? {
        cursors[accountID]
    }

    func allSyncCursors() async throws -> [MailroomMailboxSyncCursor] {
        cursors.values.sorted { lhs, rhs in
            lhs.accountID.localizedCaseInsensitiveCompare(rhs.accountID) == .orderedAscending
        }
    }
}

actor InMemoryMailboxMessageStore: MailboxMessageStore {
    private var messagesByID: [String: MailroomMailboxMessageRecord] = [:]

    func save(mailboxMessage: MailroomMailboxMessageRecord) async throws {
        messagesByID[mailboxMessage.id] = mailboxMessage
    }

    func recentMailboxMessages(limit: Int, mailboxID: String?) async throws -> [MailroomMailboxMessageRecord] {
        let filtered = messagesByID.values
            .filter { record in
                mailboxID.map { record.mailboxID == $0 } ?? true
            }
            .sorted { lhs, rhs in
                if lhs.receivedAt != rhs.receivedAt {
                    return lhs.receivedAt > rhs.receivedAt
                }
                return lhs.updatedAt > rhs.updatedAt
            }
        return Array(filtered.prefix(max(limit, 0)))
    }
}

actor InMemoryTurnStore: TurnStore {
    private var turns: [String: MailroomTurnRecord] = [:]

    func save(turn: MailroomTurnRecord) async throws {
        turns[turn.id] = turn
    }

    func turn(id: String) async throws -> MailroomTurnRecord? {
        turns[id]
    }

    func allTurns() async throws -> [MailroomTurnRecord] {
        turns.values.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
        }
    }
}

actor InMemoryMailboxAccountConfigStore: MailboxAccountConfigStore {
    private var accounts: [String: MailboxAccount] = [:]

    func allMailboxAccounts() async throws -> [MailboxAccount] {
        accounts.values.sorted { lhs, rhs in
            lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
    }

    func upsertMailboxAccount(_ account: MailboxAccount) async throws {
        accounts[account.id] = account
    }

    func deleteMailboxAccount(accountID: String) async throws {
        accounts.removeValue(forKey: accountID)
    }
}

actor InMemorySenderPolicyConfigStore: SenderPolicyConfigStore {
    private var policies: [String: SenderPolicy] = [:]

    func allSenderPolicies() async throws -> [SenderPolicy] {
        policies.values.sorted { lhs, rhs in
            lhs.senderAddress.localizedCaseInsensitiveCompare(rhs.senderAddress) == .orderedAscending
        }
    }

    func upsertSenderPolicy(_ policy: SenderPolicy) async throws {
        policies[policy.id] = policy
    }

    func deleteSenderPolicy(policyID: String) async throws {
        policies.removeValue(forKey: policyID)
    }
}

actor InMemoryManagedProjectConfigStore: ManagedProjectConfigStore {
    private var projects: [String: ManagedProject] = [:]

    func allManagedProjects() async throws -> [ManagedProject] {
        projects.values.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    func upsertManagedProject(_ project: ManagedProject) async throws {
        projects[project.id] = project
    }

    func deleteManagedProject(projectID: String) async throws {
        projects.removeValue(forKey: projectID)
    }
}
