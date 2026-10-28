import XCTest
@testable import BixkuLLM

final class AnthropicClientTests: XCTestCase {
    private let secret = "sk-ant-" + String(repeating: "y", count: 24)

    private func client(log: LLMLogSink? = nil) -> AnthropicClient {
        AnthropicClient(
            model: "test-model", apiKey: APIKey(secret), session: StubURLProtocol.session(), log: log)
    }

    func testBuildsRequestWithToolsAndMergedToolResults() async throws {
        StubURLProtocol.reset(.init(body: jsonBody(#"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#)))
        let tool = LLMTool(name: "set_mode", description: "Pick", parameters: ["type": "object", "properties": ["m": ["type": "string"]]])
        let call = LLMToolCall(id: "t1", name: "set_mode", arguments: ["m": "writing"])
        let request = LLMRequest(
            messages: [
                .system("Be brief."), .system("Be kind."),
                .user("classify"),
                .assistant("", toolCalls: [call]),
                .tool(callID: "t1", content: "done"),
                .user("thanks"),
            ],
            tools: [tool],
            toolChoice: .tool("set_mode"),
            temperature: 0.2
        )
        _ = try await client().complete(request)

        let sent = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(sent.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "x-api-key"), secret)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")

        let body = try sentBody()
        XCTAssertEqual(body["model"]?.stringValue, "test-model")
        XCTAssertEqual(body["max_tokens"]?.intValue, 1024)
        XCTAssertEqual(body["system"]?.stringValue, "Be brief.\n\nBe kind.")
        XCTAssertEqual(body["temperature"]?.doubleValue, 0.2)
        XCTAssertEqual(body["tool_choice"], ["type": "tool", "name": "set_mode"])
        XCTAssertEqual(body["tools"]?[0]?["input_schema"], tool.parameters)

        let messages = try XCTUnwrap(body["messages"]?.arrayValue)
        XCTAssertEqual(messages.map { $0["role"]?.stringValue }, ["user", "assistant", "user"])
        XCTAssertEqual(messages[1]["content"]?[0]?["type"]?.stringValue, "tool_use")
        XCTAssertEqual(messages[1]["content"]?[0]?["input"], ["m": "writing"])
        // tool_result comes first, the follow-up user text is merged after it.
        XCTAssertEqual(messages[2]["content"]?[0]?["type"]?.stringValue, "tool_result")
        XCTAssertEqual(messages[2]["content"]?[0]?["tool_use_id"]?.stringValue, "t1")
        XCTAssertEqual(messages[2]["content"]?[1]?["text"]?.stringValue, "thanks")
    }

    func testParsesTextToolUseAndUsage() async throws {
        StubURLProtocol.reset(.init(body: jsonBody("""
        {"content":[{"type":"text","text":"Switching."},
                    {"type":"tool_use","id":"toolu_1","name":"set_mode","input":{"mode":"building"}}],
         "stop_reason":"tool_use","usage":{"input_tokens":12,"output_tokens":7}}
        """)))
        let response = try await client().complete(user: "hi", tools: [LLMTool(name: "set_mode", description: "x")])
        XCTAssertEqual(response.text, "Switching.")
        XCTAssertEqual(response.stopReason, .toolUse)
        XCTAssertEqual(response.usage, LLMUsage(inputTokens: 12, outputTokens: 7))
        XCTAssertEqual(response.toolCalls, [LLMToolCall(id: "toolu_1", name: "set_mode", arguments: ["mode": "building"])])
    }

    func testHTTPErrorIsMappedAndRedacted() async {
        StubURLProtocol.reset(.init(
            status: 429,
            headers: ["retry-after": "7"],
            body: jsonBody(#"{"error":{"type":"rate_limit_error","message":"slow down for \#(secret)"}}"#)))
        do {
            _ = try await client().complete(user: "hi")
            XCTFail("expected error")
        } catch let error as LLMError {
            guard case .http(let status, let message, let retryAfter) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(status, 429)
            XCTAssertEqual(retryAfter, 7)
            XCTAssertFalse(message.contains(secret))
            XCTAssertTrue(message.contains("slow down"))
            XCTAssertTrue(error.isRetryable)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testLogsNeverContainKeyOrBody() async throws {
        StubURLProtocol.reset(.init(body: jsonBody(#"{"content":[{"type":"text","text":"SECRET-REPLY"}]}"#)))
        let lines = LockedBox<[String]>([])
        _ = try await client(log: { line in lines.withLock { $0.append(line) } }).complete(user: "PRIVATE-PROMPT")
        let joined = lines.withLock { $0.joined(separator: "\n") }
        XCTAssertFalse(joined.isEmpty)
        for needle in [secret, "PRIVATE-PROMPT", "SECRET-REPLY"] {
            XCTAssertFalse(joined.contains(needle))
        }
    }

    func testMalformedResponseThrows() async {
        StubURLProtocol.reset(.init(body: jsonBody("not json")))
        do {
            _ = try await client().complete(user: "hi")
            XCTFail("expected error")
        } catch {
            guard case .invalidResponse = error as? LLMError else { return XCTFail("\(error)") }
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

    func testCancellation() async {
        StubURLProtocol.reset(.init(hang: true))
        let c = client()
        let task = Task { try await c.complete(LLMRequest(messages: [.user("hi")], timeout: 30)) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testRefusesPlainHTTPToRemoteHost() async {
        StubURLProtocol.reset(.init())
        let c = AnthropicClient(model: "m", apiKey: APIKey(secret), baseURL: URL(string: "http://example.com")!,
                                session: StubURLProtocol.session())
        do {
            _ = try await c.complete(user: "hi")
            XCTFail("expected error")
        } catch {
            guard case .invalidConfiguration = error as? LLMError else { return XCTFail("\(error)") }
            XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        }
    }
}
