import Foundation

/// One observation of what the user is doing, produced by an ``ActivitySource``.
///
/// Sources emit a sample whenever the frontmost app, its focused window or document
/// changes, and periodically (so idle time and durations stay current). Fields that
/// the source cannot read (no permission) are `nil`.
public struct ActivitySample: Codable, Sendable, Equatable {
    /// Bundle identifier of the frontmost app (`com.apple.Terminal`).
    public var appBundleID: String?
    /// Localized name of the frontmost app.
    public var appName: String?
    /// Title of the focused window.
    public var windowTitle: String?
    /// URL of the focused browser tab, if the source can read it.
    public var url: URL?
    /// Document shown in the focused window, if any (file name or path).
    public var document: String?
    /// When the sample was taken.
    public var timestamp: Date
    /// Seconds since the last user input (keyboard / pointer) at `timestamp`.
    public var idleSeconds: TimeInterval

    public init(
        appBundleID: String?,
        appName: String? = nil,
        windowTitle: String? = nil,
        url: URL? = nil,
        document: String? = nil,
        timestamp: Date,
        idleSeconds: TimeInterval = 0
    ) {
        self.appBundleID = appBundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.url = url
        self.document = document
        self.timestamp = timestamp
        self.idleSeconds = idleSeconds
    }

    /// Lowercased host of ``url`` without a leading `www.`.
    public var urlHost: String? {
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Whether the user had been inactive for at least `threshold` seconds.
    public func isIdle(threshold: TimeInterval) -> Bool {
        idleSeconds >= threshold
    }

    /// Identity of what is on screen, ignoring time and idleness. Two samples with
    /// the same focus key show the same thing and classify the same way.
    public var focusKey: String {
        [appBundleID ?? "", windowTitle ?? "", url?.absoluteString ?? "", document ?? ""]
            .joined(separator: "\u{1F}")
    }

    /// A copy with the window title, URL and document removed (privacy redaction).
    public func redacted() -> ActivitySample {
        var copy = self
        copy.windowTitle = nil
        copy.url = nil
        copy.document = nil
        return copy
    }
}

/// Who produced a verdict or decision.
public enum VerdictSource: String, Codable, Sendable, CaseIterable {
    /// Deterministic rules.
    case rules
    /// A language model.
    case llm
    /// A cached language-model answer.
    case cache
    /// Rules, used because the language model was unavailable, too slow, or rate limited.
    case fallback
}

/// The classification of one ``ActivitySample``.
public struct ActivityVerdict: Codable, Sendable, Equatable {
    public var category: ActivityCategory
    /// How sure the classifier is, from 0 (guess) to 1 (certain).
    public var confidence: Double
    /// A mode the classifier thinks fits the activity. Advisory: the engine surfaces
    /// it in ``DockState/suggestedMode`` but never switches on it alone.
    public var suggestedMode: ModeID?
    /// Short human-readable explanation.
    public var rationale: String
    public var source: VerdictSource

    public init(
        category: ActivityCategory,
        confidence: Double,
        suggestedMode: ModeID? = nil,
        rationale: String,
        source: VerdictSource = .rules
    ) {
        self.category = category
        self.confidence = min(1, max(0, confidence))
        self.suggestedMode = suggestedMode
        self.rationale = rationale
        self.source = source
    }
}

/// A sample together with its verdict.
public struct ClassifiedActivity: Codable, Sendable, Equatable {
    public var sample: ActivitySample
    public var verdict: ActivityVerdict

    public init(sample: ActivitySample, verdict: ActivityVerdict) {
        self.sample = sample
        self.verdict = verdict
    }
}
