import Foundation

public struct SpeechActivityInput: Equatable, Sendable {
    public var hasStrongSpeechSignal: Bool
    public var hasWeakSpeechSignal: Bool
    public var observedAt: Date
    public var lastStrongSpeechDetectedAt: Date?
    public var speechHangoverDuration: TimeInterval

    public init(
        hasStrongSpeechSignal: Bool,
        hasWeakSpeechSignal: Bool,
        observedAt: Date,
        lastStrongSpeechDetectedAt: Date?,
        speechHangoverDuration: TimeInterval
    ) {
        self.hasStrongSpeechSignal = hasStrongSpeechSignal
        self.hasWeakSpeechSignal = hasWeakSpeechSignal
        self.observedAt = observedAt
        self.lastStrongSpeechDetectedAt = lastStrongSpeechDetectedAt
        self.speechHangoverDuration = speechHangoverDuration
    }
}

public struct SpeechActivityDecision: Equatable, Sendable {
    public var hasAudioActivity: Bool
    public var shouldRefreshStrongSpeechAnchor: Bool
    public var shouldRefreshStopFinalizationAnchor: Bool

    public init(
        hasAudioActivity: Bool,
        shouldRefreshStrongSpeechAnchor: Bool,
        shouldRefreshStopFinalizationAnchor: Bool
    ) {
        self.hasAudioActivity = hasAudioActivity
        self.shouldRefreshStrongSpeechAnchor = shouldRefreshStrongSpeechAnchor
        self.shouldRefreshStopFinalizationAnchor = shouldRefreshStopFinalizationAnchor
    }
}

public enum SpeechActivityPolicy {
    public static func resolve(_ input: SpeechActivityInput) -> SpeechActivityDecision {
        if input.hasStrongSpeechSignal {
            return SpeechActivityDecision(
                hasAudioActivity: true,
                shouldRefreshStrongSpeechAnchor: true,
                shouldRefreshStopFinalizationAnchor: true
            )
        }

        if let lastStrongSpeechDetectedAt = input.lastStrongSpeechDetectedAt,
           input.observedAt.timeIntervalSince(lastStrongSpeechDetectedAt) <= input.speechHangoverDuration,
           input.hasWeakSpeechSignal
        {
            return SpeechActivityDecision(
                hasAudioActivity: true,
                shouldRefreshStrongSpeechAnchor: false,
                shouldRefreshStopFinalizationAnchor: true
            )
        }

        return SpeechActivityDecision(
            hasAudioActivity: false,
            shouldRefreshStrongSpeechAnchor: false,
            shouldRefreshStopFinalizationAnchor: false
        )
    }
}
