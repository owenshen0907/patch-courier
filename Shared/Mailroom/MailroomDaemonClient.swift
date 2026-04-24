import Dispatch
import Foundation
@preconcurrency import Network

enum MailroomDaemonClientError: LocalizedError {
    case controlFileMissing(String)
    case invalidControlPort(UInt16)
    case connectionClosed
    case missingSnapshot
    case server(String)

    var errorDescription: String? {
        switch self {
        case .controlFileMissing(let path):
            return "No daemon control file exists at \(path). Start mailroomd first."
        case .invalidControlPort(let port):
            return "The daemon control file exposed an invalid port: \(port)."
        case .connectionClosed:
            return "The daemon control connection closed before a response arrived."
        case .missingSnapshot:
            return "The daemon control response did not include a state snapshot."
        case .server(let message):
            return message
        }
    }
}

struct MailroomDaemonClient {
    let controlFile: MailroomDaemonControlFile

    init(controlFileURL: URL? = nil) throws {
        let controlFileURL = try controlFileURL ?? MailroomPaths.daemonControlFileURL()
        guard FileManager.default.fileExists(atPath: controlFileURL.path) else {
            throw MailroomDaemonClientError.controlFileMissing(controlFileURL.path)
        }
        let data = try Data(contentsOf: controlFileURL)
        let decoder = Self.makeJSONDecoder()
        self.controlFile = try decoder.decode(MailroomDaemonControlFile.self, from: data)
    }

    func readState() async throws -> MailroomDaemonStateSnapshot {
        let request = MailroomDaemonControlRequest(
            id: UUID().uuidString,
            token: controlFile.authToken,
            method: .readState,
            stateRead: .default,
            resolveApproval: nil,
            resolveThreadDecision: nil,
            upsertMailboxAccount: nil,
            deleteMailboxAccount: nil,
            upsertSenderPolicy: nil,
            deleteSenderPolicy: nil,
            upsertManagedProject: nil,
            deleteManagedProject: nil
        )
        return try await send(request)
    }

    func resolveApproval(
        approvalID: String,
        decision: String?,
        answers: [String: [String]],
        note: String?
    ) async throws -> MailroomDaemonStateSnapshot {
        let request = MailroomDaemonControlRequest(
            id: UUID().uuidString,
            token: controlFile.authToken,
            method: .resolveApproval,
            stateRead: nil,
            resolveApproval: MailroomDaemonResolveApprovalParams(
                approvalID: approvalID,
                decision: decision,
                answers: answers,
                note: note
            ),
            resolveThreadDecision: nil,
            upsertMailboxAccount: nil,
            deleteMailboxAccount: nil,
            upsertSenderPolicy: nil,
            deleteSenderPolicy: nil,
            upsertManagedProject: nil,
            deleteManagedProject: nil
        )
        return try await send(request)
    }

    func resolveThreadDecision(
        threadToken: String,
        decision: MailroomDaemonThreadDecision,
        task: String?
    ) async throws -> MailroomDaemonStateSnapshot {
        let request = MailroomDaemonControlRequest(
            id: UUID().uuidString,
            token: controlFile.authToken,
            method: .resolveThreadDecision,
            stateRead: nil,
            resolveApproval: nil,
            resolveThreadDecision: MailroomDaemonResolveThreadDecisionParams(
                threadToken: threadToken,
                decision: decision,
                task: task
            ),
            upsertMailboxAccount: nil,
            deleteMailboxAccount: nil,
            upsertSenderPolicy: nil,
            deleteSenderPolicy: nil,
            upsertManagedProject: nil,
            deleteManagedProject: nil
        )
        return try await send(request)
    }

    func upsertMailboxAccount(_ account: MailboxAccount, password: String?) async throws -> MailroomDaemonStateSnapshot {
        let request = MailroomDaemonControlRequest(
            id: UUID().uuidString,
            token: controlFile.authToken,
            method: .upsertMailboxAccount,
            stateRead: nil,
            resolveApproval: nil,
            resolveThreadDecision: nil,
            upsertMailboxAccount: MailroomDaemonUpsertMailboxAccountParams(
                account: account,
                password: password
            ),
            deleteMailboxAccount: nil,
            upsertSenderPolicy: nil,
            deleteSenderPolicy: nil,
            upsertManagedProject: nil,
            deleteManagedProject: nil
        )
        return try await send(request)
    }

    func deleteMailboxAccount(accountID: String) async throws -> MailroomDaemonStateSnapshot {
        let request = MailroomDaemonControlRequest(
            id: UUID().uuidString,
            token: controlFile.authToken,
            method: .deleteMailboxAccount,
            stateRead: nil,
            resolveApproval: nil,
            resolveThreadDecision: nil,
            upsertMailboxAccount: nil,
            deleteMailboxAccount: MailroomDaemonDeleteMailboxAccountParams(accountID: accountID),
            upsertSenderPolicy: nil,
            deleteSenderPolicy: nil,
            upsertManagedProject: nil,
            deleteManagedProject: nil
        )
        return try await send(request)
    }

