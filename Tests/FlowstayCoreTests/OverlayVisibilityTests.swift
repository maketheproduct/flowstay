import XCTest

final class OverlayVisibilityTests: XCTestCase {
    func testOverlayVisibilityWhenRecordingAndEnabled() {
        let isRecording = true
        let showOverlay = true
        XCTAssertTrue(overlayShouldBeVisible(isRecording: isRecording, showOverlay: showOverlay))
    }

    func testOverlayVisibilityWhenNotRecording() {
        let isRecording = false
        let showOverlay = true
        XCTAssertFalse(overlayShouldBeVisible(isRecording: isRecording, showOverlay: showOverlay))
    }

    func testOverlayVisibilityWhenDisabled() {
        let isRecording = true
        let showOverlay = false
        XCTAssertFalse(overlayShouldBeVisible(isRecording: isRecording, showOverlay: showOverlay))
    }
}

private func overlayShouldBeVisible(isRecording: Bool, showOverlay: Bool) -> Bool {
    isRecording && showOverlay
}
