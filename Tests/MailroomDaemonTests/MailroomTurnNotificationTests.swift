import Foundation
import XCTest

final class MailroomTurnNotificationTests: XCTestCase {
    func testPendingApprovalNotificationIdentitySuppressesDuplicateReminder() async throws {
        let turnStore = InMemoryTurnStore()
        let approvalStore = InMemoryApprovalStore()
        let daemon = makeDaemon(turnStore: turnStore, approvalStore: approvalStore)
        let turn = makeTurn(
            status: .waitingOnApproval,
            lastNotifiedState: .waitingOnApproval,
            lastNotifiedApprovalID: "APR-1"
        )
        let approval = makeApproval(id: "APR-1")

        try await turnStore.save(turn: turn)

        let alreadyNotified = try await daemon.pendingApprovalAlreadyNotified(approval)
        XCTAssertTrue(alreadyNotified)
    }

    func testRecoveryDetectsNewApprovalWithSameWaitingState() async throws {
        let turnStore = InMemoryTurnStore()
        let approvalStore = InMemoryApprovalStore()
        let daemon = makeDaemon(turnStore: turnStore, approvalStore: approvalStore)
        let turn = makeTurn(
            status: .waitingOnApproval,
            lastNotifiedState: .waitingOnApproval,
            lastNotifiedApprovalID: "APR-1"
        )
        let newApproval = makeApproval(id: "APR-2", createdAt: Date(timeIntervalSince1970: 2))

        try await turnStore.save(turn: turn)
        try await approvalStore.save(approval: newApproval)

        let needsRecovery = try await daemon.shouldRecoverMailTurn(turn)
        XCTAssertTrue(needsRecovery)

        try await daemon.markTurnNotification(
            turnID: turn.id,
            state: .waitingOnApproval,
            messageID: "message-2",
            approvalID: newApproval.id
        )
        guard let refreshedTurn = try await turnStore.turn(id: turn.id) else {
            return XCTFail("Expected saved turn")
        }

        let stillNeedsRecovery = try await daemon.shouldRecoverMailTurn(refreshedTurn)
        XCTAssertFalse(stillNeedsRecovery)
    }

    func testTransitionToActiveClearsWaitingNotificationIdentity() async throws {
        let turnStore = InMemoryTurnStore()
        let daemon = makeDaemon(turnStore: turnStore, approvalStore: InMemoryApprovalStore())
        let turn = makeTurn(
            status: .waitingOnApproval,
            lastNotifiedState: .waitingOnApproval,
            lastNotifiedApprovalID: nil
        )

        try await turnStore.save(turn: turn)
        try await daemon.transitionTurn(id: turn.id, status: .active)

        guard let activeTurn = try await turnStore.turn(id: turn.id) else {
            return XCTFail("Expected active turn")
        }
        XCTAssertNil(activeTurn.lastNotifiedState)
        XCTAssertNil(activeTurn.lastNotifiedApprovalID)
        XCTAssertNil(activeTurn.lastNotificationMessageID)
    }

    func testPersistOutcomeTransitionsMailThreadAfterRecoveryPoll() async throws {
        let threadStore = InMemoryThreadStore()
        let turnStore = InMemoryTurnStore()
        let daemon = makeDaemon(
            threadStore: threadStore,
            turnStore: turnStore,
            approvalStore: InMemoryApprovalStore()
        )
        let thread = makeThread(status: .active)
        let turn = makeTurn(status: .active, lastNotifiedState: nil, lastNotifiedApprovalID: nil)
        let outcome = makeOutcome(state: .completed)

        try await threadStore.save(thread: thread)
        try await turnStore.save(turn: turn)
        try await daemon.persistOutcome(outcome)

        guard let persistedTurn = try await turnStore.turn(id: turn.id),
              let persistedThread = try await threadStore.thread(token: thread.id) else {
            return XCTFail("Expected persisted turn and thread")
        }
        XCTAssertEqual(persistedTurn.status, .completed)
        XCTAssertEqual(persistedThread.status, .completed)
    }

