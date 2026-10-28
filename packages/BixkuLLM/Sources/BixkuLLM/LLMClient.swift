import Foundation

/// A provider-agnostic chat model with structured tool calling.
///
/// Implementations must honour task cancellation (throwing `CancellationError`) and the
/// request's `timeout` (throwing ``LLMError/timeout``).
public protocol LLMClient: Sendable {
    func complete(_ request: LLMRequest) async throws -> LLMResponse
}

extension LLMClient {
    /// One-shot convenience: optional system prompt plus a single user message.
    public func complete(
        system: String? = nil,
        user: String,
        tools: [LLMTool] = [],
        toolChoice: LLMToolChoice = .auto
    ) async throws -> LLMResponse {
        var messages: [LLMMessage] = []
        if let system { messages.append(.system(system)) }
        messages.append(.user(user))
        return try await complete(LLMRequest(messages: messages, tools: tools, toolChoice: toolChoice))
    }
}
