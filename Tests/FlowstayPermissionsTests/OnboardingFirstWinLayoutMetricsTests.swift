import CoreGraphics
import XCTest
@testable import FlowstayPermissions

@MainActor
final class OnboardingFirstWinLayoutMetricsTests: XCTestCase {
    func testLayoutFitsExpectedSceneHeightsWithoutClipping() {
        let standardMetrics = OnboardingFirstWinLayoutMetrics.make(availableHeight: 520)
        let standardRequiredHeight = standardMetrics.requiredSceneContentHeight
        XCTAssertLessThanOrEqual(standardRequiredHeight, 520)

        let constrainedMetrics = OnboardingFirstWinLayoutMetrics.make(availableHeight: 500)
        let constrainedRequiredHeight = constrainedMetrics.requiredSceneContentHeight
        XCTAssertLessThanOrEqual(constrainedRequiredHeight, 500)
    }

    func testTranscriptHeightClampsToConfiguredBounds() {
        let largeMetrics = OnboardingFirstWinLayoutMetrics.make(availableHeight: 900)
        let maxTranscriptHeight = OnboardingFirstWinLayoutMetrics.maxTranscriptHeight
        let largeTranscriptHeight = largeMetrics.transcriptHeight
        XCTAssertEqual(largeTranscriptHeight, maxTranscriptHeight)

        let tightMetrics = OnboardingFirstWinLayoutMetrics.make(availableHeight: 300)
        let minTranscriptHeight = OnboardingFirstWinLayoutMetrics.minTranscriptHeight
        let tightTranscriptHeight = tightMetrics.transcriptHeight
        XCTAssertEqual(tightTranscriptHeight, minTranscriptHeight)
    }
}
