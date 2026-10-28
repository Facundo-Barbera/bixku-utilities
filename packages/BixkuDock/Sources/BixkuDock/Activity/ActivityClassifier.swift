import Foundation

/// What a classifier knows besides the sample itself.
public struct ClassificationContext: Sendable, Equatable {
    /// Most recent classified samples, oldest first (excluding the one being classified).
    public var recent: [ClassifiedActivity]
    /// Every available mode, so a classifier can suggest one.
    public var modes: [ModeDefinition]
    public var activeMode: ModeID?

    public init(recent: [ClassifiedActivity] = [], modes: [ModeDefinition] = [], activeMode: ModeID? = nil) {
        self.recent = recent
        self.modes = modes
        self.activeMode = activeMode
    }
}

/// Classifies one activity sample. Implementations never throw: when unsure they
/// return ``ActivityCategory/other`` with low confidence.
///
/// Classifiers see one sample at a time; duration weighting and hysteresis over time
/// are applied afterwards by ``ActivitySmoother`` so they work with any classifier.
public protocol ActivityClassifier: Sendable {
    func classify(_ sample: ActivitySample, context: ClassificationContext) async -> ActivityVerdict
}

/// A language-model classifier. Implemented by the LLM provider (outside this
/// package); used by ``HybridClassifier`` only when the rules are unsure.
///
/// Implementations should:
/// - return quickly (the hybrid classifier enforces a timeout and cancels the task);
/// - honor task cancellation;
/// - throw on transport / parsing errors (the hybrid classifier falls back to rules);
/// - only use `sample` fields they were given: privacy redaction happens before.
public protocol LLMClassifying: Sendable {
    func classify(
        _ sample: ActivitySample,
        recent: [ClassifiedActivity],
        modes: [ModeDefinition]
    ) async throws -> ActivityVerdict
}
