import Foundation

public struct RecordingStopFinalizationInput: Equatable, Sendable {
    public var stopRequestedAt: Date
    public var lastSpeechDetectedAt: Date?
    public var minimumFlushDelay: TimeInterval
    public var requiredSpeechTailGap: TimeInterval
    public var maximumFlushDelay: TimeInterval

    public init(
        stopRequestedAt: Date,
        lastSpeechDetectedAt: Date?,
        minimumFlushDelay: TimeInterval,
        requiredSpeechTailGap: TimeInterval,
        maximumFlushDelay: TimeInterval
    ) {
        self.stopRequestedAt = stopRequestedAt
        self.lastSpeechDetectedAt = lastSpeechDetectedAt
        self.minimumFlushDelay = minimumFlushDelay
        self.requiredSpeechTailGap = requiredSpeechTailGap
        self.maximumFlushDelay = maximumFlushDelay
    }
}

public struct RecordingStopFinalizationDecision: Equatable, Sendable {
    public var delayBeforeTapRemoval: TimeInterval
    public var timeSinceLastSpeechAtStop: TimeInterval?

    public init(
        delayBeforeTapRemoval: TimeInterval,
        timeSinceLastSpeechAtStop: TimeInterval?
    ) {
        self.delayBeforeTapRemoval = delayBeforeTapRemoval
        self.timeSinceLastSpeechAtStop = timeSinceLastSpeechAtStop
    }
}

public enum RecordingStopFinalizationPolicy {
    public static func resolve(_ input: RecordingStopFinalizationInput) -> RecordingStopFinalizationDecision {
        let timeSinceLastSpeechAtStop: TimeInterval? = if let lastSpeechDetectedAt = input.lastSpeechDetectedAt {
            max(0, input.stopRequestedAt.timeIntervalSince(lastSpeechDetectedAt))
        } else {
            nil
        }

        let additionalTailDelay: TimeInterval = if let timeSinceLastSpeechAtStop {
            max(0, input.requiredSpeechTailGap - timeSinceLastSpeechAtStop)
        } else {
            0
        }

        let unclampedDelay = max(input.minimumFlushDelay, additionalTailDelay)
        let clampedDelay = min(input.maximumFlushDelay, unclampedDelay)

        return RecordingStopFinalizationDecision(
            delayBeforeTapRemoval: clampedDelay,
            timeSinceLastSpeechAtStop: timeSinceLastSpeechAtStop
        )
    }
}
