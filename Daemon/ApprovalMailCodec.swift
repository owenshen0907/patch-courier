import Foundation

private let approvalBlockSpacingHTML = """
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%; border-collapse:collapse;">
  <tr>
    <td style="height:16px; line-height:16px; font-size:16px;">&nbsp;</td>
  </tr>
</table>
"""

enum ApprovalMailComposer {
    static func compose(
        request: MailroomApprovalRequest,
        recipient: String,
        replyAddress: String,
        subject: String
    ) -> OutboundMailEnvelope {
        let threadLabel = request.mailThreadToken.map { "[patch-courier:\($0)]" } ?? "[codex-thread:\(request.codexThreadID)]"
        var answerLines: [String] = []

        if request.availableDecisions.isEmpty,
           request.kind == .userInput,
                  let fields = request.rawPayload.objectValue,
                  case .array(let rawQuestions)? = fields["questions"] {
            answerLines = rawQuestions.compactMap { question -> String? in
                guard let questionFields = question.objectValue else { return nil }
                let id = questionFields["id"]?.stringValue ?? "question"
                let header = questionFields["header"]?.stringValue ?? id
                return "ANSWER_\(id): <\(header)>"
            }
        }

        let waitingSummary = LT(
            "This work is paused until you reply using the format below.",
            "这项工作已暂停，等待你按下面格式回复。",
            "この作業は一時停止中で、以下の形式での返信を待っています。"
        )
        let replyTemplateLines = approvalReplyTemplateLines(
            request: request,
            threadLabel: threadLabel,
            answerLines: answerLines
        )
        let replyTemplateText = replyTemplateLines.joined(separator: "\n")
        let nextSteps = approvalNextSteps(request: request, answerLines: answerLines)
        let footerText = approvalFooterText(hasQuickReply: !request.availableDecisions.isEmpty || !answerLines.isEmpty)
        let previewText = approvalInboxPreviewText(request: request, answerLines: answerLines)
        let replyBodyText = approvalPlainBody(
            request: request,
            threadLabel: threadLabel,
            waitingSummary: waitingSummary,
            nextSteps: nextSteps,
            replyTemplateText: replyTemplateText,
            footerText: footerText
        )
        let detailHTML = request.detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? approvalSectionHTML(
                title: LT("Details", "详情", "詳細"),
                bodyHTML: approvalParagraphHTML(request.detail ?? "")
            )
            : ""
        let replyInstructionsHTML = approvalManualReplyHTML(
            title: LT("Manual reply", "手动回复", "手動返信"),
            intro: approvalManualReplyIntro(request: request, answerLines: answerLines),
            template: replyTemplateText
        )
        let quickReplyHTML = approvalQuickReplyHTML(
            request: request,
            threadLabel: threadLabel,
            replyAddress: replyAddress,
            subject: subject,
            answerLines: answerLines
        )
        let nextStepsHTML = approvalNextStepsHTML(nextSteps)
        let footerHTML = approvalFooterHTML(footerText)
        let htmlBody = MailroomEmailHTML.document(
            preheader: MailroomEmailHTML.preheader(previewText),
            bodyHTML: """
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%; max-width:600px; border-collapse:collapse;">
            <tr>
              <td style="padding:0 0 12px 0; color:#7C8696; font-size:12px; line-height:1.6; letter-spacing:0.08em; text-transform:uppercase; font-weight:700;">
                Patch Courier
              </td>
            </tr>
            <tr>
              <td style="background-color:#FFFFFF; border:1px solid #D8DDE6;">
                <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%; border-collapse:collapse;">
                  <tr>
                    <td style="padding:24px 24px 18px 24px; background-color:#FFF3E2; border-bottom:1px solid #D8DDE6;">
                      <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;">
                        <tr>
                          <td style="padding:6px 10px; background-color:#B87316; color:#FFFFFF; font-size:12px; line-height:1; font-weight:700; letter-spacing:0.04em; text-transform:uppercase;">
                            \(LT("Action needed", "需要回复", "返信が必要").htmlEscaped)
                          </td>
                        </tr>
                      </table>
                      <div style="padding-top:14px; font-size:26px; line-height:1.3; color:#18212D; font-weight:700; word-wrap:break-word; overflow-wrap:anywhere;">
                        \(request.summary.htmlEscaped)
                      </div>
                      <p style="margin:14px 0 0; color:#344054; font-size:15px; line-height:1.75;">\(waitingSummary.htmlEscaped)</p>
                    </td>
                  </tr>
                  <tr>
                    <td style="padding:24px 24px 28px 24px; background-color:#FCFBF8;">
                      \(MailroomEmailHTML.contentMarker)
                      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%; border-collapse:collapse; border:1px solid #D8DDE6; background-color:#FFFFFF;">
                        <tr>
                          <td style="padding:12px 16px; border-bottom:1px solid #EDF1F5;">
                            <div style="padding-bottom:4px; font-size:12px; line-height:1.4; letter-spacing:0.04em; text-transform:uppercase; color:#6B7280; font-weight:700;">\(LT("Thread", "线程", "スレッド").htmlEscaped)</div>
                            <div style="font-size:15px; line-height:1.65; font-family:ui-monospace, SFMono-Regular, Menlo, monospace; word-wrap:break-word; overflow-wrap:anywhere;">\(threadLabel.htmlEscaped)</div>
                          </td>
                        </tr>
                        <tr>
                          <td style="padding:12px 16px; border-bottom:1px solid #EDF1F5;">
                            <div style="padding-bottom:4px; font-size:12px; line-height:1.4; letter-spacing:0.04em; text-transform:uppercase; color:#6B7280; font-weight:700;">\(LT("Request", "请求", "要求").htmlEscaped)</div>
                            <div style="font-size:15px; line-height:1.65; font-family:ui-monospace, SFMono-Regular, Menlo, monospace; word-wrap:break-word; overflow-wrap:anywhere;">\(request.id.htmlEscaped)</div>
                          </td>
                        </tr>
                        <tr>
                          <td style="padding:12px 16px;">
                            <div style="padding-bottom:4px; font-size:12px; line-height:1.4; letter-spacing:0.04em; text-transform:uppercase; color:#6B7280; font-weight:700;">\(LT("Type", "类型", "タイプ").htmlEscaped)</div>
                            <div style="font-size:15px; line-height:1.65;">\(approvalKindTitle(request.kind).htmlEscaped)</div>
                          </td>
                        </tr>
                      </table>
                      \(detailHTML.isEmpty ? "" : approvalBlockSpacingHTML + detailHTML)
                      \(quickReplyHTML.isEmpty ? "" : approvalBlockSpacingHTML + quickReplyHTML)
                      \(nextStepsHTML.isEmpty ? "" : approvalBlockSpacingHTML + nextStepsHTML)
                      \(replyInstructionsHTML.isEmpty ? "" : approvalBlockSpacingHTML + replyInstructionsHTML)
                      \(footerHTML.isEmpty ? "" : approvalBlockSpacingHTML + footerHTML)
                    </td>
                  </tr>
                </table>
              </td>
            </tr>
          </table>
        """
        )

        return OutboundMailEnvelope(
            to: [recipient],
            subject: subject,
            plainBody: replyBodyText,
            htmlBody: htmlBody,
            inReplyTo: nil,
            references: []
        )
    }
}

