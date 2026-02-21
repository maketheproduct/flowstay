@testable import FlowstayCore
import XCTest

@MainActor
final class InitializationOrderingTests: XCTestCase {
    func testShortcutInitializationOccursBeforePrewarmStep() {
        let plan = InitializationOrderingPolicy.makePlan(
            permissionsGranted: true,
            onboardingCompleted: true
        )

        guard let shortcutIndex = plan.steps.firstIndex(of: .initializeShortcuts),
              let prewarmIndex = plan.steps.firstIndex(of: .startModelPrewarmInBackground)
        else {
            XCTFail("Expected both shortcut and prewarm steps")
            return
        }

        XCTAssertLessThan(shortcutIndex, prewarmIndex)
    }

    func testListenerReadinessDoesNotBlockOnPrewarmCompletion() {
        let plan = InitializationOrderingPolicy.makePlan(
            permissionsGranted: true,
            onboardingCompleted: true
        )

        XCTAssertTrue(plan.listenerReadyWithoutPrewarmCompletion)
        XCTAssertEqual(plan.steps.first, .checkPermissions)
    }
}
