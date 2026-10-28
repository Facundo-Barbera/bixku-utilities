import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum LLMProvider: String, Sendable, Equatable, CaseIterable {
    case anthropic
    case openAICompatible = "openai-compatible"
    case none
}

/// Provider settings. Holds only a *reference* to the API key (env var name or Keychain
/// item), never the key itself.
public struct LLMConfig: Sendable, Equatable {
    public static let defaultAPIKeyEnvironmentVariable = "BIXKU_LLM_API_KEY"

    public var provider: LLMProvider
    public var model: String
    /// Required for `openai-compatible`; optional override for `anthropic`.
    public var baseURL: URL?
    public var apiKeySource: APIKeySource
    public var requestTimeout: TimeInterval
    public var maxTokens: Int

    public init(
        provider: LLMProvider,
        model: String,
        baseURL: URL? = nil,
        apiKeySource: APIKeySource = .environment(LLMConfig.defaultAPIKeyEnvironmentVariable),
        requestTimeout: TimeInterval = 20,
        maxTokens: Int = 1024
    ) {
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.apiKeySource = apiKeySource
        self.requestTimeout = requestTimeout
        self.maxTokens = maxTokens
    }

    /// Builds a config from the flat keys of the `[llm]` table in `config.example.toml`:
    /// `provider`, `model`, `base_url`, `api_key_env`, `api_key_keychain_service`,
    /// `api_key_keychain_account`, `request_timeout_seconds`, `max_tokens`.
    public init(fields: [String: String]) throws {
        func value(_ key: String) -> String? {
            let trimmed = fields[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty ?? true) ? nil : trimmed
        }

        let rawProvider = value("provider") ?? LLMProvider.none.rawValue
        guard let provider = LLMProvider(rawValue: rawProvider) else {
            throw LLMError.invalidConfiguration("unknown provider '\(rawProvider)'")
        }

        var baseURL: URL?
        if let raw = value("base_url") {
            guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme), url.host != nil
            else {
                throw LLMError.invalidConfiguration("base_url must be an http(s) URL")
            }
            baseURL = url
        }

        let source: APIKeySource
        if let service = value("api_key_keychain_service") {
            source = .keychain(service: service, account: value("api_key_keychain_account") ?? "default")
        } else if let name = value("api_key_env") {
            guard Self.isValidEnvironmentVariableName(name) else {
                // Do not echo the value: it may be a key pasted by mistake.
                throw LLMError.invalidConfiguration(
                    "api_key_env must be the NAME of an environment variable, never the key itself")
            }
            source = .environment(name)
        } else if provider == .none {
            source = .none
        } else {
            source = .environment(Self.defaultAPIKeyEnvironmentVariable)
        }

        var timeout: TimeInterval = 20
        if let raw = value("request_timeout_seconds") {
            guard let seconds = TimeInterval(raw), seconds > 0 else {
                throw LLMError.invalidConfiguration("request_timeout_seconds must be a positive number")
            }
            timeout = seconds
        }

        var maxTokens = 1024
        if let raw = value("max_tokens") {
            guard let n = Int(raw), n > 0 else {
                throw LLMError.invalidConfiguration("max_tokens must be a positive integer")
            }
            maxTokens = n
        }

        self.init(
            provider: provider,
            model: value("model") ?? "",
            baseURL: baseURL,
            apiKeySource: source,
            requestTimeout: timeout,
            maxTokens: maxTokens
        )
    }

    static func isValidEnvironmentVariableName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, !("0"..."9").contains(first) else { return false }
        return name.unicodeScalars.allSatisfy {
            ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_"
        }
    }
}

public enum LLMClientFactory {
    /// Creates the client described by `config`, resolving the API key through `secrets`.
    public static func makeClient(
        config: LLMConfig,
        secrets: any SecretResolver = DefaultSecretResolver(),
        session: URLSession = .shared,
        log: LLMLogSink? = nil
    ) throws -> any LLMClient {
        guard config.provider != .none else { throw LLMError.disabled }
        guard !config.model.isEmpty else { throw LLMError.invalidConfiguration("model is not set") }

        switch config.provider {
        case .anthropic:
            return AnthropicClient(
                model: config.model,
                apiKey: try secrets.apiKey(for: config.apiKeySource),
                baseURL: config.baseURL,
                session: session,
                defaultMaxTokens: config.maxTokens,
                requestTimeout: config.requestTimeout,
                log: log
            )
        case .openAICompatible:
            guard config.baseURL != nil else {
                throw LLMError.invalidConfiguration("base_url is required for openai-compatible providers")
            }
            let key: APIKey? = config.apiKeySource == .none ? nil : try secrets.apiKey(for: config.apiKeySource)
            return OpenAICompatibleClient(
                model: config.model,
                apiKey: key,
                baseURL: config.baseURL,
                session: session,
                defaultMaxTokens: config.maxTokens,
                requestTimeout: config.requestTimeout,
                log: log
            )
        case .none:
            throw LLMError.disabled
        }
    }
}
