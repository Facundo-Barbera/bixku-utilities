import Foundation

public enum LLMRole: String, Sendable, Codable, Equatable {
    case system
    case user
    case assistant
    case tool
}

/// A structured request from the model to run a tool.
public struct LLMToolCall: Sendable, Codable, Equatable {
    public var id: String
    public var name: String
    /// Arguments as a JSON object (validated against the tool's schema by the caller).
    public var arguments: JSONValue

    public init(id: String, name: String, arguments: JSONValue = [:]) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    /// Decodes the arguments into a `Decodable` type.
    public func decodeArguments<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try arguments.decode(T.self)
    }
}

public struct LLMMessage: Sendable, Codable, Equatable {
    public var role: LLMRole
    public var content: String
    /// Tool calls requested by an assistant message.
    public var toolCalls: [LLMToolCall]
    /// For `.tool` messages: the id of the call this message answers.
    public var toolCallID: String?
    /// For `.tool` messages: whether the tool failed.
    public var isError: Bool

    public init(
        role: LLMRole,
        content: String,
        toolCalls: [LLMToolCall] = [],
        toolCallID: String? = nil,
        isError: Bool = false
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.isError = isError
    }

    public static func system(_ text: String) -> LLMMessage {
        LLMMessage(role: .system, content: text)
    }

    public static func user(_ text: String) -> LLMMessage {
        LLMMessage(role: .user, content: text)
    }

    public static func assistant(_ text: String, toolCalls: [LLMToolCall] = []) -> LLMMessage {
        LLMMessage(role: .assistant, content: text, toolCalls: toolCalls)
    }

    public static func tool(callID: String, content: String, isError: Bool = false) -> LLMMessage {
        LLMMessage(role: .tool, content: content, toolCallID: callID, isError: isError)
    }
}

/// A tool the model may call. `parameters` is a JSON-schema object describing the arguments.
public struct LLMTool: Sendable, Codable, Equatable {
    public var name: String
    public var description: String
    public var parameters: JSONValue

    public init(
        name: String,
        description: String,
        parameters: JSONValue = ["type": "object", "properties": [:]]
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public enum LLMToolChoice: Sendable, Equatable {
    /// The model decides whether to call a tool.
    case auto
    /// The model must not call tools.
    case none
    /// The model must call some tool.
    case required
    /// The model must call this specific tool.
    case tool(String)
}

public struct LLMRequest: Sendable, Equatable {
    public var messages: [LLMMessage]
    public var tools: [LLMTool]
    public var toolChoice: LLMToolChoice
    /// Overrides the client's default model.
    public var model: String?
    public var maxTokens: Int?
    public var temperature: Double?
    /// Overall deadline in seconds; overrides the client's default.
    public var timeout: TimeInterval?

    public init(
        messages: [LLMMessage],
        tools: [LLMTool] = [],
        toolChoice: LLMToolChoice = .auto,
        model: String? = nil,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        timeout: TimeInterval? = nil
    ) {
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.model = model
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.timeout = timeout
    }
}

public enum LLMStopReason: Sendable, Equatable {
    case endTurn
    case toolUse
    case maxTokens
    case contentFilter
    case other(String)
}

public struct LLMUsage: Sendable, Codable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct LLMResponse: Sendable, Equatable {
    /// The assistant message (text and any tool calls).
    public var message: LLMMessage
    public var stopReason: LLMStopReason
    public var usage: LLMUsage?

    public init(message: LLMMessage, stopReason: LLMStopReason = .endTurn, usage: LLMUsage? = nil) {
        self.message = message
        self.stopReason = stopReason
        self.usage = usage
    }

    public var text: String { message.content }
    public var toolCalls: [LLMToolCall] { message.toolCalls }

    public func toolCall(named name: String) -> LLMToolCall? {
        toolCalls.first { $0.name == name }
    }

    /// A plain text reply.
    public static func text(_ text: String, usage: LLMUsage? = nil) -> LLMResponse {
        LLMResponse(message: .assistant(text), stopReason: .endTurn, usage: usage)
    }

    /// A reply that asks for tool calls.
    public static func toolCalls(_ calls: [LLMToolCall], text: String = "", usage: LLMUsage? = nil) -> LLMResponse {
        LLMResponse(message: .assistant(text, toolCalls: calls), stopReason: .toolUse, usage: usage)
    }
}
