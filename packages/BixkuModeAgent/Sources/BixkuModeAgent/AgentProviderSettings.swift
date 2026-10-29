import BixkuLLM
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The language model the user chose for the agent (the Agent tab's provider
/// settings), with the API key already looked up. Turns into an ``AgentLLM`` or
/// explains, in words meant for the user, what is missing.
public struct AgentProviderSettings: Sendable, Equatable {
    public var provider: LLMProvider
    /// Name shown in messages ("Anthropic").
    public var displayName: String
    public var model: String
    /// `nil` or blank when no key was found.
    public var apiKey: String?
    /// Environment variable the key may come from, named in the "no key" message.
    public var environmentVariable: String?
    /// Endpoint override; `openai-compatible` defaults to OpenAI's.
    public var baseURL: URL?
    /// Deadline of each model request (a run makes several).
    public var requestTimeout: TimeInterval

    public init(
        provider: LLMProvider,
        displayName: String,
        model: String,
        apiKey: String?,
        environmentVariable: String? = nil,
        baseURL: URL? = nil,
        requestTimeout: TimeInterval = 60
    ) {
        self.provider = provider
        self.displayName = displayName
        self.model = model
        self.apiKey = apiKey
        self.environmentVariable = environmentVariable
        self.baseURL = baseURL
        self.requestTimeout = requestTimeout
    }

    /// The configured model, or ``ModeAgentControllerError/notConfigured(_:)``.
    public func makeLLM(session: URLSession = .shared) throws -> LLMClientAgentLLM {
        guard provider != .none else {
            throw ModeAgentControllerError.notConfigured("No language model provider is selected for the agent.")
        }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw ModeAgentControllerError.notConfigured("Set the \(displayName) model under Provider in the Agent tab.")
        }
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else {
            var message = "No \(displayName) API key is configured. Add one under Provider in the Agent tab"
            if let name = environmentVariable?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                message += " or set the \(name) environment variable"
            }
            throw ModeAgentControllerError.notConfigured(message + ".")
        }

        let client: any LLMClient
        switch provider {
        case .anthropic:
            client = AnthropicClient(model: model, apiKey: APIKey(key), baseURL: baseURL, session: session, requestTimeout: requestTimeout)
        case .openAICompatible:
            client = OpenAICompatibleClient(model: model, apiKey: APIKey(key), baseURL: baseURL, session: session, requestTimeout: requestTimeout)
        case .none:
            throw ModeAgentControllerError.notConfigured("No language model provider is selected for the agent.")
        }
        return LLMClientAgentLLM(client: client)
    }
}
