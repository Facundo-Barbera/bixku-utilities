import Foundation

/// One deterministic classification rule: samples matching `match` are `category`
/// with `confidence`.
public struct CategoryRule: Codable, Sendable, Equatable {
    /// Matched on apps, title keywords and URL hosts (categories are ignored).
    public var match: ActivityMatcher
    public var category: ActivityCategory
    public var confidence: Double

    public init(_ category: ActivityCategory, confidence: Double, match: ActivityMatcher) {
        self.category = category
        self.confidence = confidence
        self.match = match
    }
}

/// An ordered list of ``CategoryRule``s. Codable so the user (or the agent) can
/// extend it.
public struct CategoryRuleSet: Codable, Sendable, Equatable {
    public var rules: [CategoryRule]
    /// Confidence given to samples that no rule matches (category `other`).
    public var unknownConfidence: Double

    public init(rules: [CategoryRule], unknownConfidence: Double = 0.2) {
        self.rules = rules
        self.unknownConfidence = unknownConfidence
    }

    /// `self` with `extra` rules taking precedence on ties.
    public func adding(_ extra: [CategoryRule]) -> CategoryRuleSet {
        CategoryRuleSet(rules: extra + rules, unknownConfidence: unknownConfidence)
    }

    /// Well-known macOS apps and sites. Browsers are only `browsing` with low
    /// confidence, so URL/title rules (or the LLM) can refine them.
    public static let standard = CategoryRuleSet(rules: [
        // Sites (beat the browser's own `browsing` rule).
        CategoryRule(.meeting, confidence: 0.9, match: ActivityMatcher(urlHosts: ["meet.google.com", "zoom.us", "teams.microsoft.com", "whereby.com"])),
        CategoryRule(.code, confidence: 0.85, match: ActivityMatcher(urlHosts: [
            "github.com", "gitlab.com", "bitbucket.org", "stackoverflow.com", "developer.apple.com", "swift.org",
            "docs.rs", "npmjs.com", "pypi.org", "localhost", "127.0.0.1",
        ])),
        CategoryRule(.writing, confidence: 0.8, match: ActivityMatcher(urlHosts: ["docs.google.com", "notion.so", "overleaf.com", "hackmd.io"])),
        CategoryRule(.communication, confidence: 0.85, match: ActivityMatcher(urlHosts: [
            "mail.google.com", "outlook.live.com", "outlook.office.com", "app.slack.com", "web.whatsapp.com",
            "discord.com", "web.telegram.org", "messages.google.com",
        ])),
        CategoryRule(.media, confidence: 0.85, match: ActivityMatcher(urlHosts: [
            "youtube.com", "netflix.com", "twitch.tv", "open.spotify.com", "music.apple.com", "primevideo.com", "disneyplus.com",
        ])),
        CategoryRule(.media, confidence: 0.7, match: ActivityMatcher(urlHosts: [
            "x.com", "twitter.com", "reddit.com", "instagram.com", "facebook.com", "tiktok.com", "news.ycombinator.com",
        ])),
        // Window titles.
        CategoryRule(.meeting, confidence: 0.85, match: ActivityMatcher(titleKeywords: ["Zoom Meeting", "Google Meet", "Microsoft Teams meeting"])),
        CategoryRule(.writing, confidence: 0.75, match: ActivityMatcher(titleKeywords: ["Google Docs", "Overleaf"])),
        CategoryRule(.code, confidence: 0.7, match: ActivityMatcher(titleKeywords: ["Pull Request", "Stack Overflow"])),
        CategoryRule(.communication, confidence: 0.7, match: ActivityMatcher(titleKeywords: ["Gmail", "Inbox"])),
        CategoryRule(.media, confidence: 0.7, match: ActivityMatcher(titleKeywords: ["YouTube", "Netflix", "Twitch"])),
        // Apps.
        CategoryRule(.meeting, confidence: 0.95, match: ActivityMatcher(apps: [
            "us.zoom.xos", "com.apple.FaceTime", "Cisco-Systems.Spark", "com.microsoft.teams2",
        ])),
        CategoryRule(.code, confidence: 0.9, match: ActivityMatcher(apps: [
            "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.apple.Terminal",
            "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "com.jetbrains.*", "dev.zed.Zed",
            "com.todesktop.230313mzl4w4u92", "com.panic.Nova", "com.sublimetext.4", "com.github.GitHubClient",
            "com.fournova.Tower3", "com.docker.docker", "com.postmanlabs.mac", "net.kovidgoyal.kitty",
            "org.alacritty", "com.github.wez.wezterm",
        ])),
        CategoryRule(.writing, confidence: 0.9, match: ActivityMatcher(apps: [
            "com.apple.iWork.Pages", "com.microsoft.Word", "com.ulyssesapp.mac", "pro.writer.mac", "md.obsidian",
            "abnerworks.Typora", "net.shinyfrog.bear", "com.literatureandlatte.scrivener3", "notion.id",
        ])),
        CategoryRule(.writing, confidence: 0.75, match: ActivityMatcher(apps: ["com.apple.Notes", "com.apple.TextEdit"])),
        CategoryRule(.communication, confidence: 0.9, match: ActivityMatcher(apps: [
            "com.tinyspeck.slackmacgap", "com.apple.MobileSMS", "com.apple.mail", "com.hnc.Discord",
            "ru.keepcoder.Telegram", "net.whatsapp.WhatsApp", "com.microsoft.Outlook", "org.whispersystems.signal-desktop",
        ])),
        CategoryRule(.media, confidence: 0.9, match: ActivityMatcher(apps: [
            "com.apple.Music", "com.spotify.client", "com.apple.TV", "org.videolan.vlc", "com.colliderli.iina",
            "com.valvesoftware.steam", "com.apple.podcasts",
        ])),
        CategoryRule(.browsing, confidence: 0.5, match: ActivityMatcher(apps: [
            "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "company.thebrowser.Browser",
            "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
        ])),
    ])
}

