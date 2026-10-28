import Foundation
import XCTest
@testable import BixkuCore

/// Records lifecycle calls across modules, in order.
final class LifecycleLog: @unchecked Sendable {
    private let calls = Locked<[String]>([])

    func record(_ call: String) {
        calls.withLock { $0.append(call) }
    }

    var entries: [String] {
        calls.withLock { $0 }
    }
}

struct TestFailure: Error, CustomStringConvertible {
    var description: String { "boom" }
}

final class TestModule: BixkuModule, @unchecked Sendable {
    let manifest: ModuleManifest
    private let log: LifecycleLog
    private let failOnStart: Bool
    private let lastContext = Locked<ModuleContext?>(nil)

    init(_ id: ModuleID, dependsOn dependencies: [ModuleID] = [], log: LifecycleLog = LifecycleLog(), failOnStart: Bool = false) {
        self.manifest = ModuleManifest(
            id: id,
            displayName: id.rawValue,
            summary: "Test module",
            version: "1.0.0",
            dependencies: dependencies
        )
        self.log = log
        self.failOnStart = failOnStart
    }

    var context: ModuleContext? {
        lastContext.withLock { $0 }
    }

    func start(context: ModuleContext) async throws {
        log.record("start \(manifest.id)")
        if failOnStart { throw TestFailure() }
        lastContext.withLock { $0 = context }
    }

    func stop() async {
        log.record("stop \(manifest.id)")
    }
}

func quietEnvironment(eventBus: EventBus = EventBus()) -> ModuleEnvironment {
    ModuleEnvironment(eventBus: eventBus, logSink: DiscardingLogSink())
}

/// Collects the first `count` elements of `stream`, failing after `timeout` seconds.
func collect<Element: Sendable>(
    _ stream: AsyncStream<Element>,
    count: Int,
    timeout: TimeInterval = 2,
    file: StaticString = #filePath,
    line: UInt = #line
) async -> [Element] {
    await withTaskGroup(of: [Element]?.self) { group in
        group.addTask {
            var result: [Element] = []
            for await element in stream {
                result.append(element)
                if result.count == count { break }
            }
            return result
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        guard let result = first else {
            XCTFail("Timed out waiting for \(count) elements", file: file, line: line)
            return []
        }
        if result.count < count {
            XCTFail("Stream ended after \(result.count) of \(count) elements", file: file, line: line)
        }
        return result
    }
}

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("bixku-core-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Asserts that `body` throws `expected`.
func assertThrows<E: Error & Equatable>(
    _ expected: E,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        XCTFail("Expected \(expected) to be thrown", file: file, line: line)
    } catch let error as E {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error \(error)", file: file, line: line)
    }
}
