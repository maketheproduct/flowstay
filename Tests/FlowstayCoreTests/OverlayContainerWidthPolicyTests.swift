@testable import FlowstayCore
import XCTest

@MainActor
final class OverlayContainerWidthPolicyTests: XCTestCase {
    func testResolvesExpandedAndCollapsedWidths() {
        let widths = OverlayContainerWidthPolicy.resolve(
            OverlayContainerWidthInput(
                leftSegmentWidth: 34,
                centerGapWidth: 260,
                rightSegmentWidth: 34
            )
        )

        XCTAssertEqual(widths.expandedWidth, 328)
        XCTAssertEqual(widths.collapsedWidth, 294)
    }

    func testNonNotchCollapsedWidthEqualsLeftSegmentWhenCenterGapIsZero() {
        let widths = OverlayContainerWidthPolicy.resolve(
            OverlayContainerWidthInput(
                leftSegmentWidth: 34,
                centerGapWidth: 0,
                rightSegmentWidth: 34
            )
        )

        XCTAssertEqual(widths.expandedWidth, 68)
        XCTAssertEqual(widths.collapsedWidth, 34)
    }

    func testAnchoredOriginClampsUsingExpandedWidthBounds() {
        let clampedOrigin = OverlayContainerAnchorPolicy.resolveOriginX(
            OverlayContainerAnchorInput(
                proposedExpandedOriginX: 980,
                expandedWidth: 180,
                screenMinX: 0,
                screenMaxX: 1000,
                horizontalInset: 8
            )
        )

        XCTAssertEqual(clampedOrigin, 812)
    }
}
