@testable import FlowstayCore
import XCTest

@MainActor
final class HotkeyStartPolicyTests: XCTestCase {
    func testAcceptedEventEnablesPendingStartIndicatorWhenStartIsPossible() {
        XCTAssertTrue(
            HotkeyStartPolicy.shouldShowStartPendingOnAccepted(
                isRecording: false,
                isAwaitingCompletion: false,
                permissionsGranted: true,
                modelsDownloaded: true
            )
        )
    }

    func testAcceptedEventDoesNotEnablePendingStartWhenHardBlocked() {
        XCTAssertFalse(
            HotkeyStartPolicy.shouldShowStartPendingOnAccepted(
                isRecording: false,
                isAwaitingCompletion: false,
                permissionsGranted: false,
                modelsDownloaded: true
            )
        )
        XCTAssertFalse(
            HotkeyStartPolicy.shouldShowStartPendingOnAccepted(
                isRecording: false,
                isAwaitingCompletion: false,
                permissionsGranted: true,
                modelsDownloaded: false
            )
        )
        XCTAssertFalse(
            HotkeyStartPolicy.shouldShowStartPendingOnAccepted(
                isRecording: true,
                isAwaitingCompletion: false,
                permissionsGranted: true,
                modelsDownloaded: true
            )
        )
        XCTAssertFalse(
            HotkeyStartPolicy.shouldShowStartPendingOnAccepted(
                isRecording: false,
                isAwaitingCompletion: true,
                permissionsGranted: true,
                modelsDownloaded: true
            )
        )
    }

    func testQueuesWhenModelsDownloadedButNotReady() {
        let decision = HotkeyStartPolicy.onToggle(
            HotkeyStartInput(
                isRecording: false,
                isTransitioning: false,
                isAwaitingCompletion: false,
                permissionsGranted: true,
                modelsDownloaded: true,
                modelsReady: false,
                queuedStartRequest: false
            )
        )

        XCTAssertEqual(decision.queuedStartRequest, true)
        XCTAssertEqual(decision.actions, [.queueWarmup, .blocked(.queued)])
    }

    func testAutoStartsWhenQueuedAndModelsBecomeReady() {
        let decision = HotkeyStartPolicy.onModelsReady(queuedStartRequest: true, modelsReady: true)

        XCTAssertEqual(decision.queuedStartRequest, false)
        XCTAssertEqual(decision.actions, [.startRecording])
    }

    func testSecondPressCancelsQueuedStart() {
        let decision = HotkeyStartPolicy.onToggle(
            HotkeyStartInput(
                isRecording: false,
                isTransitioning: false,
                isAwaitingCompletion: false,
                permissionsGranted: true,
                modelsDownloaded: true,
                modelsReady: false,
                queuedStartRequest: true
            )
        )

        XCTAssertEqual(decision.queuedStartRequest, false)
        XCTAssertEqual(decision.actions, [.cancelQueuedWarmup])
    }

    func testWarmupTimeoutTransitionsToError() {
        let decision = HotkeyStartPolicy.onWarmupTimeout(queuedStartRequest: true)

        XCTAssertEqual(decision.queuedStartRequest, false)
        XCTAssertEqual(decision.actions, [.blocked(.error)])
    }

    func testBlockedTransitionEmitsFeedback() {
        let decision = HotkeyStartPolicy.onToggle(
            HotkeyStartInput(
                isRecording: false,
                isTransitioning: true,
                isAwaitingCompletion: false,
                permissionsGranted: true,
                modelsDownloaded: true,
                modelsReady: true,
                queuedStartRequest: false
            )
        )

        XCTAssertEqual(decision.queuedStartRequest, false)
        XCTAssertEqual(decision.actions, [.blocked(.blockedTransition)])
    }

    func testAwaitingCompletionBlocksStartAndPreventsQueue() {
        let decision = HotkeyStartPolicy.onToggle(
            HotkeyStartInput(
                isRecording: false,
                isTransitioning: false,
                isAwaitingCompletion: true,
                permissionsGranted: true,
                modelsDownloaded: true,
                modelsReady: true,
                queuedStartRequest: false
            )
        )

        XCTAssertEqual(decision.queuedStartRequest, false)
        XCTAssertEqual(decision.actions, [.blocked(.blockedTransition)])
    }
}
