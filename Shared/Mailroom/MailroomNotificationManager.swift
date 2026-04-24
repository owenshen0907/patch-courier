import Foundation
import UserNotifications

@MainActor
final class MailroomNotificationManager {
    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults
    private let baselineKey = "io.github.patchcourier.notifications.baseline-established"
    private let authorizationRequestedKey = "io.github.patchcourier.notifications.authorization-requested"
    private let notifiedIDsKey = "io.github.patchcourier.notifications.notified-ids"

    init(
        center: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard
    ) {
        self.center = center
        self.defaults = defaults
    }

    func processRecentMailActivity(_ activity: [MailroomDaemonRecentMessageSummary]) {
        requestAuthorizationIfNeeded()

        let currentIDs = Array(activity.prefix(40).map(\.id))
        guard defaults.bool(forKey: baselineKey) else {
            defaults.set(true, forKey: baselineKey)
            defaults.set(currentIDs, forKey: notifiedIDsKey)
            return
        }

        var notifiedIDs = Set(defaults.stringArray(forKey: notifiedIDsKey) ?? [])
        let candidates = activity
            .reversed()
            .filter { shouldNotify(for: $0) && !notifiedIDs.contains($0.id) }

        for item in candidates {
            scheduleNotification(for: item)
            notifiedIDs.insert(item.id)
        }

        let trimmed = Array((activity.prefix(40).map(\.id) + Array(notifiedIDs)).prefix(80))
        defaults.set(trimmed, forKey: notifiedIDsKey)
    }

    private func requestAuthorizationIfNeeded() {
        guard !defaults.bool(forKey: authorizationRequestedKey) else {
            return
        }

        defaults.set(true, forKey: authorizationRequestedKey)
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    private func shouldNotify(for item: MailroomDaemonRecentMessageSummary) -> Bool {
        if item.action == "historical" {
            return false
        }
        if item.sender.caseInsensitiveCompare(item.mailboxEmailAddress) == .orderedSame {
            return false
        }
        return true
    }

    private func scheduleNotification(for item: MailroomDaemonRecentMessageSummary) {
        let content = UNMutableNotificationContent()
        content.title = notificationTitle(for: item)
        content.body = notificationBody(for: item)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "mailroom.\(item.id)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        center.add(request)
    }

    private func notificationTitle(for item: MailroomDaemonRecentMessageSummary) -> String {
        switch item.action {
        case "challenged":
            return LT("Choose start or record", "请选择启动还是仅记录", "開始するか記録だけにするか選んでください")
        case "recorded":
            return LT("Mail recorded only", "邮件已只做记录", "メールは記録のみになった")
        case "approvalRequested":
            return LT("Codex is waiting for your reply", "Codex 正在等你回复", "Codex が返信を待っている")
        case "completed":
            return LT("Codex replied by mail", "Codex 已通过邮件回复", "Codex がメールで返信した")
        case "rejected":
            return LT("A message was rejected", "有邮件被拒绝了", "メールが拒否された")
        case "failed":
            return LT("A mail task failed", "邮件任务失败", "メールタスクが失敗した")
        default:
            return LT("New mail reached Mailroom", "有新邮件进入 Mailroom", "新しいメールが Mailroom に届いた")
        }
    }

    private func notificationBody(for item: MailroomDaemonRecentMessageSummary) -> String {
        let subject = item.subject.isEmpty
            ? LT("(No subject)", "（无主题）", "（件名なし）")
            : item.subject
        return "\(item.sender)\n\(subject)"
    }
}