private func approvalInboxPreviewText(
    request: MailroomApprovalRequest,
    answerLines: [String]
) -> String {
    if !request.availableDecisions.isEmpty {
        return LT(
            "Reply with one decision to resume this paused task. Quick-reply buttons are included in the email.",
            "请回复一个明确决定，这样就能恢复当前暂停的任务。邮件里也带了快捷回复按钮。",
            "1 つ判断を返信すると、この一時停止中タスクを再開できます。メールにはクイック返信ボタンも入っています。"
        )
    }

    if !answerLines.isEmpty {
        return LT(
            "Fill in the requested fields in the reply template below so Mailroom can resume this paused task.",
            "请填好下面模板里要求的字段，这样 Mailroom 才能恢复当前暂停的任务。",
            "下の返信テンプレートに必要項目を入れると、Mailroom がこの一時停止中タスクを再開できます。"
        )
    }

    return LT(
        "Reply in this thread using the template below so Mailroom can continue this paused task.",
        "请按下面模板在这个线程里回复，这样 Mailroom 才能继续当前暂停的任务。",
        "このスレッドで下のテンプレートを使って返信すると、Mailroom がこの一時停止中タスクを続行できます。"
    )
}

private func approvalReplyTemplateLines(
    request: MailroomApprovalRequest,
    threadLabel: String,
    answerLines: [String]
) -> [String] {
    var lines = [
        "THREAD: \(threadLabel)",
        "REQUEST: \(request.id)"
    ]

    if !request.availableDecisions.isEmpty {
        lines.append("DECISION: <\(request.availableDecisions.joined(separator: " | "))>")
    } else if !answerLines.isEmpty {
        lines.append(contentsOf: answerLines)
    }

    lines.append("NOTE:")
    return lines
}

