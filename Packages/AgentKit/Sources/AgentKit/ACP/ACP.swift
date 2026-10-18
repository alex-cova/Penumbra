import Foundation

// MARK: - JSONValue helpers for the ACP decoders

extension JSONValue {
    func bool(_ key: String, default fallback: Bool = false) -> Bool { self[key]?.boolValue ?? fallback }
    func string(_ key: String) -> String? { self[key]?.stringValue }
    func int(_ key: String) -> Int? { self[key]?.intValue }
    var meta: JSONValue? { self["_meta"] }
    static func metaObject(_ meta: JSONValue?) -> (String, JSONValue)? {
        guard let meta, meta != .null else { return nil }
        return ("_meta", meta)
    }
}

func acpObject(_ pairs: [(String, JSONValue?)]) -> JSONValue {
    var object: [String: JSONValue] = [:]
    for (key, value) in pairs { if let value { object[key] = value } }
    return .object(object)
}

// MARK: - Initialization

public let acpProtocolVersion = 1

public struct ACPImplementation: Sendable, Equatable {
    public var name: String
    public var title: String?
    public var version: String
    public init(name: String, title: String? = nil, version: String) {
        self.name = name; self.title = title; self.version = version
    }
    public var jsonValue: JSONValue {
        acpObject([("name", .string(name)), ("title", title.map(JSONValue.string)), ("version", .string(version))])
    }
    public init?(jsonValue: JSONValue) {
        guard let name = jsonValue.string("name"), let version = jsonValue.string("version") else { return nil }
        self.name = name; self.title = jsonValue.string("title"); self.version = version
    }
}

public struct ACPFileSystemCapabilities: Sendable, Equatable {
    public var readTextFile: Bool
    public var writeTextFile: Bool
    public init(readTextFile: Bool = false, writeTextFile: Bool = false) {
        self.readTextFile = readTextFile; self.writeTextFile = writeTextFile
    }
    public var jsonValue: JSONValue {
        .object(["readTextFile": .bool(readTextFile), "writeTextFile": .bool(writeTextFile)])
    }
    public init(jsonValue: JSONValue?) {
        readTextFile = jsonValue?.bool("readTextFile") ?? false
        writeTextFile = jsonValue?.bool("writeTextFile") ?? false
    }
}

public struct ACPClientCapabilities: Sendable, Equatable {
    public var fs: ACPFileSystemCapabilities
    public var terminal: Bool
    /// Whether the client renders form elicitation (`elicitation/create`).
    public var elicitationForm: Bool
    public var meta: JSONValue?
    public init(fs: ACPFileSystemCapabilities = .init(), terminal: Bool = false, elicitationForm: Bool = false, meta: JSONValue? = nil) {
        self.fs = fs; self.terminal = terminal; self.elicitationForm = elicitationForm; self.meta = meta
    }
    public var jsonValue: JSONValue {
        acpObject([
            ("fs", fs.jsonValue), ("terminal", .bool(terminal)),
            ("elicitation", elicitationForm ? .object(["form": .object([:])]) : nil),
            ("_meta", meta),
        ])
    }
    public init(jsonValue: JSONValue?) {
        fs = ACPFileSystemCapabilities(jsonValue: jsonValue?["fs"])
        terminal = jsonValue?.bool("terminal") ?? false
        elicitationForm = jsonValue?["elicitation"]?["form"] != nil && jsonValue?["elicitation"]?["form"] != .null
        meta = jsonValue?.meta
    }
}

public struct ACPPromptCapabilities: Sendable, Equatable {
    public var image: Bool
    public var audio: Bool
    public var embeddedContext: Bool
    public init(image: Bool = false, audio: Bool = false, embeddedContext: Bool = false) {
        self.image = image; self.audio = audio; self.embeddedContext = embeddedContext
    }
    public init(jsonValue: JSONValue?) {
        image = jsonValue?.bool("image") ?? false
        audio = jsonValue?.bool("audio") ?? false
        embeddedContext = jsonValue?.bool("embeddedContext") ?? false
    }
    public var jsonValue: JSONValue {
        .object(["image": .bool(image), "audio": .bool(audio), "embeddedContext": .bool(embeddedContext)])
    }
}

