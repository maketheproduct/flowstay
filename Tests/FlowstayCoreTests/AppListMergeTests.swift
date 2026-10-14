@testable import FlowstayCore
import XCTest

final class AppListMergeTests: XCTestCase {
    private func app(_ bundleId: String, _ name: String) -> DetectedApp {
        DetectedApp(bundleId: bundleId, name: name, icon: nil)
    }

    func testSortsCaseInsensitivelyAndDropsDuplicates() {
        let merged = AppDetectionService.mergeApps(
            [
                app("com.zoom", "zoom.us"),
                app("com.safari", "Safari"),
                app("com.iterm", "iTerm"),
                app("com.safari", "Safari"),
                app("com.arc", "Arc"),
            ],
            excluding: nil
        )

        XCTAssertEqual(merged.map(\.name), ["Arc", "iTerm", "Safari", "zoom.us"])
    }

    func testExcludesFlowstay() {
        let merged = AppDetectionService.mergeApps(
            [app("com.flowstay.Flowstay", "Flowstay"), app("com.notes", "Notes")],
            excluding: "com.flowstay.Flowstay"
        )

        XCTAssertEqual(merged.map(\.bundleId), ["com.notes"])
    }
}
