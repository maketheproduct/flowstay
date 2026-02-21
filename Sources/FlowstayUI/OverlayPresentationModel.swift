import Foundation
import SwiftUI

public enum OverlayRightSegmentMode: Equatable, Sendable {
    case liveWave
    case loading
    case outro
    case hidden
}

@MainActor
public final class OverlayPresentationModel: ObservableObject {
    @Published public var displayState: OverlayDisplayState
    @Published public var layoutMode: OverlayLayoutMode
    @Published public var rightSegmentMode: OverlayRightSegmentMode
    @Published public var metrics: OverlayNotchSafeMetrics
    @Published public var reduceMotion: Bool

    public init(
        displayState: OverlayDisplayState,
        layoutMode: OverlayLayoutMode,
        rightSegmentMode: OverlayRightSegmentMode,
        metrics: OverlayNotchSafeMetrics,
        reduceMotion: Bool = false
    ) {
        self.displayState = displayState
        self.layoutMode = layoutMode
        self.rightSegmentMode = rightSegmentMode
        self.metrics = metrics
        self.reduceMotion = reduceMotion
    }
}