private func approvalNextSteps(
    request: MailroomApprovalRequest,
    answerLines: [String]
) -> [String] {
    if !request.availableDecisions.isEmpty {
        return [
            LT("Choose one decision with a quick-reply button, or type it manually in DECISION.", "点一个快捷回复按钮选择决定，或者手动填写 DECISION。", "クイック返信ボタンで判断を選ぶか、DECISION に手動入力してください。"),
            LT("Keep THREAD and REQUEST unchanged so Mailroom can match your reply.", "请保持 THREAD 和 REQUEST 不变，这样 Mailroom 才能正确匹配这封回复。", "THREAD と REQUEST は変更せず、Mailroom がこの返信を正しく紐づけられるようにしてください。"),
            LT("Add NOTE only if you want to explain the decision.", "只有在你想补充说明时才填写 NOTE。", "判断の補足が必要な場合だけ NOTE を追加してください。")
        ]
    }

    if !answerLines.isEmpty {
        return [
            LT("Open the prepared reply template, or fill every ANSWER_* field manually.", "打开准备好的回复模板，或者手动填写每一个 ANSWER_* 字段。", "用意された返信テンプレートを開くか、各 ANSWER_* フィールドを手動で入力してください。"),
            LT("Keep THREAD and REQUEST unchanged so Mailroom can match your reply.", "请保持 THREAD 和 REQUEST 不变，这样 Mailroom 才能正确匹配这封回复。", "THREAD と REQUEST は変更せず、Mailroom がこの返信を正しく紐づけられるようにしてください。"),
            LT("Use NOTE if you want to add extra context beyond the requested answers.", "如果你想补充题目之外的上下文，可以写在 NOTE 里。", "求められた回答以外の補足があれば NOTE に書いてください。")
        ]
    }

    return [
        LT("Reply in this thread using the template below.", "请直接在这个线程里按下面模板回复。", "このスレッドで下のテンプレートを使って返信してください。"),
        LT("Keep THREAD and REQUEST unchanged so Mailroom can match your reply.", "请保持 THREAD 和 REQUEST 不变，这样 Mailroom 才能正确匹配这封回复。", "THREAD と REQUEST は変更せず、Mailroom がこの返信を正しく紐づけられるようにしてください。"),
        LT("Use NOTE for any context Mailroom should pass back to Codex.", "需要 Mailroom 传回 Codex 的补充信息，请写在 NOTE 里。", "Mailroom から Codex へ渡したい補足情報は NOTE に書いてください。")
    ]
}

