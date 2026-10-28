import BixkuDock
import Foundation

/// Size limits applied to everything received through the `bixku://notify` URL.
public struct NotifyLimits: Sendable, Equatable {
    /// Longest accepted URL, in characters (checked before anything is parsed).
    public var maxURLLength = 8 * 1024
    /// Most query items accepted.
    public var maxParameters = 16
    public var maxAppLength = 80
    public var maxTitleLength = 200
    public var maxSubtitleLength = 200
    public var maxBodyLength = 2_000
    public var maxThreadLength = 100

    public init() {}

    public static let standard = NotifyLimits()
}

/// Why a `bixku://notify` URL was rejected. Cases carry no payload on purpose: the
/// input is untrusted and must not end up in logs or UI through an error message.
public enum NotifyURLError: Error, Equatable, Sendable, CustomStringConvertible {
    case wrongScheme
    case unknownAction
    case tooLong
    case tooManyParameters
    case malformed
    case missingTitle

    public var description: String {
        switch self {
        case .wrongScheme: return "not a bixku:// URL"
        case .unknownAction: return "unknown action (only bixku://notify is supported)"
        case .tooLong: return "URL is too long"
        case .tooManyParameters: return "too many parameters"
        case .malformed: return "malformed URL"
        case .missingTitle: return "a non-empty title is required"
        }
    }
}

/// The `bixku://notify?app=&title=&body=&category=` URL scheme.
///
/// | Parameter  | Meaning                                                              |
/// |------------|----------------------------------------------------------------------|
/// | `title`    | Required. Notification title.                                        |
/// | `body`     | Optional text. Line breaks are kept.                                 |
/// | `subtitle` | Optional second line.                                                |
/// | `app`      | Optional display name of the sender (see below).                     |
/// | `category` | Optional ``NotificationCategory`` raw value; unknown values are ignored. |
/// | `thread`   | Optional conversation id, groups notifications in digests.           |
///
/// Any process, and any web page the user lets open the link, can send these URLs, so the
/// result is deliberately low-trust: the sender can never claim a bundle id (so rules that
/// match apps cannot be spoofed), never marks a notification time-sensitive, and every
/// string is sanitized and cut to ``NotifyLimits``. Unknown parameters are ignored and
/// the first occurrence of a repeated parameter wins.
public enum NotifyURL {
    public static let scheme = "bixku"
    public static let action = "notify"

    /// Parses and validates `url`. `now` and `id` are injectable for tests.
    public static func parse(
        _ url: URL,
        now: Date = Date(),
        limits: NotifyLimits = .standard,
        id: UUID = UUID()
    ) -> Result<IncomingNotification, NotifyURLError> {
        guard url.absoluteString.count <= limits.maxURLLength else { return .failure(.tooLong) }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.malformed)
        }
        guard components.scheme?.lowercased() == scheme else { return .failure(.wrongScheme) }
        guard components.host?.lowercased() == action else { return .failure(.unknownAction) }
        // `bixku://notify` carries everything in the query; reject anything else.
        guard components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil, components.path.isEmpty || components.path == "/"
        else { return .failure(.malformed) }

        let items = components.percentEncodedQueryItems ?? []
        guard items.count <= limits.maxParameters else { return .failure(.tooManyParameters) }

        var values: [String: String] = [:]
        for item in items {
            guard let name = item.name.removingPercentEncoding else { return .failure(.malformed) }
            guard let raw = item.value else { continue }
            // Decode `%XX` only; `+` is a literal plus (the builder always writes `%20`).
            guard let value = raw.removingPercentEncoding else { return .failure(.malformed) }
            if values[name.lowercased()] == nil { values[name.lowercased()] = value }
        }

        let title = NotifyTextSanitizer.clean(values["title"] ?? "", maxLength: limits.maxTitleLength)
        guard !title.isEmpty else { return .failure(.missingTitle) }

        return .success(IncomingNotification(
            id: id,
            appBundleID: nil,
            appName: optional(values["app"], maxLength: limits.maxAppLength),
            title: title,
            subtitle: optional(values["subtitle"], maxLength: limits.maxSubtitleLength),
            body: optional(values["body"], maxLength: limits.maxBodyLength, allowNewlines: true),
            category: values["category"].flatMap { category(from: $0) },
            isTimeSensitive: false,
            threadID: optional(values["thread"], maxLength: limits.maxThreadLength),
            timestamp: now
        ))
    }

    /// Builds a `bixku://notify` URL. Fields are percent-encoded; nothing is validated
    /// beyond what ``parse(_:now:limits:id:)`` does, so call it on the result to check.
    public static func make(
        title: String,
        body: String? = nil,
        subtitle: String? = nil,
        app: String? = nil,
        category: NotificationCategory? = nil,
        thread: String? = nil
    ) -> URL? {
        var query: [(String, String)] = [("title", title)]
        if let app { query.append(("app", app)) }
        if let subtitle { query.append(("subtitle", subtitle)) }
        if let body { query.append(("body", body)) }
        if let category { query.append(("category", category.rawValue)) }
        if let thread { query.append(("thread", thread)) }
        let encoded = query.map { "\($0.0)=\(percentEncode($0.1))" }.joined(separator: "&")
        return URL(string: "\(scheme)://\(action)?\(encoded)")
    }

    // MARK: - Helpers

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static func optional(_ raw: String?, maxLength: Int, allowNewlines: Bool = false) -> String? {
        guard let raw else { return nil }
        let cleaned = NotifyTextSanitizer.clean(raw, maxLength: maxLength, allowNewlines: allowNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func category(from raw: String) -> NotificationCategory? {
        NotificationCategory(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased())
    }
}

/// Sliding-window limiter for URL-delivered notifications, so a misbehaving sender (or a
/// page that keeps firing links) cannot flood triage and the digest.
public struct NotifyRateLimiter: Sendable {
    public let maxEvents: Int
    public let window: TimeInterval
    private var accepted: [Date] = []

    public init(maxEvents: Int = 30, window: TimeInterval = 60) {
        self.maxEvents = maxEvents
        self.window = window
    }

    /// Records an event at `now` and returns whether it is within the limit.
    /// Rejected events are not recorded, so the limit recovers as the window slides.
    public mutating func allow(at now: Date = Date()) -> Bool {
        accepted.removeAll { now.timeIntervalSince($0) >= window || $0 > now }
        guard accepted.count < maxEvents else { return false }
        accepted.append(now)
        return true
    }
}
