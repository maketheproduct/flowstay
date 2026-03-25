@testable import FlowstayCore
import XCTest

@MainActor
final class RecordingStopFinalizationPolicyTests: XCTestCase {
    func testUsesMinimumDelayWhenNoRecentSpeechExists() {
        let now = Date()
        let decision = RecordingStopFinalizationPolicy.resolve(
            RecordingStopFinalizationInput(
                stopRequestedAt: now,
                lastSpeechDetectedAt: nil,
                minimumFlushDelay: 0.4,
                requiredSpeechTailGap: 0.65,
                maximumFlushDelay: 0.9
            )
        )

        XCTAssertEqual(decision.delayBeforeTapRemoval, 0.4, accuracy: 0.0001)
        XCTAssertNil(decision.timeSinceLastSpeechAtStop)
    }

    func testExtendsDelayWhenSpeechEndedVeryRecently() {
        let now = Date()
        let decision = RecordingStopFinalizationPolicy.resolve(
            RecordingStopFinalizationInput(
                stopRequestedAt: now,
                lastSpeechDetectedAt: now.addingTimeInterval(-0.1),
                minimumFlushDelay: 0.4,
                requiredSpeechTailGap: 0.65,
                maximumFlushDelay: 0.9
            )
        )

        XCTAssertEqual(decision.delayBeforeTapRemoval, 0.55, accuracy: 0.0001)
        XCTAssertEqual(decision.timeSinceLastSpeechAtStop ?? -1, 0.1, accuracy: 0.0001)
    }

    func testCapsDelayAtConfiguredMaximum() {
        let now = Date()
        let decision = RecordingStopFinalizationPolicy.resolve(
            RecordingStopFinalizationInput(
                stopRequestedAt: now,
                lastSpeechDetectedAt: now.addingTimeInterval(0.5),
                minimumFlushDelay: 0.4,
                requiredSpeechTailGap: 1.4,
                maximumFlushDelay: 0.9
            )
        )

        XCTAssertEqual(decision.delayBeforeTapRemoval, 0.9, accuracy: 0.0001)
    }

    func testFutureSpeechTimestampRequiresFullTailGapWhenWithinMaximum() {
        let now = Date()
        let decision = RecordingStopFinalizationPolicy.resolve(
            RecordingStopFinalizationInput(
                stopRequestedAt: now,
                lastSpeechDetectedAt: now.addingTimeInterval(0.15),
                minimumFlushDelay: 0.4,
                requiredSpeechTailGap: 0.65,
                maximumFlushDelay: 0.9
            )
        )

        XCTAssertEqual(decision.delayBeforeTapRemoval, 0.65, accuracy: 0.0001)
        XCTAssertEqual(decision.timeSinceLastSpeechAtStop ?? -1, 0, accuracy: 0.0001)
    }

    func testKeepsMinimumDelayWhenSpeechTailGapAlreadySatisfied() {
        let now = Date()
        let decision = RecordingStopFinalizationPolicy.resolve(
            RecordingStopFinalizationInput(
                stopRequestedAt: now,
                lastSpeechDetectedAt: now.addingTimeInterval(-1.0),
                minimumFlushDelay: 0.4,
                requiredSpeechTailGap: 0.65,
                maximumFlushDelay: 0.9
            )
        )

        XCTAssertEqual(decision.delayBeforeTapRemoval, 0.4, accuracy: 0.0001)
        XCTAssertEqual(decision.timeSinceLastSpeechAtStop ?? -1, 1.0, accuracy: 0.0001)
    }
}