    func upsertSenderPolicy(_ policy: SenderPolicy) async throws -> MailroomDaemonStateSnapshot {
        let request = MailroomDaemonControlRequest(
            id: UUID().uuidString,
            token: controlFile.authToken,
            method: .upsertSenderPolicy,
            stateRead: nil,
            resolveApproval: nil,
            resolveThreadDecision: nil,
            upsertMailboxAccount: nil,
            deleteMailboxAccount: nil,
            upsertSenderPolicy: MailroomDaemonUpsertSenderPolicyParams(policy: policy),
            deleteSenderPolicy: nil,
            upsertManagedProject: nil,
            deleteManagedProject: nil
        )
        return try await send(request)
    }

    func deleteSenderPolicy(policyID: String) async throws -> MailroomDaemonStateSnapshot {
        let request = MailroomDaemonControlRequest(
            id: UUID().uuidString,
            token: controlFile.authToken,
            method: .deleteSenderPolicy,
            stateRead: nil,
            resolveApproval: nil,
            resolveThreadDecision: nil,
            upsertMailboxAccount: nil,
            deleteMailboxAccount: nil,
            upsertSenderPolicy: nil,
            deleteSenderPolicy: MailroomDaemonDeleteSenderPolicyParams(policyID: policyID),
            upsertManagedProject: nil,
            deleteManagedProject: nil
        )
        return try await send(request)
    }

    func upsertManagedProject(_ project: ManagedProject) async throws -> MailroomDaemonStateSnapshot {
        let request = MailroomDaemonControlRequest(
            id: UUID().uuidString,
            token: controlFile.authToken,
            method: .upsertManagedProject,
            stateRead: nil,
            resolveApproval: nil,
            resolveThreadDecision: nil,
            upsertMailboxAccount: nil,
            deleteMailboxAccount: nil,
            upsertSenderPolicy: nil,
            deleteSenderPolicy: nil,
            upsertManagedProject: MailroomDaemonUpsertManagedProjectParams(project: project),
            deleteManagedProject: nil
        )
        return try await send(request)
    }

    func deleteManagedProject(projectID: String) async throws -> MailroomDaemonStateSnapshot {
        let request = MailroomDaemonControlRequest(
            id: UUID().uuidString,
            token: controlFile.authToken,
            method: .deleteManagedProject,
            stateRead: nil,
            resolveApproval: nil,
            resolveThreadDecision: nil,
            upsertMailboxAccount: nil,
            deleteMailboxAccount: nil,
            upsertSenderPolicy: nil,
            deleteSenderPolicy: nil,
            upsertManagedProject: nil,
            deleteManagedProject: MailroomDaemonDeleteManagedProjectParams(projectID: projectID)
        )
        return try await send(request)
    }

    private func send(_ request: MailroomDaemonControlRequest) async throws -> MailroomDaemonStateSnapshot {
        guard let port = NWEndpoint.Port(rawValue: controlFile.port) else {
            throw MailroomDaemonClientError.invalidControlPort(controlFile.port)
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(controlFile.host),
            port: port,
            using: .tcp
        )
        let queue = DispatchQueue(label: "io.github.patchcourier.control-client.\(request.id)")

        do {
            try await connect(connection, on: queue)
            try await sendRequest(request, over: connection)
            let responseData = try await receiveResponse(over: connection)
            connection.cancel()

            let response = try Self.makeJSONDecoder().decode(MailroomDaemonControlResponse.self, from: responseData)
            if let error = response.error {
                throw MailroomDaemonClientError.server(error.message)
            }
            guard let snapshot = response.snapshot else {
                throw MailroomDaemonClientError.missingSnapshot
            }
            return snapshot
        } catch {
            connection.cancel()
            throw error
        }
    }

    private func connect(_ connection: NWConnection, on queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: MailroomDaemonClientError.connectionClosed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func sendRequest(_ request: MailroomDaemonControlRequest, over connection: NWConnection) async throws {
        var requestData = try Self.makeJSONEncoder().encode(request)
        requestData.append(0x0A)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: requestData, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveResponse(over connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            @Sendable func receiveChunk(buffer: Data) {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }

                    var nextBuffer = buffer
                    if let data, !data.isEmpty {
                        nextBuffer.append(data)
                    }

                    if let newlineIndex = nextBuffer.firstIndex(of: 0x0A) {
                        continuation.resume(returning: Data(nextBuffer.prefix(upTo: newlineIndex)))
                        return
                    }

                    if isComplete {
                        if nextBuffer.isEmpty {
                            continuation.resume(throwing: MailroomDaemonClientError.connectionClosed)
                        } else {
                            continuation.resume(returning: nextBuffer)
                        }
                        return
                    }

                    receiveChunk(buffer: nextBuffer)
                }
            }

            receiveChunk(buffer: Data())
        }
    }

    private static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
