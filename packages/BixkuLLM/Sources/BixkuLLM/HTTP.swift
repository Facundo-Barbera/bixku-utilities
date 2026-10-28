import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct HTTPResult {
    var status: Int
    var headers: [String: String]
    var body: Data
}

/// Coordinates cancellation and the overall deadline of one `URLSessionDataTask`.
private final class TaskController: @unchecked Sendable {
    private struct State {
        var task: URLSessionDataTask?
        var cancelRequested = false
        var timedOut = false
    }

    private let state = LockedBox(State())

    func attach(_ task: URLSessionDataTask) {
        let alreadyCancelled = state.withLock { s -> Bool in
            s.task = task
            return s.cancelRequested
        }
        if alreadyCancelled { task.cancel() }
    }

    func cancel() {
        let task = state.withLock { s -> URLSessionDataTask? in
            s.cancelRequested = true
            return s.task
        }
        task?.cancel()
    }

    func expire() {
        let task = state.withLock { s -> URLSessionDataTask? in
            s.timedOut = true
            return s.task
        }
        task?.cancel()
    }

    var timedOut: Bool { state.withLock { $0.timedOut } }
}

enum HTTP {
    /// Sends `request` and returns the response whatever its status.
    /// Throws `CancellationError` on task cancellation and ``LLMError/timeout`` when
    /// `timeout` seconds pass without a complete response.
    static func send(
        _ request: URLRequest,
        session: URLSession,
        timeout: TimeInterval,
        redactor: SecretRedactor
    ) async throws -> HTTPResult {
        var request = request
        request.timeoutInterval = timeout
        let controller = TaskController()

        let timer = Task {
            try await Task.sleep(nanoseconds: UInt64(max(timeout, 0.001) * 1_000_000_000))
            controller.expire()
        }
        defer { timer.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResult, Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: classify(error, timedOut: controller.timedOut, redactor: redactor))
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        continuation.resume(throwing: LLMError.invalidResponse("not an HTTP response"))
                        return
                    }
                    var headers: [String: String] = [:]
                    for (key, value) in http.allHeaderFields {
                        if let key = key as? String, let value = value as? String {
                            headers[key.lowercased()] = value
                        }
                    }
                    continuation.resume(returning: HTTPResult(status: http.statusCode, headers: headers, body: data ?? Data()))
                }
                controller.attach(task)
                task.resume()
            }
        } onCancel: {
            controller.cancel()
        }
    }

    private static func classify(_ error: Error, timedOut: Bool, redactor: SecretRedactor) -> Error {
        if timedOut { return LLMError.timeout }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return CancellationError()
            case .timedOut: return LLMError.timeout
            default: return LLMError.transport(redactor.redact(urlError.localizedDescription))
            }
        }
        return LLMError.transport(redactor.redact(String(describing: error)))
    }

    /// Rejects endpoints that would send a key in clear text over the network.
    static func validateEndpoint(_ url: URL, sendsKey: Bool) throws {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            throw LLMError.invalidConfiguration("invalid endpoint URL")
        }
        switch scheme {
        case "https":
            return
        case "http":
            let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
            if sendsKey && !loopback {
                throw LLMError.invalidConfiguration("refusing to send an API key over plain http to a non-local host")
            }
        default:
            throw LLMError.invalidConfiguration("endpoint must be http(s)")
        }
    }

    /// Turns a non-2xx result into an ``LLMError/http(status:message:retryAfter:)``.
    static func httpError(_ result: HTTPResult, redactor: SecretRedactor) -> LLMError {
        var message = ""
        if let json = try? JSONDecoder().decode(JSONValue.self, from: result.body) {
            message = json["error"]?["message"]?.stringValue
                ?? json["error"]?.stringValue
                ?? json["message"]?.stringValue
                ?? ""
        }
        if message.isEmpty {
            message = String(String(decoding: result.body, as: UTF8.self).prefix(200))
        }
        let retryAfter = result.headers["retry-after"].flatMap { TimeInterval($0) }
        return .http(status: result.status, message: redactor.redact(message), retryAfter: retryAfter)
    }

    static func encodeBody(_ body: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(body)
    }

    static func appendPath(_ base: URL, _ path: String) -> URL {
        path.split(separator: "/").reduce(base) { $0.appendingPathComponent(String($1)) }
    }
}
