import XCTest
@testable import BixkuLLM

final class ConfigAndSecretsTests: XCTestCase {
    func testConfigFromExampleFields() throws {
        let config = try LLMConfig(fields: [
            "provider": "anthropic", "model": "m", "base_url": "",
            "api_key_env": "BIXKU_LLM_API_KEY", "request_timeout_seconds": "20",
        ])
        XCTAssertEqual(config.provider, .anthropic)
        XCTAssertNil(config.baseURL)
        XCTAssertEqual(config.apiKeySource, .environment("BIXKU_LLM_API_KEY"))
        XCTAssertEqual(config.requestTimeout, 20)
    }

    func testKeychainSourceAndDefaults() throws {
        let config = try LLMConfig(fields: [
            "provider": "openai-compatible", "model": "m", "base_url": "http://localhost:1234/v1",
            "api_key_keychain_service": "svc", "api_key_keychain_account": "acct",
        ])
        XCTAssertEqual(config.provider, .openAICompatible)
        XCTAssertEqual(config.apiKeySource, .keychain(service: "svc", account: "acct"))

        let fallback = try LLMConfig(fields: ["provider": "anthropic", "model": "m"])
        XCTAssertEqual(fallback.apiKeySource, .environment(LLMConfig.defaultAPIKeyEnvironmentVariable))
        XCTAssertEqual(try LLMConfig(fields: [:]).provider, LLMProvider.none)
    }

    func testRejectsKeyPastedIntoEnvName() {
        let pasted = "sk-ant-abcdef-0123456789"
        XCTAssertThrowsError(try LLMConfig(fields: ["provider": "anthropic", "model": "m", "api_key_env": pasted])) { error in
            guard case .invalidConfiguration(let message) = error as? LLMError else { return XCTFail("\(error)") }
            XCTAssertFalse(message.contains(pasted))
        }
    }

    func testRejectsBadValues() {
        XCTAssertThrowsError(try LLMConfig(fields: ["provider": "nope"]))
        XCTAssertThrowsError(try LLMConfig(fields: ["provider": "anthropic", "base_url": "ftp://x"]))
        XCTAssertThrowsError(try LLMConfig(fields: ["provider": "anthropic", "request_timeout_seconds": "-1"]))
        XCTAssertThrowsError(try LLMConfig(fields: ["provider": "anthropic", "max_tokens": "x"]))
    }

    func testFactory() throws {
        let secrets = EnvironmentSecretResolver(environment: ["K": " abc123456 \n"])
        let anthropic = try LLMClientFactory.makeClient(
            config: LLMConfig(provider: .anthropic, model: "m", apiKeySource: .environment("K")), secrets: secrets)
        XCTAssertTrue(anthropic is AnthropicClient)

        let local = try LLMClientFactory.makeClient(
            config: LLMConfig(provider: .openAICompatible, model: "m", baseURL: URL(string: "http://localhost:1/v1"),
                              apiKeySource: .none),
            secrets: secrets)
        XCTAssertTrue(local is OpenAICompatibleClient)

        XCTAssertThrowsError(try LLMClientFactory.makeClient(config: LLMConfig(provider: .none, model: "m"), secrets: secrets)) {
            XCTAssertEqual($0 as? LLMError, .disabled)
        }
        XCTAssertThrowsError(try LLMClientFactory.makeClient(
            config: LLMConfig(provider: .openAICompatible, model: "m", apiKeySource: .none), secrets: secrets))
        XCTAssertThrowsError(try LLMClientFactory.makeClient(
            config: LLMConfig(provider: .anthropic, model: "m", apiKeySource: .environment("MISSING")), secrets: secrets)) {
            XCTAssertEqual($0 as? LLMError, .missingAPIKey("environment variable MISSING"))
        }
        XCTAssertThrowsError(try LLMClientFactory.makeClient(config: LLMConfig(provider: .anthropic, model: ""), secrets: secrets))
    }

    func testEnvironmentResolverTrimsAndRejectsEmpty() throws {
        let resolver = EnvironmentSecretResolver(environment: ["A": "  key-value  ", "B": "   "])
        XCTAssertEqual(try resolver.apiKey(for: .environment("A")).reveal(), "key-value")
        XCTAssertThrowsError(try resolver.apiKey(for: .environment("B")))
        XCTAssertThrowsError(try resolver.apiKey(for: .none))
    }

    func testAPIKeyNeverPrints() {
        let key = APIKey("super-secret-value")
        XCTAssertFalse("\(key)".contains("super-secret"))
        XCTAssertFalse(String(reflecting: key).contains("super-secret"))
        var dumped = ""
        dump(key, to: &dumped)
        XCTAssertFalse(dumped.contains("super-secret"))
    }

    func testRedactor() {
        let bearer = String(repeating: "b", count: 16)
        let header = String(repeating: "h", count: 16)
        let json = String(repeating: "j", count: 16)
        let prefixed = "sk-ant-" + String(repeating: "p", count: 16)
        let redactor = SecretRedactor(secrets: ["custom-token-value"])
        let text = """
        key custom-token-value, Authorization: Bearer \(bearer), x-api-key: \(header),
        also \(prefixed) and {"api_key":"\(json)"} done
        """
        let out = redactor.redact(text)
        for leaked in ["custom-token-value", bearer, header, json, prefixed] {
            XCTAssertFalse(out.contains(leaked), "leaked a secret: \(out)")
        }
        XCTAssertTrue(out.contains("done"))
        XCTAssertEqual(redactor.redact("nothing to hide"), "nothing to hide")
    }
}
