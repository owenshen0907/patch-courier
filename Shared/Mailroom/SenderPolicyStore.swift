import Foundation

struct SenderPolicyStore {
    let fileURL: URL

    func load() throws -> [SenderPolicy] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([SenderPolicy].self, from: data)
    }

    func save(_ policies: [SenderPolicy]) throws {
        let sortedPolicies = policies.sorted {
            $0.senderAddress.localizedCaseInsensitiveCompare($1.senderAddress) == .orderedAscending
        }
        let data = try encoder.encode(sortedPolicies)
        try data.write(to: fileURL, options: .atomic)
    }

    func upsert(_ policy: SenderPolicy) throws {
        var policies = try load()
        if let existingIndex = policies.firstIndex(where: { $0.id == policy.id }) {
            policies[existingIndex] = policy
        } else {
            policies.append(policy)
        }
        try save(policies)
    }

    func delete(policyID: String) throws {
        try save(load().filter { $0.id != policyID })
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
