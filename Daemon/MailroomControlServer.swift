import Dispatch
import Foundation
@preconcurrency import Network

enum MailroomControlServerError: LocalizedError {
    case listenerPortUnavailable
    case listenerCancelled
    case startTimedOut
    case invalidToken
    case missingResolveApprovalParameters
    case missingResolveThreadDecisionParameters
    case missingUpsertMailboxAccountParameters
    case missingDeleteMailboxAccountParameters
    case missingUpsertSenderPolicyParameters
    case missingDeleteSenderPolicyParameters
    case missingUpsertManagedProjectParameters
    case missingDeleteManagedProjectParameters

    var errorDescription: String? {
        switch self {
        case .listenerPortUnavailable:
            return "The daemon control listener did not expose a port."
        case .listenerCancelled:
            return "The daemon control listener stopped before it became ready."
        case .startTimedOut:
            return "Timed out while starting the daemon control listener."
        case .invalidToken:
            return "The daemon control token is invalid."
        case .missingResolveApprovalParameters:
            return "The approval/resolve request is missing its parameters."
        case .missingResolveThreadDecisionParameters:
            return "The thread/resolve-decision request is missing its parameters."
        case .missingUpsertMailboxAccountParameters:
            return "The mailbox-account upsert request is missing its parameters."
        case .missingDeleteMailboxAccountParameters:
            return "The mailbox-account delete request is missing its parameters."
        case .missingUpsertSenderPolicyParameters:
            return "The sender-policy upsert request is missing its parameters."
        case .missingDeleteSenderPolicyParameters:
            return "The sender-policy delete request is missing its parameters."
        case .missingUpsertManagedProjectParameters:
            return "The managed-project upsert request is missing its parameters."
        case .missingDeleteManagedProjectParameters:
            return "The managed-project delete request is missing its parameters."
        }
    }
}

final class MailroomControlServer: @unchecked Sendable {
    struct Handlers: Sendable {
        var readState: @Sendable () async throws -> MailroomDaemonStateSnapshot
        var resolveApproval: @Sendable (MailroomDaemonResolveApprovalParams) async throws -> MailroomDaemonStateSnapshot
        var resolveThreadDecision: @Sendable (MailroomDaemonResolveThreadDecisionParams) async throws -> MailroomDaemonStateSnapshot
        var upsertMailboxAccount: @Sendable (MailroomDaemonUpsertMailboxAccountParams) async throws -> MailroomDaemonStateSnapshot
        var deleteMailboxAccount: @Sendable (MailroomDaemonDeleteMailboxAccountParams) async throws -> MailroomDaemonStateSnapshot
        var upsertSenderPolicy: @Sendable (MailroomDaemonUpsertSenderPolicyParams) async throws -> MailroomDaemonStateSnapshot
        var deleteSenderPolicy: @Sendable (MailroomDaemonDeleteSenderPolicyParams) async throws -> MailroomDaemonStateSnapshot
        var upsertManagedProject: @Sendable (MailroomDaemonUpsertManagedProjectParams) async throws -> MailroomDaemonStateSnapshot
        var deleteManagedProject: @Sendable (MailroomDaemonDeleteManagedProjectParams) async throws -> MailroomDaemonStateSnapshot
    }

    private let controlFileURL: URL
    private let handlers: Handlers
    private let queue = DispatchQueue(label: "io.github.patchcourier.control-server")

    private var listener: NWListener?
    private var advertisedControlFile: MailroomDaemonControlFile?
    private var authToken: String?
    private var startupError: Error?

    init(controlFileURL: URL, handlers: Handlers) {
        self.controlFileURL = controlFileURL
        self.handlers = handlers
    }

