import Foundation

struct MailboxAccountStore {
    let accountsURL: URL

    func load() throws -> [MailboxAccount] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: accountsURL.path) else {
            return []
        }

        let data = try Data(contentsOf: accountsURL)
        return try decoder.decode([MailboxAccount].self, from: data)
    }

    func save(_ accounts: [MailboxAccount]) throws {
        let sortedAccounts = accounts.sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
        let data = try encoder.encode(sortedAccounts)
        try data.write(to: accountsURL, options: .atomic)
    }

    func upsert(_ account: MailboxAccount) throws {
        var accounts = try load()
        if let existingIndex = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[existingIndex] = account
        } else {
            accounts.append(account)
        }
        try save(accounts)
    }

    func delete(accountID: String) throws {
        let accounts = try load().filter { $0.id != accountID }
        try save(accounts)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