public struct ACPAgentCapabilities: Sendable, Equatable {
    public var loadSession: Bool
    public var promptCapabilities: ACPPromptCapabilities
    /// Raw `sessionCapabilities` object, preserved for forward compatibility.
    public var sessionCapabilities: JSONValue?
    /// Raw `mcpCapabilities` object.
    public var mcpCapabilities: JSONValue?
    public var raw: JSONValue?
    public init(loadSession: Bool = false, promptCapabilities: ACPPromptCapabilities = .init(),
                sessionCapabilities: JSONValue? = nil, mcpCapabilities: JSONValue? = nil, raw: JSONValue? = nil) {
        self.loadSession = loadSession; self.promptCapabilities = promptCapabilities
        self.sessionCapabilities = sessionCapabilities; self.mcpCapabilities = mcpCapabilities; self.raw = raw
    }
    public init(jsonValue: JSONValue?) {
        loadSession = jsonValue?.bool("loadSession") ?? false
        promptCapabilities = ACPPromptCapabilities(jsonValue: jsonValue?["promptCapabilities"])
        sessionCapabilities = jsonValue?["sessionCapabilities"]
        mcpCapabilities = jsonValue?["mcpCapabilities"]
        raw = jsonValue
    }
    public var supportsResume: Bool { sessionCapabilities?["resume"] != nil && sessionCapabilities?["resume"] != .null }
    public var supportsClose: Bool { sessionCapabilities?["close"] != nil && sessionCapabilities?["close"] != .null }
}

public struct ACPAuthMethod: Sendable, Equatable {
    public var id: String
    public var name: String
    public var description: String?
    /// Raw `type` discriminator (`agent`, `terminal`, or a future value).
    public var type: String?
    public var raw: JSONValue
    public init(jsonValue: JSONValue) {
        id = jsonValue.string("id") ?? ""
        name = jsonValue.string("name") ?? id
        description = jsonValue.string("description")
        type = jsonValue.string("type")
        raw = jsonValue
    }
}

public struct ACPInitializeRequest: Sendable, Equatable {
    public var protocolVersion: Int
    public var clientCapabilities: ACPClientCapabilities
    public var clientInfo: ACPImplementation?
    public var meta: JSONValue?
    public init(protocolVersion: Int = acpProtocolVersion, clientCapabilities: ACPClientCapabilities,
                clientInfo: ACPImplementation? = nil, meta: JSONValue? = nil) {
        self.protocolVersion = protocolVersion; self.clientCapabilities = clientCapabilities
        self.clientInfo = clientInfo; self.meta = meta
    }
    public var jsonValue: JSONValue {
        acpObject([("protocolVersion", .int(protocolVersion)), ("clientCapabilities", clientCapabilities.jsonValue),
                   ("clientInfo", clientInfo?.jsonValue), ("_meta", meta)])
    }
    public init(jsonValue: JSONValue) {
        protocolVersion = jsonValue.int("protocolVersion") ?? 0
        clientCapabilities = ACPClientCapabilities(jsonValue: jsonValue["clientCapabilities"])
        clientInfo = jsonValue["clientInfo"].flatMap(ACPImplementation.init(jsonValue:))
        meta = jsonValue.meta
    }
}

