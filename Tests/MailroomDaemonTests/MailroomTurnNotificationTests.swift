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

    private func makeDaemon(
        turnStore: TurnStore,
        approvalStore: ApprovalStore
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

        return MailroomDaemon(
            configuration: configuration,
            threadStore: InMemoryThreadStore(),
            turnStore: turnStore,
            approvalStore: approvalStore,
            eventStore: InMemoryEventStore(),
            syncStore: InMemoryMailboxSyncStore(),
            mailboxMessageStore: InMemoryMailboxMessageStore(),
            accountStore: InMemoryMailboxAccountConfigStore(),
            senderPolicyStore: InMemorySenderPolicyConfigStore(),
            managedProjectStore: InMemoryManagedProjectConfigStore()
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
}