private func approvalPlainBody(
    request: MailroomApprovalRequest,
    threadLabel: String,
    waitingSummary: String,
    nextSteps: [String],
    replyTemplateText: String,
    footerText: String
) -> String {
    var lines: [String] = [
        LT("Approval needed", "需要回复", "返信が必要"),
        "",
        request.summary,
        "",
        waitingSummary,
        "",
        "STATUS: \(LT("Action needed", "需要回复", "返信が必要"))",
        "THREAD: \(threadLabel)",
        "REQUEST: \(request.id)",
        "TYPE: \(approvalKindTitle(request.kind))"
    ]

    if let detail = request.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
        lines.append("")
        lines.append("\(LT("Details", "详情", "詳細")):")
        lines.append(detail)
    }

    if !nextSteps.isEmpty {
        lines.append("")
        lines.append(LT("Next:", "接下来：", "次の流れ:"))
        for (index, step) in nextSteps.enumerated() {
            lines.append("\(index + 1). \(step)")
        }
    }

    lines.append("")
    lines.append("\(LT("Reply format", "回复格式", "返信フォーマット")):")
    lines.append(replyTemplateText)
    lines.append("")
    lines.append(footerText)

    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func approvalNextStepsHTML(_ nextSteps: [String]) -> String {
    guard !nextSteps.isEmpty else {
        return ""
    }

    return approvalSectionHTML(
        title: LT("Next", "接下来", "次の流れ"),
        bodyHTML: """
        <ol style="margin:0; padding:0 0 0 22px; color:#18212D; font-size:15px; line-height:1.75;">
          \(nextSteps.map { "<li style=\"margin:0 0 8px;\">\(approvalInlineHTML($0))</li>" }.joined())
        </ol>
        """
    )
}

private func approvalFooterText(hasQuickReply: Bool) -> String {
    if hasQuickReply {
        return LT(
            "If the quick-reply link does not open in your mail app, just reply in the same thread and keep the THREAD and REQUEST lines unchanged.",
            "如果你的邮箱客户端没有打开快捷回复链接，直接在同一个线程里手动回复，并保持 THREAD 和 REQUEST 不变即可。",
            "メールアプリでクイック返信リンクが開かない場合は、同じスレッドに手動で返信し、THREAD と REQUEST をそのまま残してください。"
        )
    }

    return LT(
        "Reply in the same thread and keep the THREAD and REQUEST lines unchanged so Mailroom can continue the paused work.",
        "请在同一个线程里回复，并保持 THREAD 和 REQUEST 不变，这样 Mailroom 才能继续这项暂停中的工作。",
        "同じスレッドに返信し、THREAD と REQUEST をそのまま残すと、Mailroom が停止中の作業を続行できます。"
    )
}

private func approvalFooterHTML(_ footerText: String) -> String {
    """
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%; border-collapse:collapse;">
      <tr>
        <td style="font-size:13px; line-height:1.75; color:#667085;">\(approvalInlineHTML(footerText))</td>
      </tr>
    </table>
    """
}

private func approvalInlineHTML(_ text: String) -> String {
    var html = ""
    var buffer = ""
    var insideCode = false

    for character in text {
        if character == "`" {
            if insideCode {
                html += """
                <code style="padding:1px 4px; background-color:#F3F4F6; border:1px solid #E5E7EB; color:#18212D; font:13px/1.6 ui-monospace, SFMono-Regular, Menlo, monospace; word-wrap:break-word; overflow-wrap:anywhere;">\(buffer.htmlEscaped)</code>
                """
            } else {
                html += buffer.htmlEscaped
            }
            buffer.removeAll(keepingCapacity: true)
            insideCode.toggle()
        } else {
            buffer.append(character)
        }
    }

    if insideCode {
        html += "`" + buffer.htmlEscaped
    } else {
        html += buffer.htmlEscaped
    }

    return html
}

private func approvalParagraphHTML(_ text: String) -> String {
    let paragraphs = text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: "\n\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    guard !paragraphs.isEmpty else {
        return ""
    }

    return paragraphs.map { paragraph in
        let html = paragraph
            .components(separatedBy: "\n")
            .map { approvalInlineHTML($0) }
            .joined(separator: "<br>")
        return "<p style=\"margin:0 0 12px; color:#18212D; font-size:15px; line-height:1.78;\">\(html)</p>"
    }.joined()
}

