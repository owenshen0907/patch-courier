import Foundation

enum MailroomPaths {
    private static let directoryName = "PatchCourier"

    static func applicationSupportDirectory() throws -> URL {
        let fileManager = FileManager.default
        guard let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }

        let directory = baseDirectory.appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        return directory
    }

    static func applicationSupportDirectory(path: String) throws -> URL {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        return directory
    }

    static func accountsFileURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("mailbox-accounts.json")
    }

    static func senderPoliciesFileURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("sender-policies.json")
    }

    static func jobsDatabaseURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("jobs.sqlite")
    }

    static func mailroomDatabaseURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("mailroom.sqlite3")
    }

    static func mailboxPasswordCacheURL(supportRootPath: String? = ProcessInfo.processInfo.environment["MAILROOM_SUPPORT_ROOT"]) throws -> URL {
        let supportDirectory: URL
        if let supportRootPath {
            supportDirectory = try applicationSupportDirectory(path: supportRootPath)
        } else {
            supportDirectory = try applicationSupportDirectory()
        }
        return supportDirectory.appendingPathComponent("mailbox-password-cache.json")
    }

    static func runtimeStateFileURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("runtime-state.json")
    }

    static func runtimeToolsDirectory() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("runtime-tools", isDirectory: true)
    }

    static func mailTransportScriptURL() throws -> URL {
        try runtimeToolsDirectory().appendingPathComponent("mail_transport.py")
    }

    static func daemonControlFileURL(supportRootPath: String? = nil) throws -> URL {
        let supportDirectory: URL
        if let supportRootPath {
            supportDirectory = try applicationSupportDirectory(path: supportRootPath)
        } else {
            supportDirectory = try applicationSupportDirectory()
        }
        return supportDirectory.appendingPathComponent("daemon-control.json")
    }
}