public struct ACPInitializeResponse: Sendable, Equatable {
    public var protocolVersion: Int
    public var agentCapabilities: ACPAgentCapabilities
    public var agentInfo: ACPImplementation?
    public var authMethods: [ACPAuthMethod]
    public var meta: JSONValue?
    public init(protocolVersion: Int, agentCapabilities: ACPAgentCapabilities = .init(),
                agentInfo: ACPImplementation? = nil, authMethods: [ACPAuthMethod] = [], meta: JSONValue? = nil) {
        self.protocolVersion = protocolVersion; self.agentCapabilities = agentCapabilities
        self.agentInfo = agentInfo; self.authMethods = authMethods; self.meta = meta
    }
    public init(jsonValue: JSONValue) throws {
        guard let version = jsonValue.int("protocolVersion") else {
            throw ACPError.malformedFrame("initialize response missing protocolVersion")
        }
        protocolVersion = version
        agentCapabilities = ACPAgentCapabilities(jsonValue: jsonValue["agentCapabilities"])
        agentInfo = jsonValue["agentInfo"].flatMap(ACPImplementation.init(jsonValue:))
        authMethods = (jsonValue["authMethods"]?.arrayValue ?? []).map(ACPAuthMethod.init(jsonValue:))
        meta = jsonValue.meta
    }
    public var jsonValue: JSONValue {
        acpObject([("protocolVersion", .int(protocolVersion)), ("agentCapabilities", agentCapabilities.raw),
                   ("agentInfo", agentInfo?.jsonValue),
                   ("authMethods", .array(authMethods.map(\.raw))), ("_meta", meta)])
    }
}

// MARK: - Content blocks

public enum ACPContentBlock: Sendable, Equatable {
    case text(String)
    case image(data: String, mimeType: String)
    case audio(data: String, mimeType: String)
    case resourceLink(name: String, uri: String)
    case resourceText(uri: String, text: String, mimeType: String?)
    case resourceBlob(uri: String, blob: String, mimeType: String?)
    /// A variant this build does not model; the raw value is preserved.
    case unknown(JSONValue)

    public var textValue: String? {
        switch self {
        case .text(let text): text
        case .resourceText(_, let text, _): text
        case .resourceLink(let name, let uri): "[\(name)](\(uri))"
        default: nil
        }
    }

    public var jsonValue: JSONValue {
        switch self {
        case .text(let text): .object(["type": "text", "text": .string(text)])
        case .image(let data, let mime): .object(["type": "image", "data": .string(data), "mimeType": .string(mime)])
        case .audio(let data, let mime): .object(["type": "audio", "data": .string(data), "mimeType": .string(mime)])
        case .resourceLink(let name, let uri): .object(["type": "resource_link", "name": .string(name), "uri": .string(uri)])
        case .resourceText(let uri, let text, let mime):
            acpObject([("type", "resource"),
                       ("resource", acpObject([("uri", .string(uri)), ("text", .string(text)), ("mimeType", mime.map(JSONValue.string))]))])
        case .resourceBlob(let uri, let blob, let mime):
            acpObject([("type", "resource"),
                       ("resource", acpObject([("uri", .string(uri)), ("blob", .string(blob)), ("mimeType", mime.map(JSONValue.string))]))])
        case .unknown(let raw): raw
        }
    }

    public init(jsonValue: JSONValue) {
        switch jsonValue.string("type") {
        case "text": self = .text(jsonValue.string("text") ?? "")
        case "image": self = .image(data: jsonValue.string("data") ?? "", mimeType: jsonValue.string("mimeType") ?? "")
        case "audio": self = .audio(data: jsonValue.string("data") ?? "", mimeType: jsonValue.string("mimeType") ?? "")
        case "resource_link":
            self = .resourceLink(name: jsonValue.string("name") ?? "", uri: jsonValue.string("uri") ?? "")
        case "resource":
            let resource = jsonValue["resource"] ?? .null
            if let text = resource.string("text") {
                self = .resourceText(uri: resource.string("uri") ?? "", text: text, mimeType: resource.string("mimeType"))
            } else {
                self = .resourceBlob(uri: resource.string("uri") ?? "", blob: resource.string("blob") ?? "", mimeType: resource.string("mimeType"))
            }
        default: self = .unknown(jsonValue)
        }
    }

    public static func textBlocks(for prompt: String) -> [ACPContentBlock] { [.text(prompt)] }
}

// MARK: - Sessions

