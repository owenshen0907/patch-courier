import Foundation

struct MailTransportClient: Sendable {
    let scriptURL: URL
    let pythonCandidates: [String]

    init(
        scriptURL: URL,
        pythonCandidates: [String] = [
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3"
        ]
    ) {
        self.scriptURL = scriptURL
        self.pythonCandidates = pythonCandidates
    }

    func fetchMessages(
        account: MailboxAccount,
        password: String,
        lastUID: UInt64?
    ) throws -> MailFetchResult {
        let payload = MailFetchPayload(account: account, password: password, lastUID: lastUID)
        return try run(command: "fetch", payload: payload, decode: MailFetchResult.self)
    }

    func fetchRecentHistory(
        account: MailboxAccount,
        password: String,
        limit: Int = 20
    ) throws -> MailHistoryResult {
        let payload = MailHistoryPayload(account: account, password: password, limit: limit)
        return try run(command: "history", payload: payload, decode: MailHistoryResult.self)
    }

    func mutateMessages(
        account: MailboxAccount,
        password: String,
        uids: [UInt64],
        action: MailroomMailboxRemoteAction
    ) throws -> MailMessageMutationResult {
        let payload = MailMessageMutationPayload(
            account: account,
            password: password,
            uids: uids,
            action: action
        )
        return try run(command: "mutate", payload: payload, decode: MailMessageMutationResult.self)
    }

    func sendMessage(
        account: MailboxAccount,
        password: String,
        message: OutboundMailMessage
    ) throws -> MailSendResult {
        let payload = MailSendPayload(account: account, password: password, message: message)
        return try run(command: "send", payload: payload, decode: MailSendResult.self)
    }

    func probe(
        account: MailboxAccount,
        password: String
    ) throws -> MailProbeResult {
        let payload = MailProbePayload(account: account, password: password)
        return try run(command: "probe", payload: payload, decode: MailProbeResult.self)
    }

    private func run<Payload: Encodable, Output: Decodable>(
        command: String,
        payload: Payload,
        decode: Output.Type
    ) throws -> Output {
        try installScriptIfNeeded()
        let pythonURL = try resolvePythonURL()
        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [scriptURL.path, command]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let encodedPayload = try encoder.encode(payload)

        do {
            try process.run()
        } catch {
            throw MailTransportError.launchFailed(error.localizedDescription)
        }

        stdinPipe.fileHandleForWriting.write(encodedPayload)
        try? stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            throw MailTransportError.commandFailed(command: command, details: stderr.nilIfBlank)
        }

        do {
            return try decoder.decode(Output.self, from: stdoutData)
        } catch {
            let raw = String(decoding: stdoutData, as: UTF8.self)
            throw MailTransportError.invalidResponse(command: command, details: raw.nilIfBlank ?? stderr)
        }
    }

    private func installScriptIfNeeded() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: scriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )

        let contents = Self.pythonScript
        let existing = try? String(contentsOf: scriptURL, encoding: .utf8)
        guard existing != contents else {
            return
        }

        try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
    }

    private func resolvePythonURL() throws -> URL {
        let fileManager = FileManager.default
        guard let candidate = pythonCandidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
            throw MailTransportError.pythonNotFound
        }
        return URL(fileURLWithPath: candidate)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum MailTransportError: LocalizedError, Sendable {
    case pythonNotFound
    case launchFailed(String)
    case commandFailed(command: String, details: String?)
    case invalidResponse(command: String, details: String?)

    var errorDescription: String? {
        switch self {
        case .pythonNotFound:
            return LT(
                "Python 3 is required for IMAP and SMTP transport, but no python3 executable was found.",
                "IMAP 和 SMTP 传输依赖 Python 3，但当前没有找到 python3 可执行文件。",
                "IMAP と SMTP の転送には Python 3 が必要だが、python3 実行ファイルが見つからない。"
            )
        case .launchFailed(let details):
            return LT(
                "Mail transport helper could not start: \(details)",
                "邮件传输辅助进程启动失败：\(details)",
                "メール転送ヘルパーを起動できない: \(details)"
            )
        case .commandFailed(let command, let details):
            let suffix = details ?? LT("Unknown error.", "未知错误。", "不明なエラー。")
            return LT(
                "Mail transport command \(command) failed: \(suffix)",
                "邮件传输命令 \(command) 失败：\(suffix)",
                "メール転送コマンド \(command) が失敗した: \(suffix)"
            )
        case .invalidResponse(let command, let details):
            let suffix = details ?? LT("Unknown output.", "未知输出。", "不明な出力。")
            return LT(
                "Mail transport command \(command) returned an unreadable response: \(suffix)",
                "邮件传输命令 \(command) 返回了不可解析的响应：\(suffix)",
                "メール転送コマンド \(command) が読み取れない応答を返した: \(suffix)"
            )
        }
    }
}

