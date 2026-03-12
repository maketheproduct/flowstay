@testable import FlowstayCore
import XCTest

@MainActor
final class OverlayVisibilityTests: XCTestCase {
    func testOverlayPhaseWhenRecordingAndEnabled() {
        XCTAssertEqual(
            OverlayVisibilityPolicy.resolve(makeInput(isRecording: true)),
            .recording
        )
    }

    func testOverlayPhaseWhenStartTransitionIsActive() {
        XCTAssertEqual(
            OverlayVisibilityPolicy.resolve(makeInput(isTransitioningToRecording: true)),
            .warming
        )
    }

    func testOverlayPhaseWhenHotkeyStartPending() {
        XCTAssertEqual(
            OverlayVisibilityPolicy.resolve(makeInput(isHotkeyStartPending: true)),
            .warming
        )
    }

    func testOverlayPhaseWhenQueuedWarmup() {
        XCTAssertEqual(
            OverlayVisibilityPolicy.resolve(makeInput(isQueuedWarmup: true)),
            .warming
        )
    }

    func testOverlayPhaseWhenProcessingAwaitingCompletion() {
        XCTAssertEqual(
            OverlayVisibilityPolicy.resolve(makeInput(isAwaitingCompletion: true)),
            .processing
        )
    }

    func testOverlayPhaseWhenDisabled() {
        XCTAssertEqual(
            OverlayVisibilityPolicy.resolve(
                makeInput(
                    overlayEnabled: false,
                    isRecording: true,
                    isTransitioningToRecording: true,
                    isHotkeyStartPending: true,
                    isQueuedWarmup: true,
                    isAwaitingCompletion: true,
                    outcomeState: .success,
                    outcomeVisibleUntil: Date().addingTimeInterval(1)
                )
            ),
            .hidden
        )
    }

    func testOverlayPhaseUsesSuccessOutcome() {
        XCTAssertEqual(
            OverlayVisibilityPolicy.resolve(
                makeInput(
                    outcomeState: .success,
                    outcomeVisibleUntil: Date().addingTimeInterval(1)
                )
            ),
            .outcomeSuccess
        )
    }

    func testOverlayPhaseUsesErrorOutcome() {
        XCTAssertEqual(
            OverlayVisibilityPolicy.resolve(
                makeInput(
                    outcomeState: .error,
                    outcomeVisibleUntil: Date().addingTimeInterval(1)
                )
            ),
            .outcomeError
        )
    }

    func testOverlayPhaseFallsToHiddenWhenOutcomeExpires() {
        XCTAssertEqual(
            OverlayVisibilityPolicy.resolve(
                makeInput(
                    outcomeState: .error,
                    outcomeVisibleUntil: Date().addingTimeInterval(-0.1)
                )
            ),
            .hidden
        )
    }

    func testProcessingTakesPriorityOverTransitionWarmup() {
        XCTAssertEqual(
            OverlayVisibilityPolicy.resolve(
                makeInput(
                    isTransitioningToRecording: true,
                    isAwaitingCompletion: true
                )
            ),
            .processing
        )
    }

    func testProcessingThenOutcomeDoesNotReenterWarmupOrRecording() {
        let now = Date()
        let phases = [
            OverlayVisibilityPolicy.resolve(makeInput(isRecording: true), now: now),
            OverlayVisibilityPolicy.resolve(makeInput(isAwaitingCompletion: true), now: now),
            OverlayVisibilityPolicy.resolve(
                makeInput(
                    outcomeState: .success,
                    outcomeVisibleUntil: now.addingTimeInterval(1.0)
                ),
                now: now
            ),
            OverlayVisibilityPolicy.resolve(makeInput(), now: now),
        ]

        XCTAssertEqual(phases, [.recording, .processing, .outcomeSuccess, .hidden])
        XCTAssertFalse(phases.contains(.warming))
    }

    func testOverlayEnablementAllowsRuntimeOverlayDuringOnboardingFirstWin() {
        XCTAssertTrue(
            OverlayEnablementPolicy.resolve(
                OverlayEnablementInput(
                    userPreferenceEnabled: true,
                    onboardingVisible: true,
                    onboardingOverlayMode: .followRuntime
                )
            )
        )
    }

    func testOverlayEnablementSuppressesOverlayForOtherOnboardingScenes() {
        XCTAssertFalse(
            OverlayEnablementPolicy.resolve(
                OverlayEnablementInput(
                    userPreferenceEnabled: true,
                    onboardingVisible: true,
                    onboardingOverlayMode: .suppressed
                )
            )
        )
    }

    private func makeInput(
        overlayEnabled: Bool = true,
        isRecording: Bool = false,
        isTransitioningToRecording: Bool = false,
        isHotkeyStartPending: Bool = false,
        isQueuedWarmup: Bool = false,
        isAwaitingCompletion: Bool = false,
        outcomeState: OverlayOutcomeState? = nil,
        outcomeVisibleUntil: Date? = nil
    ) -> OverlayVisibilityInput {
        OverlayVisibilityInput(
            overlayEnabled: overlayEnabled,
            isRecording: isRecording,
            isTransitioningToRecording: isTransitioningToRecording,
            isHotkeyStartPending: isHotkeyStartPending,
            isQueuedWarmup: isQueuedWarmup,
            isAwaitingCompletion: isAwaitingCompletion,
            outcomeState: outcomeState,
            outcomeVisibleUntil: outcomeVisibleUntil
        )
    }
}