public struct ACPSessionMode: Sendable, Equatable {
    public var id: String
    public var name: String
    public var description: String?
    public init(id: String, name: String, description: String? = nil) {
        self.id = id; self.name = name; self.description = description
    }
    public init(jsonValue: JSONValue) {
        id = jsonValue.string("id") ?? ""
        name = jsonValue.string("name") ?? id
        description = jsonValue.string("description")
    }
    public var jsonValue: JSONValue {
        acpObject([("id", .string(id)), ("name", .string(name)), ("description", description.map(JSONValue.string))])
    }
}

public struct ACPSessionModeState: Sendable, Equatable {
    public var currentModeId: String
    public var availableModes: [ACPSessionMode]
    public init(currentModeId: String, availableModes: [ACPSessionMode]) {
        self.currentModeId = currentModeId; self.availableModes = availableModes
    }
    public init?(jsonValue: JSONValue?) {
        guard let jsonValue, let current = jsonValue.string("currentModeId") else { return nil }
        currentModeId = current
        availableModes = (jsonValue["availableModes"]?.arrayValue ?? []).map(ACPSessionMode.init(jsonValue:))
    }
    public var jsonValue: JSONValue {
        .object(["currentModeId": .string(currentModeId), "availableModes": .array(availableModes.map(\.jsonValue))])
    }
}

/// One agent-advertised config option, kept largely raw: full config UI is a non-goal (plan step 6).
public struct ACPConfigOption: Sendable, Equatable {
    public var id: String
    public var name: String
    public var description: String?
    public var type: String?
    public var raw: JSONValue
    public init(jsonValue: JSONValue) {
        id = jsonValue.string("id") ?? ""
        name = jsonValue.string("name") ?? id
        description = jsonValue.string("description")
        type = jsonValue.string("type")
        raw = jsonValue
    }
    /// Current value as display text, when the option carries one.
    public var currentValueDescription: String? {
        if let value = raw["currentValue"] {
            switch value {
            case .string(let text): return text
            case .bool(let flag): return flag ? "on" : "off"
            case .int(let number): return String(number)
            default: return nil
            }
        }
        return nil
    }
}

public struct ACPNewSessionResponse: Sendable, Equatable {
    public var sessionId: String
    public var modes: ACPSessionModeState?
    public var configOptions: [ACPConfigOption]
    public init(jsonValue: JSONValue) throws {
        guard let id = jsonValue.string("sessionId") else { throw ACPError.malformedFrame("session/new response missing sessionId") }
        sessionId = id
        modes = ACPSessionModeState(jsonValue: jsonValue["modes"])
        configOptions = (jsonValue["configOptions"]?.arrayValue ?? []).map(ACPConfigOption.init(jsonValue:))
    }
}

public enum ACPStopReason: String, Sendable, Equatable {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal
    case cancelled
    case unknown

    public init(raw: String?) {
        self = raw.flatMap(ACPStopReason.init(rawValue:)) ?? .unknown
    }

    public var runEnding: RunEnding {
        switch self {
        case .endTurn, .unknown: .completed
        case .maxTokens: .lengthLimit
        case .maxTurnRequests: .iterationCap
        case .refusal: .contentFiltered
        case .cancelled: .stopped
        }
    }
}

// MARK: - Tool calls

public enum ACPToolKind: String, Sendable, Equatable {
    case read, edit, delete, move, search, execute, think, fetch, switchMode = "switch_mode", other
    public init(raw: String?) { self = raw.flatMap(ACPToolKind.init(rawValue:)) ?? .other }
}

public enum ACPToolCallStatus: String, Sendable, Equatable {
    case pending, inProgress = "in_progress", completed, failed
    public init(raw: String?) { self = raw.flatMap(ACPToolCallStatus.init(rawValue:)) ?? .pending }
}

public enum ACPToolCallContent: Sendable, Equatable {
    case content(ACPContentBlock)
    case diff(path: String, oldText: String?, newText: String)
    case terminal(terminalId: String)
    case unknown(JSONValue)