private struct MailFetchPayload: Encodable {
    var account: MailboxAccount
    var password: String
    var lastUID: UInt64?
}

private struct MailSendPayload: Encodable {
    var account: MailboxAccount
    var password: String
    var message: OutboundMailMessage
}

private struct MailProbePayload: Encodable {
    var account: MailboxAccount
    var password: String
}

private struct MailHistoryPayload: Encodable {
    var account: MailboxAccount
    var password: String
    var limit: Int
}

private struct MailMessageMutationPayload: Encodable {
    var account: MailboxAccount
    var password: String
    var uids: [UInt64]
    var action: MailroomMailboxRemoteAction
}

struct MailMessageMutationResult: Decodable, Sendable {
    var action: MailroomMailboxRemoteAction
    var requestedCount: Int
    var affectedUIDs: [UInt64]
    var destinationMailbox: String?
    var expunged: Bool

    private enum CodingKeys: String, CodingKey {
        case action
        case requestedCount = "requested_count"
        case affectedUIDs = "affected_uids"
        case destinationMailbox = "destination_mailbox"
        case expunged
    }
}

struct MailProbeResult: Decodable, Sendable {
    let imap: LegStatus
    let smtp: LegStatus

    struct LegStatus: Decodable, Sendable {
        let ok: Bool
        let detail: String?
    }
}

