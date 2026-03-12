@testable import FlowstayPermissions
import XCTest

@MainActor
final class OnboardingSceneLayoutProfileTests: XCTestCase {
    func testSparseScenesUseNarrowerCenteredLayouts() {
        let welcome = OnboardingSceneLayoutProfile.resolve(for: .welcome)
        let quickSetup = OnboardingSceneLayoutProfile.resolve(for: .quickSetup)
        let done = OnboardingSceneLayoutProfile.resolve(for: .done)

        XCTAssertEqual(welcome.maxWidth, 560)
        XCTAssertEqual(quickSetup.maxWidth, 520)
        XCTAssertEqual(done.maxWidth, 500)
        XCTAssertEqual(welcome.containerAlignment, .center)
        XCTAssertEqual(done.containerAlignment, .center)
    }

    func testActionHeavyScenesStayTopAligned() {
        let readiness = OnboardingSceneLayoutProfile.resolve(for: .readiness)
        let firstWin = OnboardingSceneLayoutProfile.resolve(for: .firstWin)

        XCTAssertEqual(readiness.maxWidth, 560)
        XCTAssertEqual(firstWin.maxWidth, 620)
        XCTAssertEqual(readiness.containerAlignment, .top)
        XCTAssertEqual(firstWin.containerAlignment, .top)
    }
}
