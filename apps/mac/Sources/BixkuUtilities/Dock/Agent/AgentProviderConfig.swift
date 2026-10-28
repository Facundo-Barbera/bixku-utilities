import Foundation

/// The LLM provider the Agent talks to.
enum AgentProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case anthropic
    case openai

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-5-5"
        case .openai: return "gpt-4o-mini"
        }
    }

    var defaultEnvironmentVariable: String {
        switch self {
        case .anthropic: return "ANTHROPIC_API_KEY"
        case .openai: return "OPENAI_API_KEY"
        }
    }
}

/// Non-secret provider settings. The API key itself is never part of this
/// type; it lives in a ``SecretStore`` (see ``AgentCredentials``).
struct AgentProviderConfig: Codable, Equatable, Sendable {
    var provider: AgentProvider
    var model: String
    /// Name of an environment variable that may hold the API key. When set in
    /// the app's environment it takes precedence over the stored key.
    var environmentVariable: String

    init(provider: AgentProvider = .anthropic, model: String? = nil, environmentVariable: String? = nil) {
        self.provider = provider
        self.model = model ?? provider.defaultModel
        self.environmentVariable = environmentVariable ?? provider.defaultEnvironmentVariable
    }

    static let `default` = AgentProviderConfig()

    /// Loads the config from `defaults`, or returns the default one.
    static func load(from defaults: UserDefaults, key: String = "dock.agent.provider") -> AgentProviderConfig {
        guard let data = defaults.data(forKey: key),
              let config = try? JSONDecoder().decode(AgentProviderConfig.self, from: data)
        else {
            return .default
        }
        return config
    }

    func save(to defaults: UserDefaults, key: String = "dock.agent.provider") {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: key)
        }
    }
}

/// Finds the API key for a provider configuration.
struct AgentCredentials: Sendable {
    let secrets: any SecretStore

    init(secrets: any SecretStore) {
        self.secrets = secrets
    }

    /// Secret-store account under which a provider's key is filed.
    static func account(for provider: AgentProvider) -> String {
        "dock.agent.\(provider.rawValue).api-key"
    }

    /// The key from the configured environment variable if it is set and not
    /// blank, otherwise the one in the secret store, otherwise `nil`.
    func apiKey(for config: AgentProviderConfig, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String? {
        let name = config.environmentVariable.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        return try secrets.secret(for: Self.account(for: config.provider))
    }

    func hasStoredKey(for provider: AgentProvider) -> Bool {
        ((try? secrets.secret(for: Self.account(for: provider))) ?? nil) != nil
    }

    func store(_ key: String, for provider: AgentProvider) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try secrets.removeSecret(for: Self.account(for: provider))
        } else {
            try secrets.setSecret(trimmed, for: Self.account(for: provider))
        }
    }

    func removeKey(for provider: AgentProvider) throws {
        try secrets.removeSecret(for: Self.account(for: provider))
    }
}
