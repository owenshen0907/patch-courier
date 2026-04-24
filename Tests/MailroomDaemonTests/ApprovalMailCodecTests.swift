import Foundation
import XCTest

final class ApprovalMailCodecTests: XCTestCase {
    func testApprovalReplyParserParsesMultilineAnswersAndNote() throws {
        let body = """
        REQUEST: APR-123
        DECISION: approve
        ANSWER_environment: production
        ANSWER_version:
        1.2.3
        build 45

        NOTE:
        Take the database snapshot first.
        Then continue.
        """

        let parsed = try XCTUnwrap(ApprovalReplyParser.parse(body))
        XCTAssertEqual(parsed.requestID, "APR-123")
        XCTAssertEqual(parsed.decision, "approve")
        XCTAssertEqual(parsed.answers["environment"], ["production"])
        XCTAssertEqual(parsed.answers["version"], ["1.2.3", "build 45"])
        XCTAssertEqual(parsed.note, "Take the database snapshot first.\nThen continue.")
    }

    func testApprovalComposerIncludesPreparedUserInputReplyTemplate() throws {
        let request = MailroomApprovalRequest(
            id: "APR-456",
            rpcRequestID: .string("rpc-1"),
            kind: .userInput,
            mailThreadToken: "MRM-4567",
            codexThreadID: "thread-1",
            codexTurnID: "turn-1",
            itemID: "item-1",
            summary: "Need deployment parameters",
            detail: "Please confirm the target environment and build number.",
            availableDecisions: [],
            rawPayload: .object([
                "questions": .array([
                    .object([
                        "id": .string("environment"),
                        "header": .string("Environment")
                    ]),
                    .object([
                        "id": .string("build"),
                        "header": .string("Build")
                    ])
                ])
            ]),
            status: .pending,
            resolvedDecision: nil,
            resolutionNote: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            resolvedAt: nil
        )

        let envelope = ApprovalMailComposer.compose(
            request: request,
            recipient: "ops@example.com",
            replyAddress: "mailroom@example.com",
            subject: "Reply needed"
        )

        XCTAssertEqual(envelope.to, ["ops@example.com"])
        XCTAssertTrue(envelope.plainBody.contains("REQUEST: APR-456"))
        XCTAssertTrue(envelope.plainBody.contains("ANSWER_environment: <Environment>"))
        XCTAssertTrue(envelope.plainBody.contains("ANSWER_build: <Build>"))

        let htmlBody = try XCTUnwrap(envelope.htmlBody)
        XCTAssertTrue(htmlBody.contains(MailroomEmailHTML.contentMarker))
        XCTAssertTrue(htmlBody.contains("Need deployment parameters"))
        XCTAssertTrue(htmlBody.contains("mailto:"))
        XCTAssertTrue(htmlBody.contains("ANSWER_environment"))
    }

    func testMailroomEmailHTMLDocumentEscapesPreheader() {
        let document = MailroomEmailHTML.document(
            preheader: "<Review & Ship>",
            bodyHTML: "<p>Hello</p>"
        )

        XCTAssertTrue(document.contains("&lt;Review &amp; Ship&gt;"))
        XCTAssertFalse(document.contains("<Review & Ship>"))
        XCTAssertTrue(document.contains("<p>Hello</p>"))
    }
}