    public init(jsonValue: JSONValue) {
        switch jsonValue.string("type") {
        case "content":
            if let block = jsonValue["content"] { self = .content(ACPContentBlock(jsonValue: block)) }
            else { self = .unknown(jsonValue) }
        case "diff":
            self = .diff(path: jsonValue.string("path") ?? "", oldText: jsonValue.string("oldText"), newText: jsonValue.string("newText") ?? "")
        case "terminal":
            self = .terminal(terminalId: jsonValue.string("terminalId") ?? "")
        default: self = .unknown(jsonValue)
        }
    }

    public var jsonValue: JSONValue {
        switch self {
        case .content(let block): .object(["type": "content", "content": block.jsonValue])
        case .diff(let path, let old, let new):
            acpObject([("type", "diff"), ("path", .string(path)), ("oldText", old.map(JSONValue.string)), ("newText", .string(new))])
        case .terminal(let id): .object(["type": "terminal", "terminalId": .string(id)])
        case .unknown(let raw): raw
        }
    }

    /// Plain-text rendering for the transcript / model output.
    public var textValue: String? {
        switch self {
        case .content(let block): block.textValue
        case .diff(let path, _, let new): "Edited \(path)\n\(new)"
        case .terminal(let id): "[terminal \(id)]"
        case .unknown: nil
        }
    }
}

public struct ACPToolCall: Sendable, Equatable {
    public var toolCallId: String
    public var title: String
    public var name: String?
    public var kind: ACPToolKind
    public var status: ACPToolCallStatus
    public var content: [ACPToolCallContent]
    public var locations: [String]
    public var rawInput: JSONValue?
    public var rawOutput: JSONValue?

    public init(jsonValue: JSONValue) {
        toolCallId = jsonValue.string("toolCallId") ?? ""
        title = jsonValue.string("title") ?? ""
        name = jsonValue.string("name")
        kind = ACPToolKind(raw: jsonValue.string("kind"))
        status = ACPToolCallStatus(raw: jsonValue.string("status"))
        content = (jsonValue["content"]?.arrayValue ?? []).map(ACPToolCallContent.init(jsonValue:))
        locations = (jsonValue["locations"]?.arrayValue ?? []).compactMap { $0.string("path") }
        rawInput = jsonValue["rawInput"]
        rawOutput = jsonValue["rawOutput"]
    }

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return title.isEmpty ? "tool" : title
    }
}

public struct ACPToolCallUpdate: Sendable, Equatable {
    public var toolCallId: String
    public var title: String?
    public var name: String?
    public var kind: ACPToolKind?
    public var status: ACPToolCallStatus?
    public var content: [ACPToolCallContent]?
    public var rawInput: JSONValue?
    public var rawOutput: JSONValue?

    public init(jsonValue: JSONValue) {
        toolCallId = jsonValue.string("toolCallId") ?? ""
        title = jsonValue.string("title")
        name = jsonValue.string("name")
        kind = jsonValue.string("kind").map { ACPToolKind(raw: $0) }
        status = jsonValue.string("status").map { ACPToolCallStatus(raw: $0) }
        content = jsonValue["content"]?.arrayValue?.map(ACPToolCallContent.init(jsonValue:))
        rawInput = jsonValue["rawInput"]
        rawOutput = jsonValue["rawOutput"]
    }

    public var displayName: String? { name ?? title }
}

// MARK: - Plans

public struct ACPPlanEntry: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable { case pending, inProgress = "in_progress", completed }
    public enum Priority: String, Sendable, Equatable { case high, medium, low }
    public var content: String
    public var priority: Priority
    public var status: Status
    public init(content: String, priority: Priority = .medium, status: Status = .pending) {
        self.content = content; self.priority = priority; self.status = status
    }
    public init(jsonValue: JSONValue) {
        content = jsonValue.string("content") ?? ""
        priority = Priority(rawValue: jsonValue.string("priority") ?? "") ?? .medium
        status = Status(rawValue: jsonValue.string("status") ?? "") ?? .pending
    }
    public var todoItem: TodoItem {
        switch status {
        case .pending: TodoItem(content, .pending)
        case .inProgress: TodoItem(content, .inProgress)
        case .completed: TodoItem(content, .completed)
        }
    }
}

