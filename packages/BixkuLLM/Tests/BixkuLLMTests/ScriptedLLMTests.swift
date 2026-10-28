import XCTest
@testable import BixkuLLM

final class ScriptedLLMTests: XCTestCase {
    func testRepliesInOrderAndRecordsRequests() async throws {
        let llm = ScriptedLLM(responses: [.text("one"), .text("two")])
        let a = try await llm.complete(system: "sys", user: "hi")
        let b = try await llm.complete(user: "again")
        XCTAssertEqual(a.text, "one")
        XCTAssertEqual(b.text, "two")
        XCTAssertEqual(llm.callCount, 2)
        XCTAssertEqual(llm.remaining, 0)
        XCTAssertEqual(llm.requests[0].messages, [.system("sys"), .user("hi")])
        XCTAssertEqual(llm.requests[1].messages, [.user("again")])
    }

    func testExhaustedScriptThrows() async {
        let llm = ScriptedLLM()
        do {
            _ = try await llm.complete(user: "x")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? LLMError, .scriptExhausted)
        }
    }

    func testFailStepThrowsItsError() async {
        let llm = ScriptedLLM([.fail(LLMError.timeout)])
        do {
            _ = try await llm.complete(user: "x")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? LLMError, .timeout)
        }
    }

    func testToolCallResponse() async throws {
        struct Args: Decodable, Equatable { var mode: String; var confidence: Double }
        let call = LLMToolCall(id: "c1", name: "set_mode", arguments: ["mode": "writing", "confidence": 0.9])
        let llm = ScriptedLLM(responses: [.toolCalls([call])])
        let tool = LLMTool(name: "set_mode", description: "Pick a mode")
        let response = try await llm.complete(user: "x", tools: [tool], toolChoice: .tool("set_mode"))
        XCTAssertEqual(response.stopReason, .toolUse)
        let found = try XCTUnwrap(response.toolCall(named: "set_mode"))
        XCTAssertEqual(try found.decodeArguments(Args.self), Args(mode: "writing", confidence: 0.9))
        XCTAssertEqual(llm.requests[0].toolChoice, .tool("set_mode"))
        XCTAssertEqual(llm.requests[0].tools, [tool])
    }

    func testHandlerSeesRequest() async throws {
        let llm = ScriptedLLM { request in
            .text("echo: \(request.messages.last?.content ?? "")")
        }
        let response = try await llm.complete(user: "ping")
        XCTAssertEqual(response.text, "echo: ping")
    }

    func testCancellationDuringDelay() async {
        let llm = ScriptedLLM(responses: [.text("late")], delay: 5)
        let task = Task { try await llm.complete(user: "x") }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
