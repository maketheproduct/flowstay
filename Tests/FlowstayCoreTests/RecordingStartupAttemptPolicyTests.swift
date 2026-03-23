@testable import FlowstayCore
import XCTest

@MainActor
final class RecordingStartupAttemptPolicyTests: XCTestCase {
    func testPendingMarkerRequiresRecognizerAndReadyModels() {
        XCTAssertTrue(
            RecordingStartupAttemptPolicy.shouldMarkPending(
                recognizerAvailable: true,
                modelsReady: true
            )
        )
        XCTAssertFalse(
            RecordingStartupAttemptPolicy.shouldMarkPending(
                recognizerAvailable: false,
                modelsReady: true
            )
        )
        XCTAssertFalse(
            RecordingStartupAttemptPolicy.shouldMarkPending(
                recognizerAvailable: true,
                modelsReady: false
            )
        )
    }
}
