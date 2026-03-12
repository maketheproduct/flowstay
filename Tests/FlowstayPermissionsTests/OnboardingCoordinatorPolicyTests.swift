import XCTest
@testable import FlowstayPermissions

final class OnboardingCoordinatorPolicyTests: XCTestCase {
    func testWelcomeAlwaysAllowsAdvance() {
        XCTAssertTrue(
            OnboardingCoordinator.canAdvance(
                scene: .welcome,
                requiredSetupComplete: false,
                firstWinCompleted: false,
                isRecordingFirstWin: false
            )
        )
    }

    func testReadinessRequiresRequiredSetupCompletion() {
        XCTAssertFalse(
            OnboardingCoordinator.canAdvance(
                scene: .readiness,
                requiredSetupComplete: false,
                firstWinCompleted: false,
                isRecordingFirstWin: false
            )
        )

        XCTAssertTrue(
            OnboardingCoordinator.canAdvance(
                scene: .readiness,
                requiredSetupComplete: true,
                firstWinCompleted: false,
                isRecordingFirstWin: false
            )
        )
    }

    func testFirstWinRequiresCompletedCaptureAndNoRecordingInProgress() {
        XCTAssertFalse(
            OnboardingCoordinator.canAdvance(
                scene: .firstWin,
                requiredSetupComplete: true,
                firstWinCompleted: false,
                isRecordingFirstWin: false
            )
        )

        XCTAssertFalse(
            OnboardingCoordinator.canAdvance(
                scene: .firstWin,
                requiredSetupComplete: true,
                firstWinCompleted: true,
                isRecordingFirstWin: true
            )
        )

        XCTAssertTrue(
            OnboardingCoordinator.canAdvance(
                scene: .firstWin,
                requiredSetupComplete: true,
                firstWinCompleted: true,
                isRecordingFirstWin: false
            )
        )
    }

    func testQuickSetupAlwaysAllowsAdvance() {
        XCTAssertTrue(
            OnboardingCoordinator.canAdvance(
                scene: .quickSetup,
                requiredSetupComplete: true,
                firstWinCompleted: false,
                isRecordingFirstWin: false
            )
        )
    }

    func testDoneNeverAllowsAdvance() {
        XCTAssertFalse(
            OnboardingCoordinator.canAdvance(
                scene: .done,
                requiredSetupComplete: true,
                firstWinCompleted: true,
                isRecordingFirstWin: false
            )
        )
    }

    func testCompletionRequiresDoneSceneAndRequiredMilestones() {
        XCTAssertFalse(
            OnboardingCoordinator.canCompleteOnboarding(
                scene: .quickSetup,
                requiredSetupComplete: true,
                firstWinCompleted: true
            )
        )

        XCTAssertFalse(
            OnboardingCoordinator.canCompleteOnboarding(
                scene: .done,
                requiredSetupComplete: false,
                firstWinCompleted: true
            )
        )

        XCTAssertFalse(
            OnboardingCoordinator.canCompleteOnboarding(
                scene: .done,
                requiredSetupComplete: true,
                firstWinCompleted: false
            )
        )

        XCTAssertTrue(
            OnboardingCoordinator.canCompleteOnboarding(
                scene: .done,
                requiredSetupComplete: true,
                firstWinCompleted: true
            )
        )
    }
}
