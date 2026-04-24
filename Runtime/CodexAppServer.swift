import Foundation

enum JSONValue: Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

extension JSONValue {
    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    func decoded<T: Decodable>(as type: T.Type, using decoder: JSONDecoder = JSONDecoder()) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try decoder.decode(T.self, from: data)
    }

    func prettyPrinted() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
              let string = String(data: prettyData, encoding: .utf8) else {
            return String(describing: self)
        }
        return string
    }
}

enum JSONRPCID: Hashable, Codable, Sendable, CustomStringConvertible {
    case string(String)
    case integer(Int64)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .integer(try container.decode(Int64.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        }
    }

    var description: String {
        switch self {
        case .string(let value): return value
        case .integer(let value): return String(value)
        }
    }
}

extension JSONRPCID {
    var persistedKind: String {
        switch self {
        case .string:
            return "string"
        case .integer:
            return "integer"
        }
    }

    var persistedValue: String {
        switch self {
        case .string(let value):
            return value
        case .integer(let value):
            return String(value)
        }
    }

    static func persisted(kind: String, value: String) -> JSONRPCID {
        switch kind {
        case "integer":
            return Int64(value).map(JSONRPCID.integer) ?? .string(value)
        default:
            return .string(value)
        }
    }
}

struct JSONRPCRequest<Params: Encodable & Sendable>: Encodable, Sendable {
    var id: JSONRPCID
    var method: String
    var params: Params
}

struct JSONRPCNotification<Params: Encodable & Sendable>: Encodable, Sendable {
    var method: String
    var params: Params
}

private struct JSONRPCSuccessResponse<Result: Encodable & Sendable>: Encodable, Sendable {
    var id: JSONRPCID
    var result: Result
}

private struct EmptyParams: Encodable, Sendable {}

struct JSONRPCErrorPayload: Decodable, Error, Hashable, Sendable {
    var code: Int
    var message: String
    var data: JSONValue?
}

struct RawJSONRPCMessage: Decodable, Sendable {
    var id: JSONRPCID?
    var method: String?
    var params: JSONValue?
    var result: JSONValue?
    var error: JSONRPCErrorPayload?
    var timestamp: String?
    var level: String?
    var fields: JSONValue?
    var target: String?

    var isStructuredLog: Bool {
        timestamp != nil && level != nil && !isJSONRPC
    }

    var isJSONRPC: Bool {
        method != nil || result != nil || error != nil
    }
}

enum CodexApprovalPolicy: String, Codable, Sendable {
    case untrusted
    case onFailure = "on-failure"
    case onRequest = "on-request"
    case never
}

enum CodexSandboxMode: String, Codable, Sendable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
    case dangerFullAccess = "danger-full-access"
}

enum CodexApprovalsReviewer: String, Codable, Sendable {
    case user
    case guardianSubagent = "guardian_subagent"
}

struct ClientInfo: Codable, Hashable, Sendable {
    var name: String
    var version: String
    var title: String?
}

struct InitializeCapabilities: Codable, Hashable, Sendable {
    var experimentalApi: Bool
    var optOutNotificationMethods: [String]?
}

struct InitializeParams: Codable, Hashable, Sendable {
    var clientInfo: ClientInfo
    var capabilities: InitializeCapabilities?
}

struct InitializeResponse: Codable, Hashable, Sendable {
    var userAgent: String
    var codexHome: String
    var platformFamily: String
    var platformOs: String
}

struct CodexThreadDescriptor: Codable, Hashable, Sendable {
    var id: String
    var name: String?
    var preview: String
    var cwd: String
    var path: String?
    var source: String?
    var status: JSONValue
    var turns: [CodexTurnDescriptor]?
    var modelProvider: String?
    var cliVersion: String?
    var ephemeral: Bool?
    var createdAt: Int?
    var updatedAt: Int?
}

struct CodexTurnDescriptor: Codable, Hashable, Sendable {
    var id: String
    var status: JSONValue
    var startedAt: Int?
    var completedAt: Int?
    var items: [JSONValue]
    var error: JSONValue?
    var durationMs: Int?
}

