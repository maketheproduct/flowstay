@testable import FlowstayCore
import XCTest

@MainActor
final class OverlayTransitionPolicyTests: XCTestCase {
    func testIconOnlyTransitionsDoNotRequestContainerChanges() {
        let decision = OverlayTransitionPolicy.decide(
            from: .processing,
            to: .success,
            container: .leftOnly,
            rightOutroCompleted: true
        )

        XCTAssertTrue(decision.iconOnlyUpdate)
        XCTAssertEqual(decision.containerChange, .none)
    }

    func testRightSideFoldsOnlyAfterOutroCompletion() {
        let beforeOutro = OverlayTransitionPolicy.decide(
            from: .recording,
            to: .processing,
            container: .split,
            rightOutroCompleted: false
        )
        XCTAssertEqual(beforeOutro.containerChange, .beginRightOutro)
        XCTAssertFalse(beforeOutro.iconOnlyUpdate)

        let afterOutro = OverlayTransitionPolicy.decide(
            from: .recording,
            to: .processing,
            container: .split,
            rightOutroCompleted: true
        )
        XCTAssertEqual(afterOutro.containerChange, .collapseRightAfterOutro)
        XCTAssertFalse(afterOutro.iconOnlyUpdate)
    }

    func testLeftSideFoldsOnlyOnFinalHide() {
        let intermediateState = OverlayTransitionPolicy.decide(
            from: .success,
            to: .error,
            container: .leftOnly,
            rightOutroCompleted: true
        )
        XCTAssertEqual(intermediateState.containerChange, .none)

        let hideDecision = OverlayTransitionPolicy.decide(
            from: .success,
            to: .hidden,
            container: .leftOnly,
            rightOutroCompleted: true
        )
        XCTAssertEqual(hideDecision.containerChange, .foldLeftForHide)
    }
}
