import Foundation

/// Severity of a log entry. Names match `general.log_level` in the config file.
public enum LogLevel: Int, Sendable, Codable, CaseIterable, Comparable, CustomStringConvertible {
    case trace, debug, info, warning, error

    /// Parses `trace | debug | info | warn | warning | error` (case-insensitive).
    public init?(name: String) {
        switch name.lowercased() {
        case "trace": self = .trace
        case "debug": self = .debug
        case "info": self = .info
        case "warn", "warning": self = .warning
        case "error": self = .error
        default: return nil
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String {
        switch self {
        case .trace: return "trace"
        case .debug: return "debug"
        case .info: return "info"
        case .warning: return "warn"
        case .error: return "error"
        }
    }
}

public struct LogEntry: Sendable, Equatable {
    public var timestamp: Date
    public var level: LogLevel
    /// Usually the module id that produced the entry.
    public var category: String
    public var message: String
    public var metadata: [String: String]

    public init(timestamp: Date, level: LogLevel, category: String, message: String, metadata: [String: String] = [:]) {
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.metadata = metadata
    }
}

/// Destination of log entries (stderr, a file, `os_log` on macOS, memory in tests...).
public protocol LogSink: Sendable {
    func write(_ entry: LogEntry)
}

/// Portable logger handed to each module through its ``ModuleContext``.
///
/// Named `BixkuLogger` to avoid clashing with `os.Logger` in macOS code.
public struct BixkuLogger: Sendable {
    public let category: String
    public let minimumLevel: LogLevel
    private let sink: any LogSink
    private let clock: any BixkuClock

    public init(category: String, minimumLevel: LogLevel = .info, sink: any LogSink, clock: any BixkuClock = SystemClock()) {
        self.category = category
        self.minimumLevel = minimumLevel
        self.sink = sink
        self.clock = clock
    }

    public func log(_ level: LogLevel, _ message: @autoclosure () -> String, metadata: [String: String] = [:]) {
        guard level >= minimumLevel else { return }
        sink.write(LogEntry(timestamp: clock.now(), level: level, category: category, message: message(), metadata: metadata))
    }

    public func trace(_ message: @autoclosure () -> String, metadata: [String: String] = [:]) {
        log(.trace, message(), metadata: metadata)
    }

    public func debug(_ message: @autoclosure () -> String, metadata: [String: String] = [:]) {
        log(.debug, message(), metadata: metadata)
    }

    public func info(_ message: @autoclosure () -> String, metadata: [String: String] = [:]) {
        log(.info, message(), metadata: metadata)
    }

    public func warning(_ message: @autoclosure () -> String, metadata: [String: String] = [:]) {
        log(.warning, message(), metadata: metadata)
    }

    public func error(_ message: @autoclosure () -> String, metadata: [String: String] = [:]) {
        log(.error, message(), metadata: metadata)
    }
}

/// Writes one line per entry to standard error.
public struct StandardErrorLogSink: LogSink {
    public init() {}

    public func write(_ entry: LogEntry) {
        let timestamp = ISO8601DateFormatter().string(from: entry.timestamp)
        var line = "\(timestamp) [\(entry.level)] \(entry.category): \(entry.message)"
        if !entry.metadata.isEmpty {
            line += " " + entry.metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

/// Drops every entry.
public struct DiscardingLogSink: LogSink {
    public init() {}
    public func write(_ entry: LogEntry) {}
}

/// Keeps entries in memory. Useful in tests and for an in-app log viewer.
public final class InMemoryLogSink: LogSink, @unchecked Sendable {
    private let storage = Locked<[LogEntry]>([])

    public init() {}

    public func write(_ entry: LogEntry) {
        storage.withLock { $0.append(entry) }
    }

    public var entries: [LogEntry] {
        storage.withLock { $0 }
    }
}