struct CodexThreadStartParams: Codable, Hashable, Sendable {
    var cwd: String
    var approvalPolicy: CodexApprovalPolicy
    var approvalsReviewer: CodexApprovalsReviewer?
    var sandbox: CodexSandboxMode
    var model: String
    var baseInstructions: String?
    var developerInstructions: String?
    var ephemeral: Bool?
}

struct CodexThreadStartResponse: Codable, Hashable, Sendable {
    var thread: CodexThreadDescriptor
    var model: String
    var modelProvider: String
    var cwd: String
    var approvalPolicy: JSONValue
    var approvalsReviewer: String
    var sandbox: JSONValue
}

struct CodexTurnInputItem: Codable, Hashable, Sendable {
    var type: String
    var text: String

    static func text(_ text: String) -> CodexTurnInputItem {
        CodexTurnInputItem(type: "text", text: text)
    }
}

struct CodexTurnStartParams: Codable, Hashable, Sendable {
    var threadId: String
    var input: [CodexTurnInputItem]
    var cwd: String?
    var model: String?
}

struct CodexTurnStartResponse: Codable, Hashable, Sendable {
    var turn: CodexTurnDescriptor
}

struct CodexThreadReadParams: Codable, Hashable, Sendable {
    var threadId: String
    var includeTurns: Bool
}

struct CodexThreadReadResponse: Codable, Hashable, Sendable {
    var thread: CodexThreadDescriptor
}

struct CodexTurnCompletedNotification: Codable, Hashable, Sendable {
    var threadId: String
    var turn: CodexTurnDescriptor
}

struct CodexThreadStatusChangedNotification: Codable, Hashable, Sendable {
    var threadId: String
    var status: JSONValue
}

struct CodexItemCompletedNotification: Codable, Hashable, Sendable {
    var threadId: String
    var turnId: String
    var item: JSONValue
}

struct CommandExecutionRequestApprovalParams: Codable, Hashable, Sendable {
    var threadId: String
    var turnId: String
    var itemId: String
    var approvalId: String?
    var command: String?
    var cwd: String?
    var reason: String?
    var availableDecisions: [JSONValue]?
}

struct FileChangeRequestApprovalParams: Codable, Hashable, Sendable {
    var threadId: String
    var turnId: String
    var itemId: String
    var reason: String?
    var grantRoot: String?
}

struct ToolRequestUserInputOption: Codable, Hashable, Sendable {
    var label: String
    var description: String
}

struct ToolRequestUserInputQuestion: Codable, Hashable, Sendable {
    var header: String
    var id: String
    var question: String
    var isOther: Bool?
    var isSecret: Bool?
    var options: [ToolRequestUserInputOption]?
}

struct ToolRequestUserInputParams: Codable, Hashable, Sendable {
    var threadId: String
    var turnId: String
    var itemId: String
    var questions: [ToolRequestUserInputQuestion]
}

struct CommandExecutionRequestApprovalResponse: Encodable, Sendable {
    var decision: JSONValue

    static func accept() -> Self { Self(decision: .string("accept")) }
    static func acceptForSession() -> Self { Self(decision: .string("acceptForSession")) }
    static func decline() -> Self { Self(decision: .string("decline")) }
    static func cancel() -> Self { Self(decision: .string("cancel")) }
}

struct FileChangeRequestApprovalResponse: Encodable, Sendable {
    var decision: String
}

struct ToolRequestUserInputResponse: Encodable, Sendable {
    struct Answer: Encodable, Sendable {
        var answers: [String]
    }

    var answers: [String: Answer]
}

enum CodexServerRequest: Sendable {
    case commandApproval(id: JSONRPCID, params: CommandExecutionRequestApprovalParams)
    case fileChangeApproval(id: JSONRPCID, params: FileChangeRequestApprovalParams)
    case toolRequestUserInput(id: JSONRPCID, params: ToolRequestUserInputParams)
    case other(id: JSONRPCID, method: String, params: JSONValue?)
}

enum CodexAppServerEvent: Sendable {
    case request(CodexServerRequest)
    case notification(method: String, params: JSONValue?)
    case log(level: String, target: String?, payload: JSONValue?)
}