private func approvalManualReplyIntro(
    request: MailroomApprovalRequest,
    answerLines: [String]
) -> String {
    if !request.availableDecisions.isEmpty {
        return LT(
            "If the quick reply button does not open in your mail app, copy this block into your reply and send it in the same thread.",
            "如果邮箱客户端没有打开快捷回复按钮，就把这段内容复制到你的回复里，并在同一个线程中发送。",
            "メールアプリでクイック返信ボタンが開かない場合は、このブロックを返信へコピーし、同じスレッドで送信してください。"
        )
    }

    if !answerLines.isEmpty {
        return LT(
            "If the prepared reply draft does not open, copy this block into your reply and fill in every requested field.",
            "如果准备好的回复草稿没有打开，就把这段内容复制到你的回复里，并补齐所有要求的字段。",
            "用意された返信ドラフトが開かない場合は、このブロックを返信へコピーし、必要な項目をすべて埋めてください。"
        )
    }

    return LT(
        "Reply in the same thread and keep the THREAD and REQUEST lines unchanged.",
        "请在同一个线程里回复，并保持 THREAD 和 REQUEST 不变。",
        "同じスレッドで返信し、THREAD と REQUEST を変更しないでください。"
    )
}

private func approvalManualReplyHTML(title: String, intro: String, template: String) -> String {
    approvalSectionHTML(
        title: title,
        bodyHTML: """
        <p style="margin:0 0 12px; color:#475467; font-size:15px; line-height:1.78;">\(approvalInlineHTML(intro))</p>
        \(approvalPreformattedHTML(template))
        """
    )
}

private func approvalKindTitle(_ kind: MailroomApprovalKind) -> String {
    switch kind {
    case .commandExecution:
        return LT("Command execution", "命令执行", "コマンド実行")
    case .fileChange:
        return LT("File change", "文件修改", "ファイル変更")
    case .userInput:
        return LT("User input", "用户输入", "ユーザー入力")
    case .permissions:
        return LT("Permissions", "权限", "権限")
    case .other:
        return LT("Other", "其他", "その他")
    }
}

private func approvalQuickReplyHTML(
    request: MailroomApprovalRequest,
    threadLabel: String,
    replyAddress: String,
    subject: String,
    answerLines: [String]
) -> String {
    if !request.availableDecisions.isEmpty {
        let cards = request.availableDecisions.enumerated().map { index, decision in
            let presentation = approvalDecisionPresentation(decision)
            let link = approvalReplyLink(
                replyAddress: replyAddress,
                subject: subject,
                body: """
                THREAD: \(threadLabel)
                REQUEST: \(request.id)
                DECISION: \(decision)
                NOTE:
                """
            )
            let card = approvalActionCardHTML(
                badge: presentation.badge,
                title: presentation.title,
                detailHTML: approvalInlineHTML(presentation.detail),
                accentHex: presentation.accentHex,
                link: link,
                buttonLabel: presentation.title
            )
            return (index == 0 ? "" : approvalBlockSpacingHTML) + card
        }.joined()

        return approvalSectionHTML(
            title: LT("Choose one decision", "请选择一个决定", "1 つ判断を選んでください"),
            bodyHTML: """
            <p style="margin:0 0 12px; color:#475467; font-size:15px; line-height:1.78;">\(approvalInlineHTML(LT("The buttons below open a reply draft with the decision already filled in. If they do not work in your mail app, use the manual reply block below.", "下面的按钮会打开一封已经填好决定的回复草稿；如果你的邮箱客户端不支持，就直接使用下面的手动回复格式。", "下のボタンは判断が入力済みの返信ドラフトを開きます。メールアプリで使えない場合は、下の手動返信フォーマットを使ってください。")))</p>
            \(cards)
            """
        )
    }

    guard !answerLines.isEmpty else {
        return ""
    }

    let link = approvalReplyLink(
        replyAddress: replyAddress,
        subject: subject,
        body: """
        THREAD: \(threadLabel)
        REQUEST: \(request.id)
        \(answerLines.joined(separator: "\n"))
        NOTE:
        """
    )

    return approvalSectionHTML(
        title: LT("Reply with template", "用模板回复", "テンプレートで返信"),
        bodyHTML: """
        <p style="margin:0 0 12px; color:#475467; font-size:15px; line-height:1.78;">\(approvalInlineHTML(LT("Open the prepared reply draft first. If it does not open, copy the manual reply block below and fill in the requested fields yourself.", "优先打开准备好的回复草稿；如果没有打开，就复制下面的手动回复块并自行填写要求的字段。", "まず用意された返信ドラフトを開いてください。開かない場合は、下の手動返信ブロックをコピーして必要項目を入力してください。")))</p>
        \(approvalActionCardHTML(
            badge: LT("Prepared draft", "已准备草稿", "準備済みドラフト"),
            title: LT("Reply with template", "用模板回复", "テンプレートで返信"),
            detailHTML: approvalInlineHTML(LT("Open a reply draft with the answer fields already prepared.", "打开一封已经准备好答题字段的回复草稿。", "回答欄が準備済みの返信ドラフトを開きます。")),
            accentHex: "#2D6CDF",
            link: link,
            buttonLabel: LT("Reply with template", "用模板回复", "テンプレートで返信")
        ))
        """
    )
}

