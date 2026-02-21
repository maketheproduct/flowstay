@testable import FlowstayCore
import XCTest

@MainActor
final class OverlayVisibilityTests: XCTestCase {
    func testOverlayPhaseWhenRecordingAndEnabled() {
        XCTAssertEqual(
            OverlayVisibilityPolicy.resolve(
                OverlayVisibilityInput(
                    overlayEnabled: true,
                    isRecording: true,
                    isHotkeyStartPending: false,
                    isQueuedWarmup: false,
                    isAwaitingCompletion: false,
                    outcomeState: nil,
                    outcomeVisibleUntil: nil
                )
            ),
            .recording
        )
    }

    func testOverlayPhaseWhenHotkeyStartPending() {
        XCTAssertEqual(
            OverlayVisibilityPolicy.resolve(
                OverlayVisibilityInput(
                    overlayEnabled: true,
                    isRecording: false,
                    isHotkeyStartPending: true,
                    isQueuedWarmup: false,
                    isAwaitingCompletion: false,
                    outcomeState: nil,
                    outcomeVisibleUntil: nil
                )
            ),
            .warming
        )
    }

    func testOverlayPhaseWhenQueuedWarmup() {
        XCTAssertEqual(
            OverlayVisibilityPolicy.resolve(
                OverlayVisibilityInput(
                    overlayEnabled: true,
                    isRecording: false,
                    isHotkeyStartPending: false,
                    isQueuedWarmup: true,
                    isAwaitingCompletion: false,
                    outcomeState: nil,
                    outcomeVisibleUntil: nil
                )
            ),
            .warming
        )
    }

    func testOverlayPhaseWhenProcessingAwaitingCompletion() {
        XCTAssertEqual(
            OverlayVisibilityPolicy.resolve(
                OverlayVisibilityInput(
                    overlayEnabled: true,
                    isRecording: false,
                    isHotkeyStartPending: false,
                    isQueuedWarmup: false,
                    isAwaitingCompletion: true,
                    outcomeState: nil,
                    outcomeVisibleUntil: nil
                )
            ),
            .processing
        )
    }

    func testOverlayPhaseWhenDisabled() {
        XCTAssertEqual(
            OverlayVisibilityPolicy.resolve(
                OverlayVisibilityInput(
                    overlayEnabled: false,
                    isRecording: true,
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
                OverlayVisibilityInput(
                    overlayEnabled: true,
                    isRecording: false,
                    isHotkeyStartPending: false,
                    isQueuedWarmup: false,
                    isAwaitingCompletion: false,
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
                OverlayVisibilityInput(
                    overlayEnabled: true,
                    isRecording: false,
                    isHotkeyStartPending: false,
                    isQueuedWarmup: false,
                    isAwaitingCompletion: false,
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
                OverlayVisibilityInput(
                    overlayEnabled: true,
                    isRecording: false,
                    isHotkeyStartPending: false,
                    isQueuedWarmup: false,
                    isAwaitingCompletion: false,
                    outcomeState: .error,
                    outcomeVisibleUntil: Date().addingTimeInterval(-0.1)
                )
            ),
            .hidden
        )
    }

    func testProcessingThenOutcomeDoesNotReenterWarmupOrRecording() {
        let now = Date()
        let timeline: [OverlayVisibilityInput] = [
            OverlayVisibilityInput(
                overlayEnabled: true,
                isRecording: true,
                isHotkeyStartPending: false,
                isQueuedWarmup: false,
                isAwaitingCompletion: false,
                outcomeState: nil,
                outcomeVisibleUntil: nil
            ),
            OverlayVisibilityInput(
                overlayEnabled: true,
                isRecording: false,
                isHotkeyStartPending: false,
                isQueuedWarmup: false,
                isAwaitingCompletion: true,
                outcomeState: nil,
                outcomeVisibleUntil: nil
            ),
            OverlayVisibilityInput(
                overlayEnabled: true,
                isRecording: false,
                isHotkeyStartPending: false,
                isQueuedWarmup: false,
                isAwaitingCompletion: false,
                outcomeState: .success,
                outcomeVisibleUntil: now.addingTimeInterval(1.0)
            ),
            OverlayVisibilityInput(
                overlayEnabled: true,
                isRecording: false,
                isHotkeyStartPending: false,
                isQueuedWarmup: false,
                isAwaitingCompletion: false,
                outcomeState: nil,
                outcomeVisibleUntil: nil
            ),
        ]

        let phases = timeline.map { OverlayVisibilityPolicy.resolve($0, now: now) }
        XCTAssertEqual(phases, [.recording, .processing, .outcomeSuccess, .hidden])
        XCTAssertFalse(phases.contains(.warming))
    }
}
