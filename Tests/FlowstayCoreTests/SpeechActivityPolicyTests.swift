@testable import FlowstayCore
import XCTest

@MainActor
final class SpeechActivityPolicyTests: XCTestCase {
    func testRefreshesBothAnchorsForStrongSpeech() {
        let now = Date()

        let decision = SpeechActivityPolicy.resolve(
            SpeechActivityInput(
                hasStrongSpeechSignal: true,
                hasWeakSpeechSignal: true,
                observedAt: now,
                lastStrongSpeechDetectedAt: now.addingTimeInterval(-5),
                speechHangoverDuration: 1.2
            )
        )

        XCTAssertEqual(
            decision,
            .init(
                hasAudioActivity: true,
                shouldRefreshStrongSpeechAnchor: true,
                shouldRefreshStopFinalizationAnchor: true
            )
        )
    }

    func testRefreshesOnlyStopAnchorForWeakTrailingSpeechWithinHangover() {
        let now = Date()

        let decision = SpeechActivityPolicy.resolve(
            SpeechActivityInput(
                hasStrongSpeechSignal: false,
                hasWeakSpeechSignal: true,
                observedAt: now,
                lastStrongSpeechDetectedAt: now.addingTimeInterval(-0.2),
                speechHangoverDuration: 1.2
            )
        )

        XCTAssertEqual(
            decision,
            .init(
                hasAudioActivity: true,
                shouldRefreshStrongSpeechAnchor: false,
                shouldRefreshStopFinalizationAnchor: true
            )
        )
    }

    func testRejectsWeakSignalOutsideHangover() {
        let now = Date()

        let decision = SpeechActivityPolicy.resolve(
            SpeechActivityInput(
                hasStrongSpeechSignal: false,
                hasWeakSpeechSignal: true,
                observedAt: now,
                lastStrongSpeechDetectedAt: now.addingTimeInterval(-1.3),
                speechHangoverDuration: 1.2
            )
        )

        XCTAssertEqual(
            decision,
            .init(
                hasAudioActivity: false,
                shouldRefreshStrongSpeechAnchor: false,
                shouldRefreshStopFinalizationAnchor: false
            )
        )
    }
}