private func approvalReplyLink(replyAddress: String, subject: String, body: String) -> String {
    var components = URLComponents()
    components.scheme = "mailto"
    components.path = replyAddress
    components.queryItems = [
        URLQueryItem(name: "subject", value: subject),
        URLQueryItem(name: "body", value: body)
    ]
    return components.string ?? "mailto:\(replyAddress)"
}

private func approvalDecisionTitle(_ raw: String) -> String {
    raw
        .split(separator: "_")
        .map { chunk in
            chunk.prefix(1).uppercased() + chunk.dropFirst().lowercased()
        }
        .joined(separator: " ")
}

private struct ApprovalDecisionPresentation {
    var title: String
    var badge: String
    var detail: String
    var accentHex: String
    var surfaceHex: String
}

private func approvalDecisionPresentation(_ raw: String) -> ApprovalDecisionPresentation {
    switch raw.lowercased() {
    case "approve":
        return ApprovalDecisionPresentation(
            title: LT("Approve and continue", "批准并继续", "承認して続行"),
            badge: LT("Continue task", "继续执行", "続行"),
            detail: LT(
                "Mailroom will resume this paused task and let Codex continue with the protected step.",
                "Mailroom 会恢复当前暂停的任务，并让 Codex 继续执行这个受保护的步骤。",
                "Mailroom はこの一時停止中タスクを再開し、Codex に保護されたステップの続きを実行させます。"
            ),
            accentHex: "#1F8F63",
            surfaceHex: "#EAF8F1"
        )
    case "reject":
        return ApprovalDecisionPresentation(
            title: LT("Reject for now", "先拒绝", "今回は拒否"),
            badge: LT("Stop here", "先停在这里", "ここで停止"),
            detail: LT(
                "Mailroom will keep the task paused here and return the rejection without running the protected step.",
                "Mailroom 会把任务停在这里，并返回拒绝结果，不会执行这个受保护的步骤。",
                "Mailroom はこの時点でタスクを止め、保護されたステップは実行せずに拒否結果を返します。"
            ),
            accentHex: "#C44949",
            surfaceHex: "#FDECEC"
        )
    default:
        let title = approvalDecisionTitle(raw)
        return ApprovalDecisionPresentation(
            title: title,
            badge: LT("Decision", "决定", "判断"),
            detail: LT(
                "Open a reply draft with this decision filled in.",
                "打开一封已填好这个决定的回复草稿。",
                "この判断が入った返信ドラフトを開きます。"
            ),
            accentHex: "#B87316",
            surfaceHex: "#FFF3E2"
        )
    }
}

