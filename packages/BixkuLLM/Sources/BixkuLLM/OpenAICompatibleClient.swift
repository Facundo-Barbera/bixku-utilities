import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Client for OpenAI-style Chat Completions endpoints (`POST {base}/chat/completions`):
/// OpenAI itself and compatible servers (local runtimes, gateways).
public struct OpenAICompatibleClient: LLMClient {
    public static let defaultBaseURL = URL(string: "https://api.openai.com/v1")!

    private let model: String
    private let apiKey: APIKey?
    private let baseURL: URL
    private let session: URLSession
    private let defaultMaxTokens: Int
    private let requestTimeout: TimeInterval
    private let log: LLMLogSink?

    /// - Parameter baseURL: includes the version prefix, e.g. `https://host/v1`.
    /// - Parameter apiKey: `nil` for servers that need no authentication.
    public init(
        model: String,
        apiKey: APIKey?,
        baseURL: URL? = nil,
        session: URLSession = .shared,
        defaultMaxTokens: Int = 1024,
        requestTimeout: TimeInterval = 20,
        log: LLMLogSink? = nil
    ) {
        self.model = model
        self.apiKey = apiKey
        self.baseURL = baseURL ?? Self.defaultBaseURL
        self.session = session
        self.defaultMaxTokens = defaultMaxTokens
        self.requestTimeout = requestTimeout
        self.log = log
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let redactor = SecretRedactor(keys: apiKey.map { [$0] } ?? [])
        let urlRequest = try makeURLRequest(for: request)
        let started = Date()
        let result = try await HTTP.send(
            urlRequest, session: session, timeout: request.timeout ?? requestTimeout, redactor: redactor)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        log?(redactor.redact("openai-compatible POST \(urlRequest.url?.path ?? "") -> \(result.status) in \(elapsed)ms"))

        guard (200..<300).contains(result.status) else {
            throw HTTP.httpError(result, redactor: redactor)
        }
        return try Self.parse(result.body, redactor: redactor)
    }

    // MARK: Request

    func makeURLRequest(for request: LLMRequest) throws -> URLRequest {
        let url = HTTP.appendPath(baseURL, "chat/completions")
        try HTTP.validateEndpoint(url, sendsKey: apiKey != nil)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "accept")
        if let apiKey {
            urlRequest.setValue("Bearer \(apiKey.reveal())", forHTTPHeaderField: "authorization")
        }
        urlRequest.httpBody = try HTTP.encodeBody(makeBody(for: request))
        return urlRequest
    }

    func makeBody(for request: LLMRequest) -> JSONValue {
        let messages: [JSONValue] = request.messages.map { message in
            switch message.role {
            case .system, .user:
                return ["role": .string(message.role.rawValue), "content": .string(message.content)]
            case .assistant:
                var object: [String: JSONValue] = [
                    "role": "assistant",
                    "content": message.content.isEmpty && !message.toolCalls.isEmpty ? .null : .string(message.content),
                ]
                if !message.toolCalls.isEmpty {
                    object["tool_calls"] = .array(message.toolCalls.map {
                        [
                            "id": .string($0.id),
                            "type": "function",
                            "function": ["name": .string($0.name), "arguments": .string($0.arguments.jsonString())],
                        ]
                    })
                }
                return .object(object)
            case .tool:
                return [
                    "role": "tool",
                    "tool_call_id": .string(message.toolCallID ?? ""),
                    "content": .string(message.content),
                ]
            }
        }

        var body: [String: JSONValue] = [
            "model": .string(request.model ?? model),
            "messages": .array(messages),
            "max_tokens": .number(Double(request.maxTokens ?? defaultMaxTokens)),
        ]
        if let temperature = request.temperature { body["temperature"] = .number(temperature) }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map {
                [
                    "type": "function",
                    "function": [
                        "name": .string($0.name),
                        "description": .string($0.description),
                        "parameters": $0.parameters,
                    ],
                ]
            })
            switch request.toolChoice {
            case .auto: body["tool_choice"] = "auto"
            case .none: body["tool_choice"] = "none"
            case .required: body["tool_choice"] = "required"
            case .tool(let name):
                body["tool_choice"] = ["type": "function", "function": ["name": .string(name)]]
            }
        }
        return .object(body)
    }

    // MARK: Response

    private struct Wire: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                struct Call: Decodable {
                    struct Function: Decodable {
                        var name: String
                        var arguments: String?
                    }

                    var id: String?
                    var function: Function
                }

                var content: String?
                var tool_calls: [Call]?
            }

            var message: Message
            var finish_reason: String?
        }

        struct Usage: Decodable {
            var prompt_tokens: Int?
            var completion_tokens: Int?
        }

        var choices: [Choice]
        var usage: Usage?
    }

    static func parse(_ data: Data, redactor: SecretRedactor = SecretRedactor()) throws -> LLMResponse {
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            throw LLMError.invalidResponse("could not decode chat completion response")
        }
        guard let choice = wire.choices.first else {
            throw LLMError.invalidResponse("response has no choices")
        }

        var calls: [LLMToolCall] = []
        for (index, call) in (choice.message.tool_calls ?? []).enumerated() {
            let raw = (call.function.arguments ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let arguments: JSONValue
            if raw.isEmpty {
                arguments = [:]
            } else if let parsed = try? JSONValue(jsonString: raw) {
                arguments = parsed
            } else {
                throw LLMError.invalidResponse(
                    redactor.redact("arguments of tool call '\(call.function.name)' are not valid JSON"))
            }
            calls.append(LLMToolCall(id: call.id ?? "call_\(index)", name: call.function.name, arguments: arguments))
        }

        let stop: LLMStopReason
        switch choice.finish_reason {
        case "stop", nil: stop = .endTurn
        case "tool_calls", "function_call": stop = .toolUse
        case "length": stop = .maxTokens
        case "content_filter": stop = .contentFilter
        case .some(let other): stop = .other(other)
        }

        let usage = wire.usage.map {
            LLMUsage(inputTokens: $0.prompt_tokens ?? 0, outputTokens: $0.completion_tokens ?? 0)
        }
        return LLMResponse(
            message: .assistant(choice.message.content ?? "", toolCalls: calls),
            stopReason: calls.isEmpty ? stop : .toolUse,
            usage: usage
        )
    }
}
