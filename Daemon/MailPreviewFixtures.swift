import Foundation

struct MailPreviewFixture: Codable, Hashable, Sendable {
    var id: String
    var title: String
    var summary: String
    var recipients: [String]
    var subject: String
    var preview: String
    var plainBody: String
    var htmlBody: String?
}

struct MailPreviewFixtureManifestEntry: Codable, Hashable, Sendable {
    var id: String
    var title: String
    var summary: String
    var recipients: [String]
    var subject: String
    var preview: String
    var plainPath: String
    var htmlPath: String?
}

struct MailPreviewFixtureManifest: Codable, Hashable, Sendable {
    var generatedAt: Date
    var outputDirectory: String
    var indexPath: String
    var manifestPath: String
    var fixtures: [MailPreviewFixtureManifestEntry]
}

enum MailPreviewFixtureWriter {
    static func write(_ fixtures: [MailPreviewFixture], to outputDirectory: URL) throws -> MailPreviewFixtureManifest {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        var entries: [MailPreviewFixtureManifestEntry] = []
        for (index, fixture) in fixtures.enumerated() {
            let baseName = String(format: "%02d-%@", index + 1, fixture.id)
            let plainURL = outputDirectory
                .appendingPathComponent(baseName, isDirectory: false)
                .appendingPathExtension("txt")
            try fixture.plainBody.write(to: plainURL, atomically: true, encoding: .utf8)

            var htmlPath: String?
            if let htmlBody = fixture.htmlBody?.trimmingCharacters(in: .whitespacesAndNewlines), !htmlBody.isEmpty {
                let htmlURL = outputDirectory
                    .appendingPathComponent(baseName, isDirectory: false)
                    .appendingPathExtension("html")
                try htmlBody.write(to: htmlURL, atomically: true, encoding: .utf8)
                htmlPath = htmlURL.lastPathComponent
            }

            entries.append(
                MailPreviewFixtureManifestEntry(
                    id: fixture.id,
                    title: fixture.title,
                    summary: fixture.summary,
                    recipients: fixture.recipients,
                    subject: fixture.subject,
                    preview: fixture.preview,
                    plainPath: plainURL.lastPathComponent,
                    htmlPath: htmlPath
                )
            )
        }

        let generatedAt = Date()
        let indexURL = outputDirectory.appendingPathComponent("index.html", isDirectory: false)
        let manifestURL = outputDirectory.appendingPathComponent("manifest.json", isDirectory: false)
        let manifest = MailPreviewFixtureManifest(
            generatedAt: generatedAt,
            outputDirectory: outputDirectory.path,
            indexPath: indexURL.path,
            manifestPath: manifestURL.path,
            fixtures: entries
        )

        try makeIndexHTML(manifest).write(to: indexURL, atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: Data.WritingOptions.atomic)
        return manifest
    }