// MARK: - Session updates

public struct ACPUsageUpdate: Sendable, Equatable {
    public var used: Int
    public var size: Int
    public var costAmount: Double?
    public var costCurrency: String?
    public init(jsonValue: JSONValue) {
        used = jsonValue.int("used") ?? 0
        size = jsonValue.int("size") ?? 0
        if let cost = jsonValue["cost"] {
            if case .double(let amount) = cost["amount"] ?? .null { costAmount = amount }
            else if let amount = cost["amount"]?.intValue { costAmount = Double(amount) }
            costCurrency = cost.string("currency")
        }
    }
    public var tokenUsage: TokenUsage { TokenUsage(inputTokens: used, outputTokens: 0) }
}

public enum ACPSessionUpdate: Sendable, Equatable {
    case userMessageChunk(ACPContentBlock)
    case agentMessageChunk(ACPContentBlock)
    case agentThoughtChunk(ACPContentBlock)
    case toolCall(ACPToolCall)
    case toolCallUpdate(ACPToolCallUpdate)
    case plan([ACPPlanEntry])
    case availableCommands([String])
    case currentModeUpdate(String)
    case configOptionUpdate([ACPConfigOption])
    case sessionInfoUpdate(JSONValue)
    case usageUpdate(ACPUsageUpdate)
    /// A `sessionUpdate` variant this build does not model; ignored by the client, never fatal.
    case unknown(type: String, raw: JSONValue)

    public init(jsonValue: JSONValue) {
        let type = jsonValue.string("sessionUpdate") ?? ""
        switch type {
        case "user_message_chunk":
            self = .userMessageChunk(ACPContentBlock(jsonValue: jsonValue["content"] ?? .null))
        case "agent_message_chunk":
            self = .agentMessageChunk(ACPContentBlock(jsonValue: jsonValue["content"] ?? .null))
        case "agent_thought_chunk":
            self = .agentThoughtChunk(ACPContentBlock(jsonValue: jsonValue["content"] ?? .null))
        case "tool_call":
            self = .toolCall(ACPToolCall(jsonValue: jsonValue))
        case "tool_call_update":
            self = .toolCallUpdate(ACPToolCallUpdate(jsonValue: jsonValue))
        case "plan":
            self = .plan((jsonValue["entries"]?.arrayValue ?? []).map(ACPPlanEntry.init(jsonValue:)))
        case "available_commands_update":
            self = .availableCommands((jsonValue["availableCommands"]?.arrayValue ?? []).compactMap { $0.string("name") })
        case "current_mode_update":
            self = .currentModeUpdate(jsonValue.string("currentModeId") ?? "")
        case "config_option_update":
            self = .configOptionUpdate((jsonValue["configOptions"]?.arrayValue ?? []).map(ACPConfigOption.init(jsonValue:)))
        case "session_info_update":
            self = .sessionInfoUpdate(jsonValue)
        case "usage_update":
            self = .usageUpdate(ACPUsageUpdate(jsonValue: jsonValue))
        default:
            self = .unknown(type: type, raw: jsonValue)
        }
    }
}

// MARK: - Permissions

public enum ACPPermissionOptionKind: Sendable, Equatable {
    case allowOnce, allowAlways, rejectOnce, rejectAlways
    case unknown(String)

    public init(raw: String?) {
        switch raw {
        case "allow_once": self = .allowOnce
        case "allow_always": self = .allowAlways
        case "reject_once": self = .rejectOnce
        case "reject_always": self = .rejectAlways
        default: self = .unknown(raw ?? "")
        }
    }
    public var rawValue: String {
        switch self {
        case .allowOnce: "allow_once"
        case .allowAlways: "allow_always"
        case .rejectOnce: "reject_once"
        case .rejectAlways: "reject_always"
        case .unknown(let raw): raw
        }
    }
    public var isAllow: Bool { self == .allowOnce || self == .allowAlways }
    public var isReject: Bool { self == .rejectOnce || self == .rejectAlways }
}

