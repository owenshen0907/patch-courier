import Foundation
import XCTest

final class MailPreviewFixtureTests: XCTestCase {
    func testRenderMailPreviewFixturesWritesManifestIndexAndCoreFiles() async throws {
        let outputDirectory = makeTemporaryDirectory()
        let supportRoot = makeTemporaryDirectory(prefix: "PatchCourierFixtureSupport")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        defer { try? FileManager.default.removeItem(at: supportRoot) }

        let manifest = try await makeDaemon(supportRoot: supportRoot).renderMailPreviewFixtures(outputDirectory: outputDirectory)
        let fixtureIDs = Set(manifest.fixtures.map(\.id))
        let requiredFixtureIDs: Set<String> = [
            "daemon-received-task-starting",
            "daemon-managed-project-selection",
            "daemon-approval-request",
            "daemon-completed-result",
            "daemon-failed-result",
            "daemon-recorded-only"
        ]

        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.indexPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.manifestPath))
        XCTAssertTrue(requiredFixtureIDs.isSubset(of: fixtureIDs))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifestData = try Data(contentsOf: URL(fileURLWithPath: manifest.manifestPath))
        let persistedManifest = try decoder.decode(MailPreviewFixtureManifest.self, from: manifestData)
        XCTAssertEqual(persistedManifest.fixtures.map(\.id), manifest.fixtures.map(\.id))

        for entry in manifest.fixtures where requiredFixtureIDs.contains(entry.id) {
            let plainURL = outputDirectory.appendingPathComponent(entry.plainPath, isDirectory: false)
            XCTAssertTrue(FileManager.default.fileExists(atPath: plainURL.path), entry.id)
            let plainBody = try String(contentsOf: plainURL, encoding: .utf8)
            XCTAssertFalse(plainBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, entry.id)

            let htmlPath = try XCTUnwrap(entry.htmlPath, entry.id)
            let htmlURL = outputDirectory.appendingPathComponent(htmlPath, isDirectory: false)
            XCTAssertTrue(FileManager.default.fileExists(atPath: htmlURL.path), entry.id)
            let htmlBody = try String(contentsOf: htmlURL, encoding: .utf8)
            XCTAssertTrue(htmlBody.contains(MailroomEmailHTML.contentMarker), entry.id)
        }
    }

    func testRenderMailPreviewFixturesCoverCriticalMailboxFlows() async throws {
        let outputDirectory = makeTemporaryDirectory()
        let supportRoot = makeTemporaryDirectory(prefix: "PatchCourierFixtureSupport")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        defer { try? FileManager.default.removeItem(at: supportRoot) }

        let manifest = try await makeDaemon(supportRoot: supportRoot).renderMailPreviewFixtures(outputDirectory: outputDirectory)
        let entriesByID = Dictionary(uniqueKeysWithValues: manifest.fixtures.map { ($0.id, $0) })

        try assertFixture(
            id: "daemon-received-task-starting",
            in: entriesByID,
            outputDirectory: outputDirectory,
            plainTokens: [
                "MRM-PREVIEW-RECEIVED",
                "Please investigate the login timeout regression in the dashboard.",
                "Codex"
            ]
        )
        try assertFixture(
            id: "daemon-managed-project-selection",
            in: entriesByID,
            outputDirectory: outputDirectory,
            plainTokens: [
                "MRM-PREVIEW-PROJECT",
                "Mailroom Dashboard [mailroom-dashboard]",
                "PROJECT: mailroom-dashboard",
                "COMMAND:"
            ],
            htmlTokens: ["mailto:"]
        )
        try assertFixture(
            id: "daemon-approval-request",
            in: entriesByID,
            outputDirectory: outputDirectory,
            plainTokens: [
                "MRM-PREVIEW-APPROVAL",
                "REQUEST: APR-PREVIEW-001",
                "DECISION: <approve | reject>"
            ],
            htmlTokens: ["mailto:"]
        )
        try assertFixture(
            id: "daemon-completed-result",
            in: entriesByID,
            outputDirectory: outputDirectory,
            plainTokens: [
                "MRM-PREVIEW-DONE",
                "Root cause:",
                "What changed:",
                "Risk notes:"
            ]
        )
        try assertFixture(
            id: "daemon-failed-result",
            in: entriesByID,
            outputDirectory: outputDirectory,
            plainTokens: [
                "MRM-PREVIEW-FAILED",
                "Blocking detail:",
                "Suggested recovery:"
            ]
        )
        try assertFixture(
            id: "daemon-recorded-only",
            in: entriesByID,
            outputDirectory: outputDirectory,
            plainTokens: [
                "MRM-PREVIEW-RECORDED",
                "MODE: START_TASK",
                "TASK: <optional replacement task>"
            ],
            htmlTokens: ["mailto:"]
        )
    }

    private func assertFixture(
        id: String,
        in entriesByID: [String: MailPreviewFixtureManifestEntry],
        outputDirectory: URL,
        plainTokens: [String],
        htmlTokens: [String] = []
    ) throws {
        let entry = try XCTUnwrap(entriesByID[id], id)
        XCTAssertFalse(entry.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id)
        XCTAssertFalse(entry.preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id)

        let plainURL = outputDirectory.appendingPathComponent(entry.plainPath, isDirectory: false)
        let plainBody = try String(contentsOf: plainURL, encoding: .utf8)
        for token in plainTokens {
            XCTAssertTrue(plainBody.contains(token), "\(id) missing plain token: \(token)")
        }

        let htmlPath = try XCTUnwrap(entry.htmlPath, id)
        let htmlURL = outputDirectory.appendingPathComponent(htmlPath, isDirectory: false)
        let htmlBody = try String(contentsOf: htmlURL, encoding: .utf8)
        XCTAssertTrue(htmlBody.contains(MailroomEmailHTML.contentMarker), id)
        for token in htmlTokens {
            XCTAssertTrue(htmlBody.contains(token), "\(id) missing HTML token: \(token)")
        }
    }

    private func makeDaemon(supportRoot: URL) -> MailroomDaemon {
        var configuration = MailroomDaemonConfiguration.default()
        configuration.supportRoot = supportRoot.path
        configuration.databasePath = supportRoot.appendingPathComponent("mailroom.sqlite3").path
        configuration.codexHome = supportRoot.appendingPathComponent("CodexHome", isDirectory: true).path
        configuration.bootstrapSourceHome = nil
        configuration.mailboxAccountsPath = supportRoot.appendingPathComponent("mailbox-accounts.json").path
        configuration.senderPoliciesPath = supportRoot.appendingPathComponent("sender-policies.json").path
        configuration.mailTransportScriptPath = supportRoot.appendingPathComponent("mail_transport.py").path
        configuration.defaultWorkspaceRoot = supportRoot.appendingPathComponent("Workspace", isDirectory: true).path

        return MailroomDaemon(
            configuration: configuration,
            threadStore: InMemoryThreadStore(),
            turnStore: InMemoryTurnStore(),
            approvalStore: InMemoryApprovalStore(),
            eventStore: InMemoryEventStore(),
            syncStore: InMemoryMailboxSyncStore(),
            mailboxMessageStore: InMemoryMailboxMessageStore(),
            pollIncidentStore: InMemoryMailboxPollIncidentStore(),
            accountStore: InMemoryMailboxAccountConfigStore(),
            senderPolicyStore: InMemorySenderPolicyConfigStore(),
            managedProjectStore: InMemoryManagedProjectConfigStore()
        )
    }

    private func makeTemporaryDirectory(prefix: String = "PatchCourierFixtureTests") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }
}
