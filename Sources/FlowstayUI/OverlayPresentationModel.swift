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
    @Published public var isRecording: Bool
    @Published public var audioLevel: Float
    @Published public var waveformSamples: [Float]

    public init(
        displayState: OverlayDisplayState,
        layoutMode: OverlayLayoutMode,
        rightSegmentMode: OverlayRightSegmentMode,
        metrics: OverlayNotchSafeMetrics,
        reduceMotion: Bool = false,
        isRecording: Bool = false,
        audioLevel: Float = 0,
        waveformSamples: [Float] = []
    ) {
        self.displayState = displayState
        self.layoutMode = layoutMode
        self.rightSegmentMode = rightSegmentMode
        self.metrics = metrics
        self.reduceMotion = reduceMotion
        self.isRecording = isRecording
        self.audioLevel = audioLevel
        self.waveformSamples = waveformSamples
    }
}