private func approvalSectionHTML(title: String, bodyHTML: String) -> String {
    """
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%; border-collapse:collapse; border:1px solid #D8DDE6; background-color:#FFFFFF;">
      <tr>
        <td style="padding:14px 16px 0 16px; font-size:12px; line-height:1.4; letter-spacing:0.04em; text-transform:uppercase; color:#6B7280; font-weight:700;">\(title.htmlEscaped)</td>
      </tr>
      <tr>
        <td style="padding:12px 16px 16px 16px;">\(bodyHTML)</td>
      </tr>
    </table>
    """
}

private func approvalActionCardHTML(
    badge: String,
    title: String,
    detailHTML: String,
    accentHex: String,
    link: String,
    buttonLabel: String
) -> String {
    """
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%; border-collapse:collapse; border:1px solid #D8DDE6; background-color:#FFFFFF;">
      <tr>
        <td style="padding:16px;">
          <div style="font-size:11px; line-height:1.2; letter-spacing:0.08em; text-transform:uppercase; color:\(accentHex); font-weight:700;">\(badge.htmlEscaped)</div>
          <div style="padding-top:10px; font-size:18px; line-height:1.4; color:#18212D; font-weight:700; word-wrap:break-word; overflow-wrap:anywhere;">\(title.htmlEscaped)</div>
          <p style="margin:10px 0 0; color:#475467; font-size:14px; line-height:1.72;">\(detailHTML)</p>
          <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin-top:14px; border-collapse:collapse;">
            <tr>
              <td style="background-color:\(accentHex); text-align:center;">
                <a href="\(link.htmlEscaped)" style="display:inline-block; padding:12px 14px; color:#FFFFFF; text-decoration:none; font-size:14px; font-weight:700;">\(buttonLabel.htmlEscaped)</a>
              </td>
            </tr>
          </table>
        </td>
      </tr>
    </table>
    """
}

private func approvalPreformattedHTML(_ text: String) -> String {
    let lines = text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: "\n")
        .map { $0.htmlEscaped }
        .joined(separator: "<br>")
    return """
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%; border-collapse:collapse; background-color:#F7F4EE; border:1px solid #D8DDE6;">
      <tr>
        <td style="padding:14px 16px; color:#18212D; font:13px/1.7 ui-monospace, SFMono-Regular, Menlo, monospace; word-wrap:break-word; overflow-wrap:anywhere;">
          \(lines)
        </td>
      </tr>
    </table>
    """
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

enum ApprovalReplyParser {
    static func parse(_ body: String) -> ParsedApprovalReply? {
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var requestID: String?
        var decision: String?
        var answers: [String: [String]] = [:]
        var noteLines: [String] = []
        var currentAnswerKey: String?
        var noteMode = false

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if let currentAnswerKey {
                    answers[currentAnswerKey, default: []].append("")
                } else if noteMode {
                    noteLines.append("")
                }
                continue
            }

            if line.uppercased().hasPrefix("REQUEST:") {
                requestID = fieldValue(from: line)
                currentAnswerKey = nil
                noteMode = false
                continue
            }

            if line.uppercased().hasPrefix("DECISION:") {
                decision = fieldValue(from: line)
                currentAnswerKey = nil
                noteMode = false
                continue
            }

            if line.uppercased().hasPrefix("NOTE:") {
                noteMode = true
                currentAnswerKey = nil
                continue
            }

            if line.uppercased().hasPrefix("ANSWER_") {
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                let key = parts[0].dropFirst("ANSWER_".count).trimmingCharacters(in: .whitespacesAndNewlines)
                currentAnswerKey = key.isEmpty ? nil : key
                noteMode = false
                if let key = currentAnswerKey {
                    answers[key, default: []] = []
                    if parts.count == 2 {
                        let inline = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !inline.isEmpty {
                            answers[key, default: []].append(inline)
                        }
                    }
                }
                continue
            }

            if let currentAnswerKey {
                answers[currentAnswerKey, default: []].append(line)
                continue
            }