private extension MailTransportClient {
    static var pythonScript: String {
        #"""
#!/usr/bin/env python3
import html
import imaplib
import json
import re
import smtplib
import ssl
import sys
from datetime import datetime, timezone
from email import policy
from email.message import EmailMessage
from email.parser import BytesParser
from email.utils import format_datetime, getaddresses, make_msgid, parseaddr, parsedate_to_datetime


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def read_payload() -> dict:
    raw = sys.stdin.buffer.read()
    if not raw:
        return {}
    return json.loads(raw.decode("utf-8"))


def normalize_date(raw_value):
    if not raw_value:
        return None
    try:
        return parsedate_to_datetime(raw_value).isoformat()
    except Exception:
        return None


def extract_message_ids(raw_value: str) -> list[str]:
    if not raw_value:
        return []
    return re.findall(r"<[^>]+>", raw_value)


def html_to_text(raw_html: str) -> str:
    text = re.sub(r"<br\s*/?>", "\n", raw_html, flags=re.IGNORECASE)
    text = re.sub(r"</p\s*>", "\n\n", text, flags=re.IGNORECASE)
    text = re.sub(r"<[^>]+>", " ", text)
    text = html.unescape(text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def get_body_text(message) -> str:
    if message.is_multipart():
        plain_parts = []
        html_parts = []
        for part in message.walk():
            if part.get_content_disposition() == "attachment":
                continue
            content_type = part.get_content_type()
            try:
                content = part.get_content()
            except Exception:
                payload = part.get_payload(decode=True) or b""
                charset = part.get_content_charset() or "utf-8"
                content = payload.decode(charset, errors="replace")
            if content_type == "text/plain":
                plain_parts.append(str(content).strip())
            elif content_type == "text/html":
                html_parts.append(str(content))
        if plain_parts:
            return "\n\n".join([part for part in plain_parts if part]).strip()
        if html_parts:
            return "\n\n".join([html_to_text(part) for part in html_parts if part]).strip()
        return ""

    try:
        content = message.get_content()
    except Exception:
        payload = message.get_payload(decode=True) or b""
        charset = message.get_content_charset() or "utf-8"
        content = payload.decode(charset, errors="replace")

    if message.get_content_type() == "text/html":
        return html_to_text(str(content))
    return str(content).strip()


def connect_imap(account: dict, password: str):
    imap_config = account["imap"]
    security = imap_config["security"]
    host = imap_config["host"]
    port = int(imap_config["port"])

    if security == "sslTLS":
        client = imaplib.IMAP4_SSL(host, port)
    else:
        client = imaplib.IMAP4(host, port)
        if security == "startTLS":
            client.starttls(ssl_context=ssl.create_default_context())

    client.login(account["email_address"], password)
    return client


def connect_smtp(account: dict, password: str):
    smtp_config = account["smtp"]
    security = smtp_config["security"]
    host = smtp_config["host"]
    port = int(smtp_config["port"])

    if security == "sslTLS":
        client = smtplib.SMTP_SSL(host, port, timeout=30)
    else:
        client = smtplib.SMTP(host, port, timeout=30)
        client.ehlo()
        if security == "startTLS":
            client.starttls(context=ssl.create_default_context())
            client.ehlo()

    client.login(account["email_address"], password)
    return client


def decode_messages_by_uid(client, uids: list[int]) -> list[dict]:
    messages = []
    for uid in uids:
        status, rows = client.uid("fetch", str(uid), "(BODY.PEEK[])")
        if status != "OK":
            continue

        raw_bytes = None
        for row in rows:
            if isinstance(row, tuple) and len(row) > 1:
                raw_bytes = row[1]
                break
        if raw_bytes is None:
            continue

        parsed = BytesParser(policy=policy.default).parsebytes(raw_bytes)
        sender_name, sender_address = parseaddr(parsed.get("From", ""))
        message_id = parsed.get("Message-ID") or f"<uid-{uid}@mailroom.local>"
        references = []
        for header in parsed.get_all("References", []):
            references.extend(extract_message_ids(header))

        messages.append(
            {
                "uid": uid,
                "message_id": message_id,
                "from_address": sender_address.lower(),
                "from_display_name": sender_name or None,
                "subject": parsed.get("Subject", "").strip(),
                "plain_body": get_body_text(parsed),
                "received_at": normalize_date(parsed.get("Date")) or normalize_date(parsed.get("Resent-Date")) or datetime.now(timezone.utc).isoformat(),
                "in_reply_to": parsed.get("In-Reply-To"),
                "references": references,
            }
        )
    return messages


def fetch_messages(payload: dict) -> dict:
    account = payload["account"]
    password = payload["password"]
    last_uid = payload.get("last_uid")

    client = connect_imap(account, password)
    try:
        status, _ = client.select("INBOX")
        if status != "OK":
            fail("Could not open INBOX.")

        status, data = client.uid("search", None, "ALL")
        if status != "OK":
            fail("Could not search mailbox UIDs.")

        raw_uids = data[0].split() if data and data[0] else []
        uids = [int(item) for item in raw_uids]
        if last_uid is None:
            bootstrap_uid = max(uids) if uids else 0
            history_uids = uids[-20:]
            return {
                # Keep a concrete watermark so the first message after an empty bootstrap is not skipped.
                "last_uid": bootstrap_uid,
                "messages": decode_messages_by_uid(client, history_uids),
                "did_bootstrap": True,
            }

        pending_uids = [uid for uid in uids if uid > int(last_uid)]
        messages = decode_messages_by_uid(client, pending_uids)

        return {
            "last_uid": max([int(last_uid)] + pending_uids) if pending_uids else int(last_uid),
            "messages": messages,
            "did_bootstrap": False,
        }
    finally:
        try:
            client.logout()
        except Exception:
            pass


def fetch_history(payload: dict) -> dict:
    account = payload["account"]
    password = payload["password"]
    limit = max(1, min(int(payload.get("limit", 20)), 100))

    client = connect_imap(account, password)
    try:
        status, _ = client.select("INBOX")
        if status != "OK":
            fail("Could not open INBOX.")

        status, data = client.uid("search", None, "ALL")
        if status != "OK":
            fail("Could not search mailbox UIDs.")

        raw_uids = data[0].split() if data and data[0] else []
        uids = [int(item) for item in raw_uids]
        selected_uids = uids[-limit:]
        messages = decode_messages_by_uid(client, selected_uids)
        messages.sort(key=lambda item: item["uid"], reverse=True)
        return {
            "visible_count": len(uids),
            "messages": messages,
        }
    finally:
        try:
            client.logout()
        except Exception:
            pass


def parse_mailbox_list_row(row):
    if isinstance(row, bytes):
        text = row.decode("utf-8", errors="replace")
    else:
        text = str(row)

    match = re.match(r"\((?P<flags>[^\)]*)\)\s+\"?(?P<delimiter>[^\"]*)\"?\s+(?P<name>.+)$", text)
    if not match:
        return None

    raw_name = match.group("name").strip()
    if raw_name.startswith('"') and raw_name.endswith('"'):
        raw_name = raw_name[1:-1].replace(r'\"', '"').replace(r"\\", "\\")

    return {
        "name": raw_name,
        "flags": [flag.lower() for flag in match.group("flags").split()],
    }


def list_mailboxes(client) -> list[dict]:
    status, rows = client.list()
    if status != "OK":
        return []
    mailboxes = []
    for row in rows or []:
        parsed = parse_mailbox_list_row(row)
        if parsed and parsed.get("name"):
            mailboxes.append(parsed)
    return mailboxes


def find_destination_mailbox(client, action: str):
    mailboxes = list_mailboxes(client)
    special_flag = r"\archive" if action == "archive" else r"\trash"
    for mailbox in mailboxes:
        if special_flag in mailbox["flags"]:
            return mailbox["name"]

    common_names = {
        "archive": [
            "Archive",
            "Archives",
            "INBOX.Archive",
            "[Gmail]/All Mail",
            "[Google Mail]/All Mail",
            "All Mail",
        ],
        "delete": [
            "Trash",
            "Deleted Messages",
            "Deleted Items",
            "INBOX.Trash",
            "[Gmail]/Trash",
            "[Google Mail]/Trash",
        ],
    }[action]
    by_lower_name = {mailbox["name"].lower(): mailbox["name"] for mailbox in mailboxes}
    for name in common_names:
        match = by_lower_name.get(name.lower())
        if match:
            return match
    return None


def quote_mailbox(client, mailbox_name: str) -> str:
    quote = getattr(client, "_quote", None)
    if quote:
        return quote(mailbox_name)
    escaped = mailbox_name.replace("\\", "\\\\").replace('"', r'\"')
    return f'"{escaped}"'


def move_uids_to_mailbox(client, uid_set: str, destination: str) -> bool:
    quoted_destination = quote_mailbox(client, destination)
    status, _ = client.uid("MOVE", uid_set, quoted_destination)
    if status == "OK":
        return True

    status, _ = client.uid("COPY", uid_set, quoted_destination)
    if status != "OK":
        return False

    status, _ = client.uid("STORE", uid_set, "+FLAGS.SILENT", r"(\Deleted)")
    if status != "OK":
        return False
    client.expunge()
    return True


def mutate_messages(payload: dict) -> dict:
    account = payload["account"]
    password = payload["password"]
    action = payload.get("action")
    if action not in ("archive", "delete"):
        fail("Unsupported mailbox mutation action.")

    uids = sorted({int(uid) for uid in payload.get("uids", []) if int(uid) > 0})
    if not uids:
        fail("No message UIDs were provided.")

    client = connect_imap(account, password)
    destination = None
    expunged = False
    try:
        status, _ = client.select("INBOX")
        if status != "OK":
            fail("Could not open INBOX.")

        uid_set = ",".join(str(uid) for uid in uids)
        destination = find_destination_mailbox(client, action)

        if destination:
            if not move_uids_to_mailbox(client, uid_set, destination):
                fail(f"Could not move message(s) to {destination}.")
        elif action == "delete":
            status, _ = client.uid("STORE", uid_set, "+FLAGS.SILENT", r"(\Deleted)")
            if status != "OK":
                fail("Could not mark message(s) as deleted.")
            client.expunge()
            expunged = True
        else:
            fail("Could not find an Archive mailbox for this account.")

        return {
            "action": action,
            "requested_count": len(uids),
            "affected_uids": uids,
            "destination_mailbox": destination,
            "expunged": expunged,
        }
    finally:
        try:
            client.logout()
        except Exception:
            pass


def send_message(payload: dict) -> dict:
    account = payload["account"]
    password = payload["password"]
    message_payload = payload["message"]

    message = EmailMessage()
    message["From"] = account["email_address"]
    message["To"] = ", ".join(message_payload["to"])
    message["Subject"] = message_payload["subject"]

    if message_payload.get("in_reply_to"):
        message["In-Reply-To"] = message_payload["in_reply_to"]

    references = message_payload.get("references") or []
    if references:
        message["References"] = " ".join(references)

    message_id = make_msgid(domain=account["email_address"].split("@")[-1])
    message["Date"] = format_datetime(datetime.now(timezone.utc))
    message["Message-ID"] = message_id
    message.set_content(message_payload["plain_body"])
    html_body = message_payload.get("html_body")
    if html_body and str(html_body).strip():
        message.add_alternative(str(html_body), subtype="html")

    client = connect_smtp(account, password)
    try:
        client.send_message(message)
    finally:
        try:
            client.quit()
        except Exception:
            pass

    return {"message_id": message_id}


def probe_connection(payload: dict) -> dict:
    account = payload["account"]
    password = payload["password"]
    address = account.get("email_address", "")

    imap_result = {"ok": False, "detail": "IMAP check did not run."}
    try:
        client = connect_imap(account, password)
        try:
            status, _ = client.select("INBOX")
            if status != "OK":
                raise RuntimeError("IMAP login succeeded, but INBOX could not be opened.")
            status, data = client.uid("search", None, "ALL")
            if status != "OK":
                raise RuntimeError("INBOX opened, but UID search failed.")
            visible_count = len(data[0].split()) if data and data[0] else 0
            imap_result = {
                "ok": True,
                "detail": f"IMAP login succeeded and INBOX is readable for {address} ({visible_count} visible message(s)).",
            }
        finally:
            try:
                client.logout()
            except Exception:
                pass
    except Exception as err:
        imap_result = {"ok": False, "detail": str(err) or type(err).__name__}

    smtp_result = {"ok": False, "detail": "SMTP check did not run."}
    try:
        client = connect_smtp(account, password)
        try:
            client.noop()
            smtp_result = {"ok": True, "detail": f"SMTP login succeeded for {address}."}
        finally:
            try:
                client.quit()
            except Exception:
                pass
    except Exception as err:
        smtp_result = {"ok": False, "detail": str(err) or type(err).__name__}

    return {"imap": imap_result, "smtp": smtp_result}


def main():
    if len(sys.argv) < 2:
        fail("Expected a transport command.")

    try:
        payload = read_payload()
        command = sys.argv[1]
        if command == "fetch":
            result = fetch_messages(payload)
        elif command == "history":
            result = fetch_history(payload)
        elif command == "mutate":
            result = mutate_messages(payload)
        elif command == "send":
            result = send_message(payload)
        elif command == "probe":
            result = probe_connection(payload)
        else:
            fail(f"Unsupported command: {command}")
    except Exception as exc:
        fail(str(exc))

    print(json.dumps(result))


if __name__ == "__main__":
    main()
"""#
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