enum CodexAppServerError: Error, LocalizedError, Sendable {
    case executableNotFound([String])
    case transportUnavailable
    case server(JSONRPCErrorPayload)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let candidates):
            return "Could not find the Codex executable. Tried: \(candidates.joined(separator: ", "))"
        case .transportUnavailable:
            return "Codex App Server transport is not running."
        case .server(let payload):
            return payload.message
        }
    }
}

final class CodexAppServerTransport {
    struct Configuration: Sendable {
        var executableCandidates: [String]
        var codexHome: String
        var bootstrapSourceHome: String?
        var workingDirectory: String
        var additionalEnvironment: [String: String]
    }

    nonisolated let messages: AsyncStream<RawJSONRPCMessage>

    private let configuration: Configuration
    private let messageContinuation: AsyncStream<RawJSONRPCMessage>.Continuation
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutTask: Task<Void, Never>?

    init(configuration: Configuration) {
        self.configuration = configuration

        var continuation: AsyncStream<RawJSONRPCMessage>.Continuation?
        self.messages = AsyncStream<RawJSONRPCMessage> { continuation = $0 }
        self.messageContinuation = continuation!
    }

    func start() throws {
        guard process == nil else { return }

        let executableURL = try resolveExecutableURL()
        let bootstrap = try CodexProfileBootstrapper.prepare(configuration: .init(
            sourceHome: configuration.bootstrapSourceHome,
            destinationHome: configuration.codexHome
        ))

        let stdoutPipe = Pipe()
        let stdinPipe = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = URL(fileURLWithPath: configuration.workingDirectory, isDirectory: true)
        process.standardOutput = stdoutPipe
        process.standardError = stdoutPipe
        process.standardInput = stdinPipe

        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = configuration.codexHome
        for (key, value) in bootstrap.loadedEnvironment {
            environment[key] = value
        }
        for (key, value) in configuration.additionalEnvironment {
            environment[key] = value
        }
        process.environment = environment

        try process.run()
        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting

        let outputHandle = stdoutPipe.fileHandleForReading
        stdoutTask = Task { [continuation = messageContinuation] in
            let decoder = JSONDecoder()
            do {
                for try await line in outputHandle.bytes.lines {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    guard let data = trimmed.data(using: .utf8),
                          let message = try? decoder.decode(RawJSONRPCMessage.self, from: data) else {
                        continue
                    }
                    continuation.yield(message)
                }
            } catch {
                continuation.finish()
            }
            continuation.finish()
        }
    }

    func stop() {
        stdoutTask?.cancel()
        stdoutTask = nil
        try? stdinHandle?.close()
        stdinHandle = nil
        process?.terminate()
        process = nil
        messageContinuation.finish()
    }

    func send<Request: Encodable>(_ request: Request) throws {
        guard let stdinHandle else { throw CodexAppServerError.transportUnavailable }
        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        try stdinHandle.write(contentsOf: payload)
    }

    private func resolveExecutableURL() throws -> URL {
        let fileManager = FileManager.default
        if let candidate = configuration.executableCandidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: candidate)
        }
        throw CodexAppServerError.executableNotFound(configuration.executableCandidates)
    }
}