    func testRecoveredTurnTimeoutMarksSystemErrorAndRecordsEvent() async throws {
        let threadStore = InMemoryThreadStore()
        let turnStore = InMemoryTurnStore()
        let eventStore = InMemoryEventStore()
        let daemon = makeDaemon(
            threadStore: threadStore,
            turnStore: turnStore,
            approvalStore: InMemoryApprovalStore(),
            eventStore: eventStore
        ) { configuration in
            configuration.activeTurnRecoveryTimeoutSeconds = 60
        }
        let thread = makeThread(status: .active)
        let turn = makeTurn(status: .active, lastNotifiedState: nil, lastNotifiedApprovalID: nil)

        try await threadStore.save(thread: thread)
        try await turnStore.save(turn: turn)
        let outcome = try await daemon.markRecoveredTurnTimedOut(
            turn,
            now: Date(timeIntervalSince1970: 120)
        )

        guard let persistedTurn = try await turnStore.turn(id: turn.id),
              let persistedThread = try await threadStore.thread(token: thread.id) else {
            return XCTFail("Expected persisted turn and thread")
        }
        let events = try await eventStore.allEvents()
        XCTAssertEqual(outcome.state, .systemError)
        XCTAssertEqual(persistedTurn.status, .systemError)
        XCTAssertEqual(persistedThread.status, .failed)
        XCTAssertEqual(events.first?.method, "turn/recovery/timeout")
    }

    func testMailboxReplaySkipsPersistedProcessedMessage() async throws {
        let mailboxMessageStore = InMemoryMailboxMessageStore()
        let daemon = makeDaemon(
            turnStore: InMemoryTurnStore(),
            approvalStore: InMemoryApprovalStore(),
            mailboxMessageStore: mailboxMessageStore
        )
        let account = makeMailboxAccount()
        let message = makeInboundMessage()
        let record = makeMailboxMessageRecord(
            account: account,
            message: message,
            action: .completed,
            processedAt: Date(timeIntervalSince1970: 30)
        )

        try await mailboxMessageStore.save(mailboxMessage: record)

        let decision = try await daemon.mailboxReplayDecision(account: account, message: message)
        switch decision {
        case .process:
            XCTFail("Expected replayed processed message to be skipped")
        case .skip(let result):
            XCTAssertEqual(result.uid, message.uid)
            XCTAssertEqual(result.messageID, message.messageID)
            XCTAssertEqual(result.action, .completed)
            XCTAssertEqual(result.threadToken, "MRM-1")
            XCTAssertEqual(result.outboundMessageID, "outbound-1")
        }
    }

    func testMailboxReplayProcessesUnfinishedReceivedMessage() async throws {
        let mailboxMessageStore = InMemoryMailboxMessageStore()
        let daemon = makeDaemon(
            turnStore: InMemoryTurnStore(),
            approvalStore: InMemoryApprovalStore(),
            mailboxMessageStore: mailboxMessageStore
        )
        let account = makeMailboxAccount()
        let message = makeInboundMessage()
        let record = makeMailboxMessageRecord(
            account: account,
            message: message,
            action: .received,
            processedAt: nil
        )

        try await mailboxMessageStore.save(mailboxMessage: record)

        let decision = try await daemon.mailboxReplayDecision(account: account, message: message)
        XCTAssertEqual(decision, .process)
    }

    private func makeDaemon(
        threadStore: ThreadStore = InMemoryThreadStore(),
        turnStore: TurnStore,
        approvalStore: ApprovalStore,
        eventStore: EventStore = InMemoryEventStore(),
        mailboxMessageStore: MailboxMessageStore = InMemoryMailboxMessageStore(),
        configure: (inout MailroomDaemonConfiguration) -> Void = { _ in }
    ) -> MailroomDaemon {
        var configuration = MailroomDaemonConfiguration.default()
        let supportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PatchCourierTests-\(UUID().uuidString)", isDirectory: true)
        configuration.supportRoot = supportRoot.path
        configuration.databasePath = supportRoot.appendingPathComponent("mailroom.sqlite3").path
        configuration.codexHome = supportRoot.appendingPathComponent("CodexHome", isDirectory: true).path
        configuration.bootstrapSourceHome = nil
        configuration.mailboxAccountsPath = supportRoot.appendingPathComponent("mailbox-accounts.json").path
        configuration.senderPoliciesPath = supportRoot.appendingPathComponent("sender-policies.json").path
        configuration.mailTransportScriptPath = supportRoot.appendingPathComponent("mail_transport.py").path
        configure(&configuration)

        return MailroomDaemon(
            configuration: configuration,
            threadStore: threadStore,
            turnStore: turnStore,
            approvalStore: approvalStore,
            eventStore: eventStore,
            syncStore: InMemoryMailboxSyncStore(),
            mailboxMessageStore: mailboxMessageStore,
            accountStore: InMemoryMailboxAccountConfigStore(),
            senderPolicyStore: InMemorySenderPolicyConfigStore(),
            managedProjectStore: InMemoryManagedProjectConfigStore()
        )
    }

