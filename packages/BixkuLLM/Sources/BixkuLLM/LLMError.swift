import Foundation

public enum LLMError: Error, Equatable, Sendable {
    /// The configured provider is `none`.
    case disabled
    case invalidConfiguration(String)
    /// No API key could be resolved. The associated text names the source, never a value.
    case missingAPIKey(String)
    /// The overall deadline elapsed.
    case timeout
    case transport(String)
    case http(status: Int, message: String, retryAfter: TimeInterval?)
    case invalidResponse(String)
    /// `ScriptedLLM` ran out of scripted steps.
    case scriptExhausted

    /// Whether retrying the same request may succeed.
    public var isRetryable: Bool {
        switch self {
        case .timeout, .transport: return true
        case .http(let status, _, _): return status == 408 || status == 409 || status == 429 || status >= 500
        default: return false
        }
    }
}

extension LLMError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .disabled: return "The LLM provider is disabled."
        case .invalidConfiguration(let m): return "Invalid LLM configuration: \(m)"
        case .missingAPIKey(let s): return "No API key available from \(s)."
        case .timeout: return "The LLM request timed out."
        case .transport(let m): return "LLM transport error: \(m)"
        case .http(let status, let m, _): return "LLM request failed (HTTP \(status)): \(m)"
        case .invalidResponse(let m): return "Unexpected LLM response: \(m)"
        case .scriptExhausted: return "ScriptedLLM has no more scripted steps."
        }
    }
}
