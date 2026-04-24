import Foundation
import Security

struct KeychainSecretStore {
    private let service = "io.github.patchcourier.mailbox-password"
    private let fileManager = FileManager.default

    func savePassword(_ password: String, for accountID: String) throws {
        try saveCachedPassword(password, for: accountID)

        do {
            try savePasswordToKeychain(password, for: accountID)
        } catch {
            // The daemon may run without an interactive UI session, so the local
            // cache is the required source of truth for background mailbox polling.
            return
        }
    }

    func password(for accountID: String) throws -> String? {
        do {
            if let password = try passwordFromKeychain(for: accountID)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !password.isEmpty {
                try? saveCachedPassword(password, for: accountID)
                return password
            }
        } catch {
            if let cachedPassword = try cachedPassword(for: accountID)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !cachedPassword.isEmpty {
                return cachedPassword
            }
            throw error
        }

        return try cachedPassword(for: accountID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func containsPassword(for accountID: String) -> Bool {
        guard let password = try? password(for: accountID) else {
            return false
        }
        return !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func deletePassword(for accountID: String) throws {
        try deleteCachedPassword(for: accountID)

        do {
            try deletePasswordFromKeychain(for: accountID)
        } catch {
            return
        }
    }

    func primeLocalCacheFromKeychain(for accountID: String) {
        guard let password = try? passwordFromKeychain(for: accountID)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !password.isEmpty else {
            return
        }
        try? saveCachedPassword(password, for: accountID)
    }

    private func baseQuery(for accountID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
        ]
    }

    private func savePasswordToKeychain(_ password: String, for accountID: String) throws {
        let encodedPassword = Data(password.utf8)
        var query = baseQuery(for: accountID)

        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = encodedPassword

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainSecretStoreError.unhandledStatus(status)
        }
    }

    private func passwordFromKeychain(for accountID: String) throws -> String? {
        var query = baseQuery(for: accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw KeychainSecretStoreError.invalidPayload
            }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainSecretStoreError.unhandledStatus(status)
        }
    }

    private func deletePasswordFromKeychain(for accountID: String) throws {
        let status = SecItemDelete(baseQuery(for: accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainSecretStoreError.unhandledStatus(status)
        }
    }

    private func cachedPassword(for accountID: String) throws -> String? {
        try loadCachedPasswords()[accountID]
    }

    private func saveCachedPassword(_ password: String, for accountID: String) throws {
        var passwords = try loadCachedPasswords()
        passwords[accountID] = password
        try persistCachedPasswords(passwords)
    }

    private func deleteCachedPassword(for accountID: String) throws {
        let cacheURL = try MailroomPaths.mailboxPasswordCacheURL()
        guard fileManager.fileExists(atPath: cacheURL.path) else {
            return
        }

        var passwords = try loadCachedPasswords()
        passwords.removeValue(forKey: accountID)

        if passwords.isEmpty {
            try? fileManager.removeItem(at: cacheURL)
            return
        }

        try persistCachedPasswords(passwords)
    }

    private func loadCachedPasswords() throws -> [String: String] {
        let cacheURL = try MailroomPaths.mailboxPasswordCacheURL()
        guard fileManager.fileExists(atPath: cacheURL.path) else {
            return [:]
        }

        let data = try Data(contentsOf: cacheURL)
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    private func persistCachedPasswords(_ passwords: [String: String]) throws {
        let cacheURL = try MailroomPaths.mailboxPasswordCacheURL()
        let data = try JSONEncoder().encode(passwords)
        try data.write(to: cacheURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
    }
}

enum KeychainSecretStoreError: LocalizedError {
    case invalidPayload
    case unhandledStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return "The stored Keychain entry could not be decoded as a password."
        case .unhandledStatus(let status):
            let fallback = "Keychain returned status \(status)."
            guard let message = SecCopyErrorMessageString(status, nil) as String? else {
                return fallback
            }
            return message
        }
    }
}