    private func makeMailboxAccount() -> MailboxAccount {
        MailboxAccount(
            id: "mailbox-1",
            label: "Operator",
            emailAddress: "operator@example.com",
            role: .operator,
            workspaceRoot: "/tmp/project",
            imap: MailServerEndpoint(host: "imap.example.com", port: 993, security: .sslTLS),
            smtp: MailServerEndpoint(host: "smtp.example.com", port: 465, security: .sslTLS),
            pollingIntervalSeconds: 60,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func makeInboundMessage() -> InboundMailMessage {
        InboundMailMessage(
            uid: 42,
            messageID: "message-42",
            fromAddress: "ops@example.com",
            fromDisplayName: "Ops",
            subject: "Ship",
            plainBody: "Continue",
            receivedAt: Date(timeIntervalSince1970: 10),
            inReplyTo: nil,
            references: []
        )
    }

    private func makeMailboxMessageRecord(
        account: MailboxAccount,
        message: InboundMailMessage,
        action: MailroomMailboxMessageAction,
        processedAt: Date?
    ) -> MailroomMailboxMessageRecord {
        MailroomMailboxMessageRecord(
            id: MailroomMailboxMessageRecord.makeID(mailboxID: account.id, uid: message.uid),
            mailboxID: account.id,
            mailboxLabel: account.label,
            mailboxEmailAddress: account.emailAddress,
            uid: message.uid,
            messageID: message.messageID,
            fromAddress: message.fromAddress,
            fromDisplayName: message.fromDisplayName,
            subject: message.subject,
            plainBody: message.plainBody,
            receivedAt: message.receivedAt,
            inReplyTo: message.inReplyTo,
            references: message.references,
            threadToken: "MRM-1",
            action: action,
            outboundMessageID: action == .received ? nil : "outbound-1",
            note: "Processed once.",
            processedAt: processedAt,
            updatedAt: Date(timeIntervalSince1970: 40)
        )
    }

    private func makeThread(status: MailroomThreadStatus) -> MailroomThreadRecord {
        MailroomThreadRecord(
            id: "MRM-1",
            mailboxID: "mailbox-1",
            normalizedSender: "ops@example.com",
            subject: "Deploy",
            codexThreadID: "thread-1",
            workspaceRoot: "/tmp/project",
            capability: .writeWorkspace,
            status: status,
            pendingStage: nil,
            pendingPromptBody: nil,
            managedProjectID: nil,
            lastInboundMessageID: nil,
            lastOutboundMessageID: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func makeTurn(
        status: MailroomTurnStatus,
        lastNotifiedState: MailroomTurnOutcomeState?,
        lastNotifiedApprovalID: String?
    ) -> MailroomTurnRecord {
        MailroomTurnRecord(
            id: "turn-1",
            mailThreadToken: "MRM-1",
            codexThreadID: "thread-1",
            origin: .reply,
            status: status,
            promptPreview: "Deploy",
            lastNotifiedState: lastNotifiedState,
            lastNotifiedApprovalID: lastNotifiedApprovalID,
            lastNotificationMessageID: "message-1",
            startedAt: Date(timeIntervalSince1970: 0),
            completedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func makeApproval(
        id: String,
        createdAt: Date = Date(timeIntervalSince1970: 1)
    ) -> MailroomApprovalRequest {
        MailroomApprovalRequest(
            id: id,
            rpcRequestID: .string("rpc-\(id)"),
            kind: .commandExecution,
            mailThreadToken: "MRM-1",
            codexThreadID: "thread-1",
            codexTurnID: "turn-1",
            itemID: "item-1",
            summary: "Run command",
            detail: "Allow shell command",
            availableDecisions: ["approve", "deny"],
            rawPayload: .object([:]),
            status: .pending,
            resolvedDecision: nil,
            resolutionNote: nil,
            createdAt: createdAt,
            resolvedAt: nil
        )
    }

    private func makeOutcome(state: MailroomTurnOutcomeState) -> MailroomTurnOutcome {
        MailroomTurnOutcome(
            state: state,
            mailThreadToken: "MRM-1",
            codexThreadID: "thread-1",
            turnID: "turn-1",
            finalAnswer: "Done",
            approvalID: nil,
            approvalKind: nil,
            approvalSummary: nil,
            turnStatus: nil,
            threadStatus: nil,
            turnError: nil
        )
    }
}
