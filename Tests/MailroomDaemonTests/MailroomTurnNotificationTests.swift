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

    private func makeDaemon(
        threadStore: ThreadStore = InMemoryThreadStore(),
        turnStore: TurnStore,
        approvalStore: ApprovalStore,
        eventStore: EventStore = InMemoryEventStore(),
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
            mailboxMessageStore: InMemoryMailboxMessageStore(),
            accountStore: InMemoryMailboxAccountConfigStore(),
            senderPolicyStore: InMemorySenderPolicyConfigStore(),
            managedProjectStore: InMemoryManagedProjectConfigStore()
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
