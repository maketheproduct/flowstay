@testable import FlowstayCore
import XCTest

@MainActor
final class OverlayTopBarMetricsPolicyTests: XCTestCase {
    func testUsesVisibleTopInsetWhenAvailable() {
        let height = OverlayTopBarMetricsPolicy.resolveHeight(
            OverlayTopBarMetricsInput(
                visibleTopInset: 39,
                safeAreaTopInset: 22,
                minimumHeight: 24,
                maximumHeight: 48,
                fallbackHeight: 26
            )
        )

        XCTAssertEqual(height, 39)
    }

    func testFallsBackToSafeAreaInsetWhenVisibleInsetMissing() {
        let height = OverlayTopBarMetricsPolicy.resolveHeight(
            OverlayTopBarMetricsInput(
                visibleTopInset: 0,
                safeAreaTopInset: 38,
                minimumHeight: 24,
                maximumHeight: 48,
                fallbackHeight: 26
            )
        )

        XCTAssertEqual(height, 38)
    }

    func testFallsBackToConfiguredDefaultWhenNoInsetsProvided() {
        let height = OverlayTopBarMetricsPolicy.resolveHeight(
            OverlayTopBarMetricsInput(
                visibleTopInset: 0,
                safeAreaTopInset: 0,
                minimumHeight: 24,
                maximumHeight: 48,
                fallbackHeight: 26
            )
        )

        XCTAssertEqual(height, 26)
    }

    func testHeightIsClampedToBounds() {
        let tooSmall = OverlayTopBarMetricsPolicy.resolveHeight(
            OverlayTopBarMetricsInput(
                visibleTopInset: 10,
                safeAreaTopInset: 0,
                minimumHeight: 24,
                maximumHeight: 48,
                fallbackHeight: 26
            )
        )
        XCTAssertEqual(tooSmall, 24)

        let tooLarge = OverlayTopBarMetricsPolicy.resolveHeight(
            OverlayTopBarMetricsInput(
                visibleTopInset: 64,
                safeAreaTopInset: 0,
                minimumHeight: 24,
                maximumHeight: 48,
                fallbackHeight: 26
            )
        )
        XCTAssertEqual(tooLarge, 48)
    }
}
