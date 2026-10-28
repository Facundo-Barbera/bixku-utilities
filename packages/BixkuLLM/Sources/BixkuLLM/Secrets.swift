import Foundation

/// An API key. It never prints itself: `description`, `debugDescription` and
/// reflection all show a placeholder, and it is deliberately not `Codable`.
public struct APIKey: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let value: String

    public init(_ value: String) {
        self.value = value
    }

    /// The raw key. Only call this when building an authenticated request.
    public func reveal() -> String { value }

    public var description: String { "APIKey(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// Where an API key comes from. Only a *reference* is ever stored in config files.
public enum APIKeySource: Sendable, Equatable {
    /// The provider needs no key (e.g. a local server).
    case none
    /// The NAME of an environment variable.
    case environment(String)
    /// A generic-password item in the macOS Keychain.
    case keychain(service: String, account: String)

    /// Human-readable reference, safe to log.
    public var reference: String {
        switch self {
        case .none: return "no key"
        case .environment(let name): return "environment variable \(name)"
        case .keychain(let service, let account): return "keychain item \(service)/\(account)"
        }
    }
}

public protocol SecretResolver: Sendable {
    /// Returns the key for `source`, or throws ``LLMError/missingAPIKey(_:)``.
    func apiKey(for source: APIKeySource) throws -> APIKey
}

/// Resolves `.environment` sources from a process environment.
public struct EnvironmentSecretResolver: SecretResolver {
    private let environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func apiKey(for source: APIKeySource) throws -> APIKey {
        guard case .environment(let name) = source else {
            throw LLMError.missingAPIKey(source.reference)
        }
        guard let raw = environment[name], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.missingAPIKey(source.reference)
        }
        return APIKey(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

#if canImport(Security)
import Security

/// Resolves `.keychain` sources from the macOS Keychain (generic passwords).
public struct KeychainSecretResolver: SecretResolver {
    public init() {}

    public func apiKey(for source: APIKeySource) throws -> APIKey {
        guard case .keychain(let service, let account) = source else {
            throw LLMError.missingAPIKey(source.reference)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            throw LLMError.missingAPIKey(source.reference)
        }
        return APIKey(text)
    }
}
#endif

/// Environment variables, plus the Keychain where the platform has one.
public struct DefaultSecretResolver: SecretResolver {
    private let environment: EnvironmentSecretResolver

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = EnvironmentSecretResolver(environment: environment)
    }

    public func apiKey(for source: APIKeySource) throws -> APIKey {
        switch source {
        case .none:
            throw LLMError.missingAPIKey(source.reference)
        case .environment:
            return try environment.apiKey(for: source)
        case .keychain:
            #if canImport(Security)
            return try KeychainSecretResolver().apiKey(for: source)
            #else
            throw LLMError.missingAPIKey("\(source.reference) (the keychain is unavailable on this platform)")
            #endif
        }
    }
}

/// Scrubs secrets from text before it reaches logs or error messages.
public struct SecretRedactor: Sendable {
    public static let placeholder = "[REDACTED]"

    private let secrets: [String]

    /// - Parameter secrets: exact secret values to mask wherever they appear.
    public init(secrets: [String] = []) {
        self.secrets = secrets.filter { $0.count >= 4 }
    }

    public init(keys: [APIKey]) {
        self.init(secrets: keys.map { $0.reveal() })
    }

    // Patterns for keys that were not registered explicitly.
    private static let patterns: [(NSRegularExpression, String)] = {
        let specs: [(String, String)] = [
            (#"sk-[A-Za-z0-9_\-]{8,}"#, placeholder),
            (#"(?i)(bearer\s+)[A-Za-z0-9._\-~+/]{8,}=*"#, "$1\(placeholder)"),
            (#"(?i)((?:x-api-key|api[-_]?key|authorization)["']?\s*[:=]\s*["']?)[^\s"',}]+"#, "$1\(placeholder)"),
        ]
        return specs.compactMap { spec in
            (try? NSRegularExpression(pattern: spec.0)).map { ($0, spec.1) }
        }
    }()

    public func redact(_ text: String) -> String {
        var result = text
        for secret in secrets {
            result = result.replacingOccurrences(of: secret, with: Self.placeholder)
        }
        for (regex, template) in Self.patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }
}

/// Receives log lines from clients. Lines are always redacted first and never contain
/// request or response bodies.
public typealias LLMLogSink = @Sendable (String) -> Void