            if noteMode {
                noteLines.append(line)
            }
        }

        guard let requestID, !requestID.isEmpty else { return nil }

        let cleanedAnswers = answers.mapValues { values in
            values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        let note = noteLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        return ParsedApprovalReply(
            requestID: requestID,
            decision: decision?.trimmingCharacters(in: .whitespacesAndNewlines),
            answers: cleanedAnswers,
            note: note.isEmpty ? nil : note
        )
    }

    private static func fieldValue(from line: String) -> String? {
        guard let separator = line.firstIndex(of: ":") else { return nil }
        let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

enum ThreadConfirmationDecision: String, Hashable, Sendable {
    case startTask
    case recordOnly
}

struct ParsedThreadConfirmation: Hashable, Sendable {
    var decision: ThreadConfirmationDecision
    var customPrompt: String?
}

enum ThreadConfirmationReplyParser {
    static func parse(_ body: String) -> ParsedThreadConfirmation? {
        let stripped = MailroomMailParser.stripQuotedReplyChain(from: body)
        let normalized = stripped.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var decision: ThreadConfirmationDecision?
        var taskLines: [String] = []
        var capturingTask = false

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty {
                if capturingTask, !taskLines.isEmpty, taskLines.last != "" {
                    taskLines.append("")
                }
                continue
            }

            if let field = parseField(trimmed) {
                switch field.key {
                case "mode":
                    decision = decisionValue(from: field.value)
                    capturingTask = false
                case "task":
                    capturingTask = true
                    taskLines = []
                    if !field.value.isEmpty {
                        taskLines.append(field.value)
                    }
                default:
                    break
                }
                continue
            }

            if let inlineDecision = decisionValue(from: trimmed) {
                decision = inlineDecision
                capturingTask = false
                continue
            }

            if capturingTask || decision != nil {
                capturingTask = true
                taskLines.append(rawLine)
            }
        }

        if decision == nil,
           let firstMeaningfulLine = lines
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            decision = decisionValue(from: firstMeaningfulLine)
        }

        guard let decision else {
            return nil
        }

        let customPrompt = taskLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ParsedThreadConfirmation(
            decision: decision,
            customPrompt: customPrompt.isEmpty ? nil : customPrompt
        )
    }

    private static func parseField(_ line: String) -> (key: String, value: String)? {
        guard let separator = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
            return nil
        }

        let rawKey = line[..<separator]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let value = line[line.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch rawKey {
        case "mode", "decision", "action", "reply", "模式", "处理", "操作":
            return ("mode", value)
        case "task", "prompt", "request", "任务", "说明", "内容":
            return ("task", value)
        default:
            return nil
        }
    }

    private static func decisionValue(from rawValue: String) -> ThreadConfirmationDecision? {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let compactChoice = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "[](){}<>.:;,!?，。；：、_"))

        switch compactChoice {
        case "1", "选1", "选项1", "option1", "option_1", "choice1", "choice_1":
            return .startTask
        case "2", "选2", "选项2", "option2", "option_2", "choice2", "choice_2":
            return .recordOnly
        default:
            break
        }

        switch normalized {
        case "start", "start_task", "run", "run_task", "yes", "go", "开始", "开始任务", "执行", "运行", "启动":
            return .startTask
        case "record", "record_only", "log_only", "archive", "no_run", "仅记录", "记录", "归档", "只存档", "不要执行", "不执行":
            return .recordOnly
        default:
            break
        }

        let startPrefixes = [
            "start_",
            "run_",
            "go_",
            "开始",
            "执行",
            "运行",
            "启动"
        ]
        if startPrefixes.contains(where: { normalized.hasPrefix($0) }) {
            return .startTask
        }

        let recordPrefixes = [
            "record_",
            "archive_",
            "log_",
            "仅记录",
            "记录",
            "归档",
            "只存档",
            "不要执行",
            "不执行"
        ]
        if recordPrefixes.contains(where: { normalized.hasPrefix($0) }) {
            return .recordOnly
        }

        return nil
    }
}
