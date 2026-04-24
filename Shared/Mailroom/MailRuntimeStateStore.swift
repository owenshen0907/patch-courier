import Foundation

struct MailRuntimeStateStore: Sendable {
    let fileURL: URL

    func load() throws -> MailroomRuntimeState {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .empty
        }

        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(MailroomRuntimeState.self, from: data)
    }

    func save(_ state: MailroomRuntimeState) throws {
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
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
