# LLM layer (`packages/BixkuLLM`)

A small, provider-agnostic chat/tool-calling layer shared by modules (the Dock
classifier, the mode agent, ...). It is a portable SwiftPM package (Foundation only, no
third-party dependencies) that builds and tests on Linux and macOS.

## API

```swift
let client = try LLMClientFactory.makeClient(config: config)   // any LLMClient

let tool = LLMTool(
    name: "set_mode",
    description: "Switch the active mode",
    parameters: ["type": "object",
                 "properties": ["mode": ["type": "string"]],
                 "required": ["mode"]])        // JSON schema

let response = try await client.complete(
    LLMRequest(messages: [.system("..."), .user("...")],
               tools: [tool], toolChoice: .tool("set_mode"), timeout: 10))

if let call = response.toolCall(named: "set_mode") {
    let args = try call.decodeArguments(SetModeArgs.self)
}
```

- `LLMMessage` roles: `system`, `user`, `assistant` (optionally with `toolCalls`) and
  `tool` (answers a call by `toolCallID`). Run tools yourself and send the result back as
  a `.tool` message.
- `LLMToolChoice`: `auto`, `none`, `required`, `tool(name)`.
- Errors are `LLMError` (`isRetryable` tells transient failures apart). Per-request
  `timeout` throws `.timeout`; cancelling the task throws `CancellationError` and aborts
  the HTTP request.
- `ScriptedLLM` replays queued responses (or runs a handler) and records requests; use it
  in module tests instead of the network.

## Providers

| `provider` | Client | Endpoint |
| --- | --- | --- |
| `anthropic` | `AnthropicClient` | `POST {base_url or https://api.anthropic.com}/v1/messages` |
| `openai-compatible` | `OpenAICompatibleClient` | `POST {base_url}/chat/completions` (`base_url` required, include `/v1`) |
| `none` | - | factory throws `LLMError.disabled` |

Plain `http://` is accepted only for loopback hosts when a key is configured.

## Configuration and secrets

The `[llm]` table in `config.example.toml` maps to `LLMConfig(fields:)`. The config holds
only a *reference* to the key:

- `api_key_env`: the **name** of an environment variable (default `BIXKU_LLM_API_KEY`).
  Values that are not valid variable names are rejected, so a pasted key is never
  accepted or echoed.
- `api_key_keychain_service` / `api_key_keychain_account`: a macOS Keychain
  generic-password item (macOS only).

Keys live in `APIKey`, which prints as `APIKey(<redacted>)`. Clients log one line per
request (method, path, status, latency) with no bodies, and every log line and error
message passes through `SecretRedactor`, which masks the configured key plus common key
patterns (`sk-...`, `Bearer ...`, `x-api-key: ...`).

## Tests

`cd packages/BixkuLLM && swift test`. HTTP clients are tested through a `URLProtocol`
stub, so no network or server is needed.