    func start() async throws -> MailroomDaemonControlFile {
        if let controlFile = queue.sync(execute: { advertisedControlFile }) {
            return controlFile
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)

        let listener = try NWListener(using: parameters)
        let authToken = UUID().uuidString
        let startedAt = Date()

        queue.sync {
            startupError = nil
            self.listener = listener
            self.authToken = authToken
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.handleListenerState(state, listener: listener, authToken: authToken, startedAt: startedAt)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        for _ in 0..<100 {
            if let error = queue.sync(execute: { startupError }) {
                throw error
            }
            if let controlFile = queue.sync(execute: { advertisedControlFile }) {
                return controlFile
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        throw MailroomControlServerError.startTimedOut
    }

    func stop() {
        let listener = queue.sync { () -> NWListener? in
            let currentListener = self.listener
            self.listener = nil
            self.advertisedControlFile = nil
            self.authToken = nil
            self.startupError = nil
            return currentListener
        }
        removeControlFileIfPresent()
        listener?.cancel()
    }

    private func handleListenerState(
        _ state: NWListener.State,
        listener: NWListener,
        authToken: String,
        startedAt: Date
    ) {
        switch state {
        case .ready:
            guard advertisedControlFile == nil else {
                return
            }
            do {
                guard let port = listener.port?.rawValue else {
                    throw MailroomControlServerError.listenerPortUnavailable
                }
                let controlFile = MailroomDaemonControlFile(
                    host: "127.0.0.1",
                    port: port,
                    authToken: authToken,
                    pid: getpid(),
                    startedAt: startedAt
                )
                try writeControlFile(controlFile)
                self.advertisedControlFile = controlFile
                self.startupError = nil
            } catch {
                self.startupError = error
                listener.cancel()
            }

        case .failed(let error):
            self.startupError = error
            self.listener = nil
            self.advertisedControlFile = nil
            self.authToken = nil
            removeControlFileIfPresent()

        case .cancelled:
            if self.startupError == nil && self.advertisedControlFile == nil {
                self.startupError = MailroomControlServerError.listenerCancelled
            }
            self.listener = nil
            self.advertisedControlFile = nil
            self.authToken = nil
            removeControlFileIfPresent()

        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.sendErrorResponse(
                    id: "invalid-request",
                    message: error.localizedDescription,
                    on: connection
                )
                return
            }

            var nextBuffer = buffer
            if let data, !data.isEmpty {
                nextBuffer.append(data)
            }

            if let newlineIndex = nextBuffer.firstIndex(of: 0x0A) {
                let requestLine = nextBuffer.prefix(upTo: newlineIndex)
                let requestData = Data(requestLine)
                Task {
                    let responseData = await self.processRequestData(requestData)
                    self.queue.async {
                        self.send(responseData, on: connection)
                    }
                }
                return
            }

            if isComplete {
                Task {
                    let responseData = await self.processRequestData(nextBuffer)
                    self.queue.async {
                        self.send(responseData, on: connection)
                    }
                }
                return
            }

            self.receiveRequest(on: connection, buffer: nextBuffer)
        }
    }

    private func processRequestData(_ data: Data) async -> Data {
        let response: MailroomDaemonControlResponse
        do {
            let decoder = Self.makeJSONDecoder()
            let request = try decoder.decode(MailroomDaemonControlRequest.self, from: data)
            response = try await handle(request: request)
        } catch {
            response = MailroomDaemonControlResponse(
                id: "invalid-request",
                snapshot: nil,
                error: MailroomDaemonControlError(message: error.localizedDescription)
            )
        }
        return Self.encodeResponse(response)
    }

    private func handle(request: MailroomDaemonControlRequest) async throws -> MailroomDaemonControlResponse {
        let expectedToken = queue.sync(execute: { authToken })
        guard request.token == expectedToken else {
            throw MailroomControlServerError.invalidToken
        }

        let snapshot: MailroomDaemonStateSnapshot
        switch request.method {
        case .readState:
            snapshot = try await handlers.readState()

        case .resolveApproval:
            guard let params = request.resolveApproval else {
                throw MailroomControlServerError.missingResolveApprovalParameters
            }
            snapshot = try await handlers.resolveApproval(params)

        case .resolveThreadDecision:
            guard let params = request.resolveThreadDecision else {
                throw MailroomControlServerError.missingResolveThreadDecisionParameters
            }
            snapshot = try await handlers.resolveThreadDecision(params)

        case .upsertMailboxAccount:
            guard let params = request.upsertMailboxAccount else {
                throw MailroomControlServerError.missingUpsertMailboxAccountParameters
            }
            snapshot = try await handlers.upsertMailboxAccount(params)

        case .deleteMailboxAccount:
            guard let params = request.deleteMailboxAccount else {
                throw MailroomControlServerError.missingDeleteMailboxAccountParameters
            }
            snapshot = try await handlers.deleteMailboxAccount(params)

        case .upsertSenderPolicy:
            guard let params = request.upsertSenderPolicy else {
                throw MailroomControlServerError.missingUpsertSenderPolicyParameters
            }
            snapshot = try await handlers.upsertSenderPolicy(params)

        case .deleteSenderPolicy:
            guard let params = request.deleteSenderPolicy else {
                throw MailroomControlServerError.missingDeleteSenderPolicyParameters
            }
            snapshot = try await handlers.deleteSenderPolicy(params)

        case .upsertManagedProject:
            guard let params = request.upsertManagedProject else {
                throw MailroomControlServerError.missingUpsertManagedProjectParameters
            }
            snapshot = try await handlers.upsertManagedProject(params)

        case .deleteManagedProject:
            guard let params = request.deleteManagedProject else {
                throw MailroomControlServerError.missingDeleteManagedProjectParameters
            }
            snapshot = try await handlers.deleteManagedProject(params)
        }

        return MailroomDaemonControlResponse(
            id: request.id,
            snapshot: snapshot,
            error: nil
        )
    }

    private func send(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendErrorResponse(id: String, message: String, on connection: NWConnection) {
        let response = MailroomDaemonControlResponse(
            id: id,
            snapshot: nil,
            error: MailroomDaemonControlError(message: message)
        )
        send(Self.encodeResponse(response), on: connection)
    }

    private func writeControlFile(_ controlFile: MailroomDaemonControlFile) throws {
        let encoder = Self.makeJSONEncoder()
        let data = try encoder.encode(controlFile)
        try FileManager.default.createDirectory(
            at: controlFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try data.write(to: controlFileURL, options: .atomic)
    }

    private func removeControlFileIfPresent() {
        try? FileManager.default.removeItem(at: controlFileURL)
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

    private static func encodeResponse(_ response: MailroomDaemonControlResponse) -> Data {
        let data = (try? makeJSONEncoder().encode(response)) ?? Data(#"{"id":"invalid-request","error":{"message":"Failed to encode control response."}}"#.utf8)
        var line = data
        line.append(0x0A)
        return line
    }
}
