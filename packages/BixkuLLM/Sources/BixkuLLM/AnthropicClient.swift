import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Client for the Anthropic Messages API (`POST /v1/messages`) with tool use.
public struct AnthropicClient: LLMClient {
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com")!
    public static let apiVersion = "2023-06-01"

    private let model: String
    private let apiKey: APIKey
    private let baseURL: URL
    private let session: URLSession
    private let defaultMaxTokens: Int
    private let requestTimeout: TimeInterval
    private let log: LLMLogSink?

    public init(
        model: String,
        apiKey: APIKey,
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
        let redactor = SecretRedactor(keys: [apiKey])
        let urlRequest = try makeURLRequest(for: request)
        let started = Date()
        let result = try await HTTP.send(
            urlRequest, session: session, timeout: request.timeout ?? requestTimeout, redactor: redactor)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        log?(redactor.redact("anthropic POST \(urlRequest.url?.path ?? "") -> \(result.status) in \(elapsed)ms"))

        guard (200..<300).contains(result.status) else {
            throw HTTP.httpError(result, redactor: redactor)
        }
        return try Self.parse(result.body)
    }

    // MARK: Request

    func makeURLRequest(for request: LLMRequest) throws -> URLRequest {
        let url = HTTP.appendPath(baseURL, "v1/messages")
        try HTTP.validateEndpoint(url, sendsKey: true)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "accept")
        urlRequest.setValue(apiKey.reveal(), forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try HTTP.encodeBody(makeBody(for: request))
        return urlRequest
    }

    func makeBody(for request: LLMRequest) -> JSONValue {
        let systemText = request.messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")

        // Anthropic wants alternating user/assistant turns; tool results travel as user
        // content blocks, so consecutive same-role entries are merged.
        var turns: [(role: String, blocks: [JSONValue])] = []
        func append(role: String, blocks: [JSONValue]) {
            if let last = turns.last, last.role == role {
                turns[turns.count - 1].blocks += blocks
            } else {
                turns.append((role, blocks))
            }
        }
        for message in request.messages {
            switch message.role {
            case .system:
                continue
            case .user:
                append(role: "user", blocks: [["type": "text", "text": .string(message.content)]])
            case .assistant:
                var blocks: [JSONValue] = []
                if !message.content.isEmpty {
                    blocks.append(["type": "text", "text": .string(message.content)])
                }
                for call in message.toolCalls {
                    blocks.append([
                        "type": "tool_use",
                        "id": .string(call.id),
                        "name": .string(call.name),
                        "input": call.arguments,
                    ])
                }
                append(role: "assistant", blocks: blocks)
            case .tool:
                var block: [String: JSONValue] = [
                    "type": "tool_result",
                    "tool_use_id": .string(message.toolCallID ?? ""),
                    "content": .string(message.content),
                ]
                if message.isError { block["is_error"] = true }
                append(role: "user", blocks: [.object(block)])
            }
        }

        var body: [String: JSONValue] = [
            "model": .string(request.model ?? model),
            "max_tokens": .number(Double(request.maxTokens ?? defaultMaxTokens)),
            "messages": .array(turns.map { ["role": .string($0.role), "content": .array($0.blocks)] }),
        ]
        if !systemText.isEmpty { body["system"] = .string(systemText) }
        if let temperature = request.temperature { body["temperature"] = .number(temperature) }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map {
                ["name": .string($0.name), "description": .string($0.description), "input_schema": $0.parameters]
            })
            switch request.toolChoice {
            case .auto: body["tool_choice"] = ["type": "auto"]
            case .none: body["tool_choice"] = ["type": "none"]
            case .required: body["tool_choice"] = ["type": "any"]
            case .tool(let name): body["tool_choice"] = ["type": "tool", "name": .string(name)]
            }
        }
        return .object(body)
    }

    // MARK: Response

    private struct Wire: Decodable {
        struct Block: Decodable {
            var type: String
            var text: String?
            var id: String?
            var name: String?
            var input: JSONValue?
        }

        struct Usage: Decodable {
            var input_tokens: Int?
            var output_tokens: Int?
        }

        var content: [Block]
        var stop_reason: String?
        var usage: Usage?
    }

    static func parse(_ data: Data) throws -> LLMResponse {
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            throw LLMError.invalidResponse("could not decode Anthropic response")
        }

        var text = ""
        var calls: [LLMToolCall] = []
        for block in wire.content {
            switch block.type {
            case "text":
                text += block.text ?? ""
            case "tool_use":
                guard let id = block.id, let name = block.name else {
                    throw LLMError.invalidResponse("tool_use block without id or name")
                }
                calls.append(LLMToolCall(id: id, name: name, arguments: block.input ?? [:]))
            default:
                continue
            }
        }

        let stop: LLMStopReason
        switch wire.stop_reason {
        case "end_turn", "stop_sequence", nil: stop = .endTurn
        case "tool_use": stop = .toolUse
        case "max_tokens": stop = .maxTokens
        case "refusal": stop = .contentFilter
        case .some(let other): stop = .other(other)
        }

        let usage = wire.usage.map {
            LLMUsage(inputTokens: $0.input_tokens ?? 0, outputTokens: $0.output_tokens ?? 0)
        }
        return LLMResponse(
            message: .assistant(text, toolCalls: calls),
            stopReason: calls.isEmpty ? stop : .toolUse,
            usage: usage
        )
    }
}
