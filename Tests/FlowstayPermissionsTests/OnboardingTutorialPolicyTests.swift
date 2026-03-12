import XCTest
@testable import FlowstayPermissions

@MainActor
final class OnboardingTutorialPolicyTests: XCTestCase {
    func testToggleRecordingPressAlwaysStopsWhenRecordingIsActive() {
        let shouldStop = ToggleShortcutHandlingPolicy.shouldStopToggleRecording(
            tutorialStep: .toggleRecording,
            activeMode: .toggle,
            isRecording: true
        )
        XCTAssertTrue(shouldStop)
    }

    func testToggleStopPromptPressAlsoStopsWhenRecordingIsActive() {
        let shouldStop = ToggleShortcutHandlingPolicy.shouldStopToggleRecording(
            tutorialStep: .toggleStopPrompt,
            activeMode: .toggle,
            isRecording: true
        )
        XCTAssertTrue(shouldStop)
    }

    func testTogglePressDoesNotStopOutsideToggleModeOrRecordingState() {
        let holdModeStop = ToggleShortcutHandlingPolicy.shouldStopToggleRecording(
            tutorialStep: .toggleRecording,
            activeMode: .hold,
            isRecording: true
        )
        XCTAssertFalse(holdModeStop)

        let notRecordingStop = ToggleShortcutHandlingPolicy.shouldStopToggleRecording(
            tutorialStep: .toggleRecording,
            activeMode: .toggle,
            isRecording: false
        )
        XCTAssertFalse(notRecordingStop)
    }

    func testTogglePressDebounceRejectsRapidRepeatButAcceptsNormalInterval() {
        let firstPress = Date()
        let acceptsInitial = ToggleShortcutHandlingPolicy.shouldAcceptPress(
            now: firstPress,
            lastHandledAt: nil
        )
        let rejectsRapidRepeat = ToggleShortcutHandlingPolicy.shouldAcceptPress(
            now: firstPress.addingTimeInterval(0.05),
            lastHandledAt: firstPress
        )
        let acceptsAfterInterval = ToggleShortcutHandlingPolicy.shouldAcceptPress(
            now: firstPress.addingTimeInterval(0.25),
            lastHandledAt: firstPress
        )

        XCTAssertTrue(acceptsInitial)
        XCTAssertFalse(rejectsRapidRepeat)
        XCTAssertTrue(acceptsAfterInterval)
    }

    func testToggleShortcutTargetsStayHighlightedBeforePressAndLatchWhileRecording() {
        XCTAssertEqual(
            TutorialKeyVisualStatePolicy.resolve(
                tutorialStep: .toggleStartPrompt,
                activeMode: nil,
                isRecording: false,
                isTogglePressFeedbackActive: false,
                isHoldPressed: false
            ),
            .target
        )

        XCTAssertEqual(
            TutorialKeyVisualStatePolicy.resolve(
                tutorialStep: .toggleRecording,
                activeMode: .toggle,
                isRecording: true,
                isTogglePressFeedbackActive: false,
                isHoldPressed: false
            ),
            .pressed
        )
    }

    func testHoldShortcutHighlightsTargetAndUsesPhysicalPressState() {
        XCTAssertEqual(
            TutorialKeyVisualStatePolicy.resolve(
                tutorialStep: .holdStartPrompt,
                activeMode: nil,
                isRecording: false,
                isTogglePressFeedbackActive: false,
                isHoldPressed: false
            ),
            .target
        )

        XCTAssertEqual(
            TutorialKeyVisualStatePolicy.resolve(
                tutorialStep: .holdRecording,
                activeMode: .hold,
                isRecording: true,
                isTogglePressFeedbackActive: false,
                isHoldPressed: true
            ),
            .pressed
        )
    }
}
