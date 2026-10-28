import BixkuCore
import Foundation
import XCTest
@testable import BixkuDock

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func sample(
    _ bundleID: String?,
    title: String? = nil,
    url: String? = nil,
    at offset: TimeInterval,
    idle: TimeInterval = 0
) -> ActivitySample {
    ActivitySample(
        appBundleID: bundleID,
        appName: bundleID?.split(separator: ".").last.map(String.init),
        windowTitle: title,
        url: url.flatMap(URL.init(string:)),
        timestamp: t0.addingTimeInterval(offset),
        idleSeconds: idle
    )
}

func notification(
    _ bundleID: String?,
    title: String = "Hello",
    body: String? = nil,
    category: NotificationCategory? = nil,
    timeSensitive: Bool = false,
    thread: String? = nil,
    at offset: TimeInterval = 0
) -> IncomingNotification {
    IncomingNotification(
        appBundleID: bundleID,
        appName: bundleID?.split(separator: ".").last.map(String.init),
        title: title,
        body: body,
        category: category,
        isTimeSensitive: timeSensitive,
        threadID: thread,
        timestamp: t0.addingTimeInterval(offset)
    )
}

func json(_ string: String) -> Data {
    Data(string.utf8)
}

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("bixku-dock-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A minimal valid mode.
func makeMode(_ id: ModeID, transitions: [ModeRule] = [], policy: NotificationPolicy = NotificationPolicy()) -> ModeDefinition {
    ModeDefinition(
        id: id,
        name: id.rawValue.capitalized,
        symbol: "circle",
        summary: "Test mode \(id)",
        notifications: policy,
        transitions: transitions
    )
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

/// Polls `condition` (real time) until it holds or `timeout` elapses.
func eventually(
    timeout: TimeInterval = 2,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @Sendable () async -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("Condition not met within \(timeout)s", file: file, line: line)
}
