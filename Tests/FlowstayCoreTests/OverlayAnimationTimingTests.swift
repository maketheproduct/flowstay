@testable import FlowstayCore
import XCTest

@MainActor
final class OverlayAnimationTimingTests: XCTestCase {
    func testRightOutroDurationUsesSharedBudget() {
        // Guard against regressions where controller collapse timing becomes shorter
        // than the SwiftUI outro visual budget.
        XCTAssertEqual(OverlayAnimationTiming.rightOutroDuration, 0.26, accuracy: 0.001)
    }

    func testBouncyResizeTimingConstantsAreNonZero() {
        XCTAssertGreaterThan(OverlayAnimationTiming.resizeBouncePhaseOneDuration, 0)
        XCTAssertGreaterThan(OverlayAnimationTiming.resizeBouncePhaseTwoDuration, 0)
        XCTAssertGreaterThan(OverlayAnimationTiming.resizeOvershootFraction, 0)
    }

    func testReduceMotionResizeTimingIsNonZero() {
        XCTAssertGreaterThan(OverlayAnimationTiming.resizeReducedMotionDuration, 0)
    }
}