actor CodexAppServerClient {
    nonisolated let events: AsyncStream<CodexAppServerEvent>

    private let transport: CodexAppServerTransport
    private let clientInfo: ClientInfo
    private let eventContinuation: AsyncStream<CodexAppServerEvent>.Continuation
    private var readLoopTask: Task<Void, Never>?
    private var nextRequestID: Int64 = 1
    private var pendingResponses: [String: CheckedContinuation<JSONValue, Error>] = [:]

    init(transport: CodexAppServerTransport, clientInfo: ClientInfo) {
        self.transport = transport
        self.clientInfo = clientInfo

        var continuation: AsyncStream<CodexAppServerEvent>.Continuation?
        self.events = AsyncStream<CodexAppServerEvent> { continuation = $0 }
        self.eventContinuation = continuation!
    }

    func start() async throws -> InitializeResponse {
        try transport.start()
        if readLoopTask == nil {
            readLoopTask = Task { [self] in await consumeMessages() }
        }

        let params = InitializeParams(
            clientInfo: clientInfo,
            capabilities: InitializeCapabilities(experimentalApi: true, optOutNotificationMethods: nil)
        )
        let response: InitializeResponse = try await sendRequest(method: "initialize", params: params)
        try transport.send(JSONRPCNotification(method: "initialized", params: EmptyParams()))
        return response
    }

    func stop() async {
        readLoopTask?.cancel()
        readLoopTask = nil
        transport.stop()
        eventContinuation.finish()
    }

    func startThread(params: CodexThreadStartParams) async throws -> CodexThreadStartResponse {
        try await sendRequest(method: "thread/start", params: params)
    }

    func readThread(threadID: String, includeTurns: Bool = false) async throws -> CodexThreadReadResponse {
        let params = CodexThreadReadParams(threadId: threadID, includeTurns: includeTurns)
        return try await sendRequest(method: "thread/read", params: params)
    }

    func startTurn(threadID: String, prompt: String, cwd: String? = nil, model: String? = nil) async throws -> CodexTurnStartResponse {
        let params = CodexTurnStartParams(threadId: threadID, input: [.text(prompt)], cwd: cwd, model: model)
        return try await sendRequest(method: "turn/start", params: params)
    }

    func respond<Result: Encodable & Sendable>(to requestID: JSONRPCID, result: Result) async throws {
        try transport.send(JSONRPCSuccessResponse(id: requestID, result: result))
    }

    func respond(to requestID: JSONRPCID, commandDecision: CommandExecutionRequestApprovalResponse) async throws {
        try await respond(to: requestID, result: commandDecision)
    }

    func respond(to requestID: JSONRPCID, fileDecision: FileChangeRequestApprovalResponse) async throws {
        try await respond(to: requestID, result: fileDecision)
    }

    func respond(to requestID: JSONRPCID, userInput: ToolRequestUserInputResponse) async throws {
        try await respond(to: requestID, result: userInput)
    }

    private func consumeMessages() async {
        for await message in transport.messages {
            if message.isStructuredLog {
                eventContinuation.yield(.log(level: message.level ?? "info", target: message.target, payload: message.fields))
                continue
            }

            if let id = message.id, let result = message.result {
                pendingResponses.removeValue(forKey: id.description)?.resume(returning: result)
                continue
            }

            if let id = message.id, let error = message.error {
                pendingResponses.removeValue(forKey: id.description)?.resume(throwing: CodexAppServerError.server(error))
                continue
            }

            if let id = message.id, let method = message.method {
                do {
                    eventContinuation.yield(.request(try mapServerRequest(id: id, method: method, params: message.params)))
                } catch {
                    eventContinuation.yield(.log(level: "error", target: "mailroomd", payload: .string(error.localizedDescription)))
                }
                continue
            }

            if let method = message.method {
                eventContinuation.yield(.notification(method: method, params: message.params))
            }
        }
    }

    private func mapServerRequest(id: JSONRPCID, method: String, params: JSONValue?) throws -> CodexServerRequest {
        let payload = params ?? .object([:])
        switch method {
        case "item/commandExecution/requestApproval":
            return .commandApproval(id: id, params: try payload.decoded(as: CommandExecutionRequestApprovalParams.self))
        case "item/fileChange/requestApproval":
            return .fileChangeApproval(id: id, params: try payload.decoded(as: FileChangeRequestApprovalParams.self))
        case "item/tool/requestUserInput":
            return .toolRequestUserInput(id: id, params: try payload.decoded(as: ToolRequestUserInputParams.self))
        default:
            return .other(id: id, method: method, params: params)
        }
    }

    private func sendRequest<Params: Encodable & Sendable, Result: Decodable>(method: String, params: Params) async throws -> Result {
        let id = JSONRPCID.integer(nextRequestID)
        nextRequestID += 1

        let rawResult: JSONValue = try await withCheckedThrowingContinuation { continuation in
            pendingResponses[id.description] = continuation
            do {
                try transport.send(JSONRPCRequest(id: id, method: method, params: params))
            } catch {
                pendingResponses.removeValue(forKey: id.description)
                continuation.resume(throwing: error)
            }
        }

        return try rawResult.decoded(as: Result.self)
    }
}