    private static func makeIndexHTML(_ manifest: MailPreviewFixtureManifest) -> String {
        let cardsHTML = manifest.fixtures.map { fixture in
            let recipients = fixture.recipients.joined(separator: ", ")
            let htmlLink = fixture.htmlPath.map { path in
                "<a href=\"\(path.htmlEscaped)\" class=\"primary\">Open HTML</a>"
            } ?? ""
            let plainLink = "<a href=\"\(fixture.plainPath.htmlEscaped)\">Open plain text</a>"
            let metaRows = [
                (LT("Recipients", "收件人", "宛先"), recipients),
                (LT("Subject", "主题", "件名"), fixture.subject),
                (LT("Inbox preview", "收件箱预览", "受信トレイのプレビュー"), fixture.preview)
            ]
            .filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { label, value in
                """
                <div class="meta-row">
                  <div class="meta-label">\(label.htmlEscaped)</div>
                  <div class="meta-value">\(value.htmlEscaped)</div>
                </div>
                """
            }
            .joined()

            return """
            <article class="fixture-card">
              <div class="card-header">
                <div>
                  <div class="eyebrow">\(fixture.id.htmlEscaped)</div>
                  <h2>\(fixture.title.htmlEscaped)</h2>
                </div>
                <div class="actions">
                  \(htmlLink)
                  \(plainLink)
                </div>
              </div>
              <p class="summary">\(fixture.summary.htmlEscaped)</p>
              <div class="meta-block">
                \(metaRows)
              </div>
            </article>
            """
        }.joined(separator: "\n")

        let timestamp = ISO8601DateFormatter().string(from: manifest.generatedAt)
        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Patch Courier Email Fixtures</title>
          <style>
            :root {
              color-scheme: light;
              --bg: #f4efe6;
              --panel: rgba(255, 252, 247, 0.92);
              --panel-strong: #ffffff;
              --ink: #1d2430;
              --muted: #697586;
              --line: rgba(29, 36, 48, 0.12);
              --accent: #c26c2b;
              --accent-2: #245fb8;
              --shadow: 0 22px 60px rgba(28, 34, 44, 0.1);
            }
            * { box-sizing: border-box; }
            body {
              margin: 0;
              min-height: 100vh;
              font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
              color: var(--ink);
              background:
                radial-gradient(circle at top left, rgba(194, 108, 43, 0.16), transparent 34%),
                radial-gradient(circle at top right, rgba(36, 95, 184, 0.14), transparent 28%),
                linear-gradient(180deg, #fbf7f1 0%, var(--bg) 100%);
            }
            main {
              max-width: 1120px;
              margin: 0 auto;
              padding: 40px 20px 56px;
            }
            .hero {
              padding: 28px;
              border: 1px solid var(--line);
              border-radius: 28px;
              background: var(--panel);
              backdrop-filter: blur(14px);
              box-shadow: var(--shadow);
            }
            .eyebrow {
              font-size: 12px;
              line-height: 1.4;
              letter-spacing: 0.12em;
              text-transform: uppercase;
              color: var(--muted);
              font-weight: 700;
            }
            h1 {
              margin: 12px 0 0;
              font-size: clamp(34px, 5vw, 56px);
              line-height: 1.02;
              letter-spacing: -0.04em;
            }
            .hero p {
              max-width: 760px;
              margin: 16px 0 0;
              color: #404a59;
              font-size: 17px;
              line-height: 1.75;
            }
            .hero-meta {
              margin-top: 18px;
              color: var(--muted);
              font-size: 14px;
              line-height: 1.7;
            }
            .grid {
              display: grid;
              gap: 18px;
              margin-top: 22px;
            }
            .fixture-card {
              border: 1px solid var(--line);
              border-radius: 24px;
              padding: 22px;
              background: var(--panel-strong);
              box-shadow: 0 12px 28px rgba(28, 34, 44, 0.06);
            }
            .card-header {
              display: flex;
              gap: 16px;
              justify-content: space-between;
              align-items: flex-start;
              flex-wrap: wrap;
            }
            h2 {
              margin: 10px 0 0;
              font-size: 25px;
              line-height: 1.15;
              letter-spacing: -0.03em;
            }
            .summary {
              margin: 14px 0 0;
              color: #485466;
              font-size: 15px;
              line-height: 1.8;
            }
            .actions {
              display: flex;
              gap: 10px;
              flex-wrap: wrap;
            }
            .actions a {
              display: inline-flex;
              align-items: center;
              justify-content: center;
              min-height: 42px;
              padding: 0 14px;
              border-radius: 999px;
              border: 1px solid rgba(36, 95, 184, 0.16);
              color: var(--accent-2);
              text-decoration: none;
              font-size: 14px;
              font-weight: 700;
              background: #eef5ff;
            }
            .actions a.primary {
              border-color: rgba(194, 108, 43, 0.16);
              background: #fff1e6;
              color: var(--accent);
            }
            .meta-block {
              display: grid;
              gap: 10px;
              margin-top: 18px;
              padding-top: 18px;
              border-top: 1px solid rgba(29, 36, 48, 0.08);
            }
            .meta-row {
              display: grid;
              gap: 4px;
            }
            .meta-label {
              font-size: 12px;
              letter-spacing: 0.08em;
              text-transform: uppercase;
              color: var(--muted);
              font-weight: 700;
            }
            .meta-value {
              font-size: 15px;
              line-height: 1.75;
              color: var(--ink);
              word-break: break-word;
            }
            @media (max-width: 720px) {
              main { padding: 24px 14px 40px; }
              .hero, .fixture-card { padding: 18px; border-radius: 22px; }
              h2 { font-size: 22px; }
            }
          </style>
        </head>
        <body>
          <main>
            <section class="hero">
              <div class="eyebrow">Patch Courier</div>
              <h1>Email Preview Fixtures</h1>
              <p>Representative outbound emails rendered from the current Mailroom templates. Open the HTML version to inspect mailbox styling, or the plain-text version to check fallback readability.</p>
              <div class="hero-meta">Generated at \(timestamp.htmlEscaped)<br>Output directory: \(manifest.outputDirectory.htmlEscaped)</div>
            </section>
            <section class="grid">
              \(cardsHTML)
            </section>
          </main>
        </body>
        </html>
        """
    }
}

private extension String {
    var htmlEscaped: String {
        self
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