public struct ACPPermissionOption: Sendable, Equatable {
    public var optionId: String
    public var name: String
    public var kind: ACPPermissionOptionKind
    public init(optionId: String, name: String, kind: ACPPermissionOptionKind) {
        self.optionId = optionId; self.name = name; self.kind = kind
    }
    public init(jsonValue: JSONValue) {
        optionId = jsonValue.string("optionId") ?? ""
        name = jsonValue.string("name") ?? optionId
        kind = ACPPermissionOptionKind(raw: jsonValue.string("kind"))
    }
}

public struct ACPRequestPermission: Sendable, Equatable {
    public var sessionId: String
    public var toolCall: ACPToolCallUpdate
    public var options: [ACPPermissionOption]
    public init(jsonValue: JSONValue) throws {
        guard let sessionId = jsonValue.string("sessionId") else { throw ACPError.malformedFrame("request_permission missing sessionId") }
        self.sessionId = sessionId
        toolCall = ACPToolCallUpdate(jsonValue: jsonValue["toolCall"] ?? .null)
        options = (jsonValue["options"]?.arrayValue ?? []).map(ACPPermissionOption.init(jsonValue:))
    }
}

public enum ACPRequestPermissionOutcome: Sendable, Equatable {
    case cancelled
    case selected(optionId: String)

    public var jsonValue: JSONValue {
        switch self {
        case .cancelled: .object(["outcome": "cancelled"])
        case .selected(let id): .object(["outcome": "selected", "optionId": .string(id)])
        }
    }
    public init?(jsonValue: JSONValue) {
        switch jsonValue.string("outcome") {
        case "cancelled": self = .cancelled
        case "selected":
            guard let id = jsonValue.string("optionId") else { return nil }
            self = .selected(optionId: id)
        default: return nil
        }
    }
}

// MARK: - File system & terminal (agent -> client)

public struct ACPReadTextFileRequest: Sendable, Equatable {
    public var sessionId: String
    public var path: String
    public var line: Int?
    public var limit: Int?
    public init(sessionId: String, path: String, line: Int? = nil, limit: Int? = nil) {
        self.sessionId = sessionId; self.path = path; self.line = line; self.limit = limit
    }
    public init(jsonValue: JSONValue) throws {
        guard let path = jsonValue.string("path") else { throw ACPError.malformedFrame("read_text_file missing path") }
        sessionId = jsonValue.string("sessionId") ?? ""
        self.path = path
        line = jsonValue.int("line")
        limit = jsonValue.int("limit")
    }
    /// Applies the 1-based `line`/`limit` window to a full text.
    public func windowed(_ text: String) -> String {
        guard line != nil || limit != nil else { return text }
        let lines = text.components(separatedBy: "\n")
        let start = max(0, (line ?? 1) - 1)
        guard start < lines.count else { return "" }
        let end = limit.map { min(lines.count, start + $0) } ?? lines.count
        return lines[start..<end].joined(separator: "\n")
    }
}

public struct ACPWriteTextFileRequest: Sendable, Equatable {
    public var sessionId: String
    public var path: String
    public var content: String
    public init(sessionId: String, path: String, content: String) {
        self.sessionId = sessionId; self.path = path; self.content = content
    }
    public init(jsonValue: JSONValue) throws {
        guard let path = jsonValue.string("path"), let content = jsonValue.string("content") else {
            throw ACPError.malformedFrame("write_text_file missing path or content")
        }
        sessionId = jsonValue.string("sessionId") ?? ""
        self.path = path; self.content = content
    }
}

