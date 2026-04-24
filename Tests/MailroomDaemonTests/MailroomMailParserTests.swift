import Foundation
import XCTest

final class MailroomMailParserTests: XCTestCase {
    func testThreadConfirmationReplyParserIgnoresQuotedHistory() throws {
        let body = """
        模式：开始任务
        任务：检查最新构建

        如果失败，给我原因。
        On Tue, Apr 23, 2026 at 9:00 AM Mailroom wrote:
        > Previous reply content
        """

        let parsed = try XCTUnwrap(ThreadConfirmationReplyParser.parse(body))
        XCTAssertEqual(parsed.decision, .startTask)
        XCTAssertEqual(parsed.customPrompt, "检查最新构建\n\n如果失败，给我原因。")
    }

    func testParseCommandUsesStructuredHeadersAndSubjectToken() {
        let message = InboundMailMessage(
            uid: 42,
            messageID: "message-1",
            fromAddress: "ops@example.com",
            fromDisplayName: "Ops",
            subject: "Re: [Patch Courier Done] [patch-courier:mrm-1234] Repo check",
            plainBody: """
            WORKSPACE: /tmp/project
            CAPABILITY: shell
            ACTION: Inspect failing tests

            Please inspect the latest failing test logs.

            > quoted history
            """,
            receivedAt: Date(timeIntervalSince1970: 0),
            inReplyTo: nil,
            references: []
        )

        let parsed = MailroomMailParser.parseCommand(
            from: message,
            fallbackWorkspaceRoot: "/fallback"
        )

        XCTAssertEqual(parsed.cleanedSubject, "Repo check")
        XCTAssertEqual(parsed.workspaceRoot, "/tmp/project")
        XCTAssertEqual(parsed.capability, .executeShell)
        XCTAssertEqual(parsed.actionSummary, "Inspect failing tests")
        XCTAssertEqual(parsed.promptBody, "Inspect failing tests")
        XCTAssertEqual(parsed.detectedToken, "MRM-1234")
    }

    func testParseCommandAcceptsLegacyMailroomToken() {
        let message = InboundMailMessage(
            uid: 43,
            messageID: "message-2",
            fromAddress: "ops@example.com",
            fromDisplayName: "Ops",
            subject: "Re: [mailroom done] [codex-mailroom:mrm-5678] Repo check",
            plainBody: "ACTION: Continue",
            receivedAt: Date(timeIntervalSince1970: 0),
            inReplyTo: nil,
            references: []
        )

        let parsed = MailroomMailParser.parseCommand(
            from: message,
            fallbackWorkspaceRoot: "/fallback"
        )

        XCTAssertEqual(parsed.cleanedSubject, "Repo check")
        XCTAssertEqual(parsed.detectedToken, "MRM-5678")
    }
}
