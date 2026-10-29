import BixkuCore
import BixkuDock
import Foundation

/// One applied catalog change. `before`/`after` are `nil` when the mode did not
/// exist (creation) or no longer exists (deletion). A `before` with provenance
/// ``ModeProvenance/factory`` means the change created a user override.
public struct ModeHistoryEntry: Codable, Sendable, Equatable, Identifiable {
    /// Monotonic, starting at 1.
    public var version: Int
    public var modeID: ModeID
    public var before: ModeDefinition?
    public var beforeProvenance: ModeProvenance?
    public var after: ModeDefinition?
    /// Proposal that produced it (`nil` for reverts).
    public var proposalID: UUID?
    /// Set when this entry reverts another one.
    public var revertsVersion: Int?
    public var summary: String
    public var appliedAt: Date

    public var id: Int { version }

    public init(
        version: Int,
        modeID: ModeID,
        before: ModeDefinition?,
        beforeProvenance: ModeProvenance?,
        after: ModeDefinition?,
        proposalID: UUID?,
        revertsVersion: Int? = nil,
        summary: String,
        appliedAt: Date
    ) {
        self.version = version
        self.modeID = modeID
        self.before = before
        self.beforeProvenance = beforeProvenance
        self.after = after
        self.proposalID = proposalID
        self.revertsVersion = revertsVersion
        self.summary = summary
        self.appliedAt = appliedAt
    }
}

/// Persistence for the history (one JSON document). `nil` storage keeps it in memory.
public actor ModeHistory {
    public static let storageKey = "agent.history"
    /// Oldest entries are dropped beyond this.
    public let limit: Int
    private let storage: (any ModuleStorage)?
    private var entries: [ModeHistoryEntry] = []
    private var nextVersion = 1
    private var loaded = false

    public init(storage: (any ModuleStorage)? = nil, limit: Int = 200) {
        self.storage = storage
        self.limit = max(1, limit)
    }

    /// Newest last.
    public func all() async throws -> [ModeHistoryEntry] {
        try await loadIfNeeded()
        return entries
    }

    public func entry(_ version: Int) async throws -> ModeHistoryEntry? {
        try await loadIfNeeded()
        return entries.first { $0.version == version }
    }

    /// Appends an entry, assigning its version.
    @discardableResult
    public func record(
        modeID: ModeID,
        before: ModeDefinition?,
        beforeProvenance: ModeProvenance?,
        after: ModeDefinition?,
        proposalID: UUID?,
        revertsVersion: Int? = nil,
        summary: String,
        at date: Date
    ) async throws -> ModeHistoryEntry {
        try await loadIfNeeded()
        let entry = ModeHistoryEntry(
            version: nextVersion,
            modeID: modeID,
            before: before,
            beforeProvenance: beforeProvenance,
            after: after,
            proposalID: proposalID,
            revertsVersion: revertsVersion,
            summary: summary,
            appliedAt: date
        )
        nextVersion += 1
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        try await persist()
        return entry
    }

    private struct Document: Codable {
        var nextVersion: Int
        var entries: [ModeHistoryEntry]
    }

    private func loadIfNeeded() async throws {
        guard !loaded else { return }
        loaded = true
        guard let storage, let data = try await storage.data(forKey: Self.storageKey) else { return }
        let document = try JSONDecoder().decode(Document.self, from: data)
        entries = document.entries
        nextVersion = max(document.nextVersion, (entries.last?.version ?? 0) + 1)
    }

    private func persist() async throws {
        guard let storage else { return }
        let data = try JSONEncoder().encode(Document(nextVersion: nextVersion, entries: entries))
        try await storage.setData(data, forKey: Self.storageKey)
    }
}
