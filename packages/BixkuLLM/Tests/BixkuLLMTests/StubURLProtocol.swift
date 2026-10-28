import Foundation
@testable import BixkuLLM
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Serves canned responses to a `URLSession` so HTTP clients are tested without a network.
final class StubURLProtocol: URLProtocol {
    struct Stub {
        var status: Int = 200
        var headers: [String: String] = ["content-type": "application/json"]
        var body: Data = Data()
        /// When true the request never completes (for timeout / cancellation tests).
        var hang = false
    }

    private static let lock = NSLock()
    private static var stub = Stub()
    private static var captured: [URLRequest] = []
    private static var capturedBodies: [Data] = []

    static func reset(_ stub: Stub) {
        lock.lock()
        defer { lock.unlock() }
        self.stub = stub
        captured = []
        capturedBodies = []
    }

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    static var bodies: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return capturedBodies
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        Self.lock.lock()
        Self.captured.append(request)
        Self.capturedBodies.append(body)
        let stub = Self.stub
        Self.lock.unlock()

        if stub.hang { return }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

func jsonBody(_ text: String) -> Data { Data(text.utf8) }

func sentBody(at index: Int = 0) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: StubURLProtocol.bodies[index])
}
