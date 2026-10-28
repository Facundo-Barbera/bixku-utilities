import XCTest
@testable import BixkuLLM

final class OpenAICompatibleClientTests: XCTestCase {
    private let secret = "sk-" + String(repeating: "x", count: 24)
    private let base = URL(string: "https://llm.example.com/v1")!

    private func client(key: APIKey? = APIKey("sk-" + String(repeating: "x", count: 24)), base: URL? = nil) -> OpenAICompatibleClient {
        OpenAICompatibleClient(
            model: "test-model", apiKey: key, baseURL: base ?? self.base, session: StubURLProtocol.session())
    }

    func testBuildsRequest() async throws {
        StubURLProtocol.reset(.init(body: jsonBody(#"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"#)))
        let call = LLMToolCall(id: "c1", name: "set_mode", arguments: ["m": "writing"])
        let tool = LLMTool(name: "set_mode", description: "Pick")
        let request = LLMRequest(
            messages: [.system("sys"), .user("hi"), .assistant("", toolCalls: [call]), .tool(callID: "c1", content: "done")],
            tools: [tool],
            toolChoice: .required,
            maxTokens: 64
        )
        _ = try await client().complete(request)

        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.url?.absoluteString, "https://llm.example.com/v1/chat/completions")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "authorization"), "Bearer \(secret)")

        let body = try sentBody()
        XCTAssertEqual(body["max_tokens"]?.intValue, 64)
        XCTAssertEqual(body["tool_choice"]?.stringValue, "required")
        XCTAssertEqual(body["tools"]?[0]?["function"]?["name"]?.stringValue, "set_mode")
        let messages = try XCTUnwrap(body["messages"]?.arrayValue)
        XCTAssertEqual(messages.map { $0["role"]?.stringValue }, ["system", "user", "assistant", "tool"])
        XCTAssertEqual(messages[2]["content"], .null)
        let arguments = try XCTUnwrap(messages[2]["tool_calls"]?[0]?["function"]?["arguments"]?.stringValue)
        XCTAssertEqual(try JSONValue(jsonString: arguments), ["m": "writing"])
        XCTAssertEqual(messages[3]["tool_call_id"]?.stringValue, "c1")
    }

    func testParsesToolCallsAndUsage() async throws {
        StubURLProtocol.reset(.init(body: jsonBody("""
        {"choices":[{"message":{"content":null,"tool_calls":[
           {"id":"call_9","type":"function","function":{"name":"set_mode","arguments":"{\\"mode\\":\\"building\\"}"}}]},
          "finish_reason":"tool_calls"}],
         "usage":{"prompt_tokens":5,"completion_tokens":3}}
        """)))
        let response = try await client().complete(user: "hi", tools: [LLMTool(name: "set_mode", description: "x")])
        XCTAssertEqual(response.text, "")
        XCTAssertEqual(response.stopReason, .toolUse)
        XCTAssertEqual(response.usage, LLMUsage(inputTokens: 5, outputTokens: 3))
        XCTAssertEqual(response.toolCalls, [LLMToolCall(id: "call_9", name: "set_mode", arguments: ["mode": "building"])])
    }

    func testToolCallsWithStopFinishReasonAreNormalised() async throws {
        StubURLProtocol.reset(.init(body: jsonBody("""
        {"choices":[{"message":{"tool_calls":[{"function":{"name":"f","arguments":""}}]},"finish_reason":"stop"}]}
        """)))
        let response = try await client().complete(user: "hi")
        XCTAssertEqual(response.stopReason, .toolUse)
        XCTAssertEqual(response.toolCalls, [LLMToolCall(id: "call_0", name: "f", arguments: [:])])
    }

    func testInvalidToolArgumentsThrow() async {
        StubURLProtocol.reset(.init(body: jsonBody("""
        {"choices":[{"message":{"tool_calls":[{"id":"a","function":{"name":"f","arguments":"{oops"}}]}}]}
        """)))
        do {
            _ = try await client().complete(user: "hi")
            XCTFail("expected error")
        } catch {
            guard case .invalidResponse = error as? LLMError else { return XCTFail("\(error)") }
        }
    }

    func testNoKeyMeansNoAuthorizationHeaderAndLocalHTTPIsAllowed() async throws {
        StubURLProtocol.reset(.init(body: jsonBody(#"{"choices":[{"message":{"content":"hi"}}]}"#)))
        let c = client(key: nil, base: URL(string: "http://localhost:11434/v1")!)
        let response = try await c.complete(user: "hi")
        XCTAssertEqual(response.text, "hi")
        XCTAssertNil(StubURLProtocol.requests[0].value(forHTTPHeaderField: "authorization"))
    }

    func testRefusesKeyOverPlainHTTPToRemoteHost() async {
        StubURLProtocol.reset(.init())
        do {
            _ = try await client(base: URL(string: "http://llm.example.com/v1")!).complete(user: "hi")
            XCTFail("expected error")
        } catch {
            guard case .invalidConfiguration = error as? LLMError else { return XCTFail("\(error)") }
        }
    }

    func testHTTPErrorIsRedacted() async {
        StubURLProtocol.reset(.init(
            status: 401,
            body: jsonBody(#"{"error":{"message":"Incorrect API key provided: \#(secret)."}}"#)))
        do {
            _ = try await client().complete(user: "hi")
            XCTFail("expected error")
        } catch let error as LLMError {
            guard case .http(let status, let message, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(status, 401)
            XCTAssertFalse(message.contains(secret))
            XCTAssertFalse(error.isRetryable)
            XCTAssertFalse((error.errorDescription ?? "").contains(secret))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testTimeout() async {
        StubURLProtocol.reset(.init(hang: true))
        do {
            _ = try await client().complete(LLMRequest(messages: [.user("hi")], timeout: 0.2))
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? LLMError, .timeout)
        }
    }
}