public struct ACPCreateTerminalRequest: Sendable, Equatable {
    public var sessionId: String
    public var command: String
    public var args: [String]
    public var cwd: String?
    public var env: [(name: String, value: String)]
    public var outputByteLimit: Int?
    public static func == (lhs: ACPCreateTerminalRequest, rhs: ACPCreateTerminalRequest) -> Bool {
        lhs.sessionId == rhs.sessionId && lhs.command == rhs.command && lhs.args == rhs.args && lhs.cwd == rhs.cwd
    }
    public init(jsonValue: JSONValue) throws {
        guard let command = jsonValue.string("command") else { throw ACPError.malformedFrame("terminal/create missing command") }
        sessionId = jsonValue.string("sessionId") ?? ""
        self.command = command
        args = (jsonValue["args"]?.arrayValue ?? []).compactMap(\.stringValue)
        cwd = jsonValue.string("cwd")
        env = (jsonValue["env"]?.arrayValue ?? []).compactMap { entry in
            guard let name = entry.string("name"), let value = entry.string("value") else { return nil }
            return (name: name, value: value)
        }
        outputByteLimit = jsonValue.int("outputByteLimit")
    }
}

/// Free-text (and structured) user input over `elicitation/create` (form mode).
public struct ACPElicitationPrompt: Sendable, Equatable {
    public var sessionId: String?
    public var toolCallId: String?
    public var title: String
    public var message: String
    public init(sessionId: String? = nil, toolCallId: String? = nil, title: String, message: String = "") {
        self.sessionId = sessionId; self.toolCallId = toolCallId; self.title = title; self.message = message
    }
}

public enum ACPElicitationOutcome: Sendable, Equatable {
    case accept(content: [String: JSONValue]?)
    case decline
    case cancel

    /// The accepted free-text answer under the endpoint's single-field form, if any.
    public var acceptedText: String? {
        guard case .accept(let content) = self else { return nil }
        return content?["answer"]?.stringValue
    }

    public init(jsonValue: JSONValue) {
        switch jsonValue.string("action") {
        case "accept": self = .accept(content: jsonValue["content"]?.objectValue)
        case "decline": self = .decline
        default: self = .cancel
        }
    }

    /// A single-string-field form request for `elicitation/create`.
    public static func formRequest(prompt: ACPElicitationPrompt, field: String = "answer") -> JSONValue {
        var object: [String: JSONValue] = [
            "message": .string(prompt.message.isEmpty ? prompt.title : prompt.message),
            "mode": "form",
            "requestedSchema": .object([
                "type": "object", "title": .string(prompt.title),
                "properties": .object([field: .object(["type": "string", "description": .string(prompt.message)])]),
                "required": .array([.string(field)]),
            ]),
        ]
        if let sessionId = prompt.sessionId { object["sessionId"] = .string(sessionId) }
        if let toolCallId = prompt.toolCallId { object["toolCallId"] = .string(toolCallId) }
        return .object(object)
    }

    public static func acceptResponse(text: String, field: String = "answer") -> JSONValue {
        .object(["action": "accept", "content": .object([field: .string(text)])])
    }
}

public struct ACPTerminalOutput: Sendable, Equatable {
    public var output: String
    public var truncated: Bool
    public var exitCode: Int?
    public var signal: String?
    public init(output: String, truncated: Bool = false, exitCode: Int? = nil, signal: String? = nil) {
        self.output = output; self.truncated = truncated; self.exitCode = exitCode; self.signal = signal
    }
    public var jsonValue: JSONValue {
        if exitCode != nil || signal != nil {
            return acpObject([
                ("output", .string(output)), ("truncated", .bool(truncated)),
                ("exitStatus", acpObject([("exitCode", exitCode.map(JSONValue.int)), ("signal", signal.map(JSONValue.string))])),
            ])
        }
        return acpObject([("output", .string(output)), ("truncated", .bool(truncated))])
    }
}

/// Terminal operations the host may provide. Every member is optional at the `ACPHostServices` level.
public struct ACPTerminalSession: Sendable {
    public var terminalId: String
    public init(terminalId: String) { self.terminalId = terminalId }
}
