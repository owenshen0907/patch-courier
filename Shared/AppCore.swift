import Foundation

enum AppBuildMetadata {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    static let buildDate = resolveBuildDate()
    static let buildStamp = resolveBuildStamp()
    static let displayVersion = "\(version)+\(buildStamp)"
    static let updatedAt = resolveUpdatedAt()

    private static func resolveBuildDate() -> Date? {
        let bundle = Bundle.main
        let candidates = [bundle.executableURL, bundle.bundleURL.appendingPathComponent("Info.plist")]

        for candidate in candidates {
            guard let candidate else {
                continue
            }

            if let values = try? candidate.resourceValues(forKeys: [.contentModificationDateKey]),
               let date = values.contentModificationDate {
                return date
            }
        }

        return nil
    }

    private static func resolveBuildStamp() -> String {
        guard let buildDate else {
            return build
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: buildDate)
    }

    private static func resolveUpdatedAt() -> String {
        guard let buildDate else {
            return Bundle.main.object(forInfoDictionaryKey: "AppLastUpdatedAt") as? String ?? LT("Unknown", "未知", "不明")
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss z"
        return formatter.string(from: buildDate)
    }
}

enum OperatorWorkspaceSection: String, CaseIterable, Identifiable {
    case overview
    case mailboxes
    case policies
    case dispatch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview:
            return LT("Overview", "总览", "概要")
        case .mailboxes:
            return LT("Mailboxes", "邮箱", "メールボックス")
        case .policies:
            return LT("Sender policies", "发件人策略", "送信者ポリシー")
        case .dispatch:
            return LT("Dispatch lab", "执行与账本", "ディスパッチ")
        }
    }

    var subtitle: String {
        switch self {
        case .overview:
            return LT("See queue posture and the next setup step at a glance.", "先看当前状态，再决定下一步操作。", "現在地と次の操作を一目で把握する。")
        case .mailboxes:
            return LT("Configure mailbox accounts, credentials, and workspace roots.", "集中处理邮箱账号、密码和工作区根目录。", "メールアカウント、認証情報、ワークスペースルートを設定する。")
        case .policies:
            return LT("Choose which senders can reach Codex and what scope they get.", "决定哪些发件人能进入 Codex，以及他们能做什么。", "どの送信者を Codex へ通し、どこまで許可するか決める。")
        case .dispatch:
            return LT("Preview decisions, run bounded requests, and inspect the ledger.", "预演策略结果、发起受控执行、查看任务账本。", "判定を試し、制御された実行を流し、ジョブ台帳を確認する。")
        }
    }

    var systemImage: String {
        switch self {
        case .overview:
            return "square.grid.2x2"
        case .mailboxes:
            return "tray.full"
        case .policies:
            return "person.crop.rectangle.badge.checkmark"
        case .dispatch:
            return "paperplane"
        }
    }

    var accent: String {
        switch self {
        case .overview:
            return LT("Status", "状态", "ステータス")
        case .mailboxes:
            return LT("Account setup", "账号配置", "アカウント設定")
        case .policies:
            return LT("Trust rules", "信任规则", "信頼ルール")
        case .dispatch:
            return LT("Run + audit", "执行与审计", "実行と監査")
        }
    }
}
