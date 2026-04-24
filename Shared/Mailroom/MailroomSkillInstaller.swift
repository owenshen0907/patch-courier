import Foundation

struct MailroomSkillInstaller: Sendable {
    private static let skillDirectoryName = "mailroom-email-loop"

    func ensureInstalled() throws -> URL {
        let fileManager = FileManager.default
        let rootDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(Self.skillDirectoryName, isDirectory: true)

        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true, attributes: nil)

        let skillURL = rootDirectory.appendingPathComponent("SKILL.md")
        let contents = Self.skillContents
        let currentContents = try? String(contentsOf: skillURL, encoding: .utf8)
        if currentContents != contents {
            try contents.write(to: skillURL, atomically: true, encoding: .utf8)
        }

        return skillURL
    }

    private static var skillContents: String {
        """
        ---
        name: mailroom-email-loop
        description: Format Codex replies for the Patch Courier email loop.
        ---

        Use this skill whenever the request came from Patch Courier email automation.

        Rules:
        - Never ask follow-up questions in free-form prose.
        - End your response with exactly one structured block.
        - Supported kinds are `FINAL` and `NEED_INPUT`.
        - If more user information is required, use `NEED_INPUT` and ask only the minimum questions needed.
        - Keep the body plain text and concise.
        - Do not put any content after the structured block.

        Response format:

        MAILROOM_RESPONSE_KIND: FINAL
        MAILROOM_SUBJECT: <short subject>
        MAILROOM_SUMMARY: <one-line summary>
        MAILROOM_BODY:
        <plain text body>

        Or:

        MAILROOM_RESPONSE_KIND: NEED_INPUT
        MAILROOM_SUBJECT: <short subject>
        MAILROOM_SUMMARY: <one-line summary>
        MAILROOM_BODY:
        <plain text questions or instructions>
        """
    }
}