/// Deterministic, instant classifier: the highest-confidence matching
/// ``CategoryRule`` wins (earlier rules win ties).
public struct RuleBasedClassifier: ActivityClassifier {
    public var ruleSet: CategoryRuleSet

    public init(ruleSet: CategoryRuleSet = .standard) {
        self.ruleSet = ruleSet
    }

    public func classify(_ sample: ActivitySample, context: ClassificationContext) async -> ActivityVerdict {
        verdict(for: sample)
    }

    /// Synchronous classification.
    public func verdict(for sample: ActivitySample) -> ActivityVerdict {
        guard sample.appBundleID != nil || sample.url != nil || sample.windowTitle != nil else {
            return ActivityVerdict(category: .other, confidence: 0.1, rationale: "nothing known about the foreground app")
        }
        var best: CategoryRule?
        for rule in ruleSet.rules where rule.match.matches(sample, category: nil) {
            if best == nil || rule.confidence > best!.confidence {
                best = rule
            }
        }
        guard let best else {
            let name = sample.appName ?? sample.appBundleID ?? "this app"
            return ActivityVerdict(category: .other, confidence: ruleSet.unknownConfidence, rationale: "no rule for \(name)")
        }
        return ActivityVerdict(
            category: best.category,
            confidence: best.confidence,
            rationale: "\(Self.explain(best.match, sample)) → \(best.category)"
        )
    }

    /// Which criterion of `matcher` matched `sample`.
    static func explain(_ matcher: ActivityMatcher, _ sample: ActivitySample) -> String {
        if AppPattern.matchesAny(matcher.apps, bundleID: sample.appBundleID) {
            return "app \(sample.appName ?? sample.appBundleID ?? "?")"
        }
        if let host = sample.urlHost, matcher.urlHosts.contains(where: { HostPattern.matches($0, host: host) }) {
            return "site \(host)"
        }
        let haystack = [sample.windowTitle, sample.document].compactMap { $0 }.joined(separator: "\n")
        if let keyword = matcher.titleKeywords.first(where: { !$0.isEmpty && haystack.localizedCaseInsensitiveContains($0) }) {
            return "title contains \"\(keyword)\""
        }
        return "rule"
    }
}
