import FlowstayCore
import SwiftUI

public enum OverlayDisplayState: Equatable, Sendable {
    case recording
    case warming
    case processing
    case success
    case error
}

public enum OverlayLayoutMode: Equatable, Sendable {
    case splitAroundNotch
    case leftExtension
}

public struct OverlayNotchSafeMetrics: Equatable, Sendable {
    public let hasNotch: Bool
    public let centerGapWidth: CGFloat
    public let leftSegmentWidth: CGFloat
    public let rightSegmentWidth: CGFloat
    public let height: CGFloat
    public let iconSize: CGFloat
    public let bottomCornerRadius: CGFloat

    public var totalWidth: CGFloat {
        leftSegmentWidth + centerGapWidth + rightSegmentWidth
    }

    public init(
        hasNotch: Bool,
        centerGapWidth: CGFloat,
        leftSegmentWidth: CGFloat,
        rightSegmentWidth: CGFloat,
        height: CGFloat,
        iconSize: CGFloat,
        bottomCornerRadius: CGFloat
    ) {
        self.hasNotch = hasNotch
        self.centerGapWidth = centerGapWidth
        self.leftSegmentWidth = leftSegmentWidth
        self.rightSegmentWidth = rightSegmentWidth
        self.height = height
        self.iconSize = iconSize
        self.bottomCornerRadius = bottomCornerRadius
    }
}

public struct OverlayBubbleView: View {
    @ObservedObject var engineCoordinator: EngineCoordinatorViewModel
    @ObservedObject var presentation: OverlayPresentationModel

    @Environment(\.accessibilityReduceMotion) private var environmentReduceMotion
    @State private var rightOutroProgress: CGFloat = 0
    @State private var rightOutroOpacity: CGFloat = 1

    public init(
        engineCoordinator: EngineCoordinatorViewModel,
        presentation: OverlayPresentationModel
    ) {
        self.engineCoordinator = engineCoordinator
        self.presentation = presentation
    }

    public var body: some View {
        ZStack(alignment: .leading) {
            content
                .frame(width: contentWidth, height: metrics.height, alignment: .leading)
                .background(
                    BottomRoundedRect(radius: metrics.bottomCornerRadius)
                        .fill(.black)
                )
                .clipShape(BottomRoundedRect(radius: metrics.bottomCornerRadius))
        }
        .frame(maxWidth: .infinity, minHeight: metrics.height, maxHeight: metrics.height, alignment: .leading)
        .onAppear {
            resetRightOutroState()
        }
        .onChange(of: presentation.rightSegmentMode) { _, newValue in
            if newValue == .outro {
                startRightOutro()
            } else if newValue == .liveWave || newValue == .loading {
                resetRightOutroState()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var metrics: OverlayNotchSafeMetrics {
        presentation.metrics
    }

    private var reduceMotion: Bool {
        presentation.reduceMotion || environmentReduceMotion
    }

    private var content: some View {
        HStack(spacing: 0) {
            OverlayStateIcon(
                displayState: presentation.displayState,
                iconSize: metrics.iconSize,
                reduceMotion: reduceMotion
            )
            .frame(width: metrics.leftSegmentWidth, height: metrics.height)

            if presentation.layoutMode == .splitAroundNotch {
                Color.clear
                    .frame(width: metrics.centerGapWidth, height: metrics.height)

                rightSegment
                    .frame(width: metrics.rightSegmentWidth, height: metrics.height)
                    .clipped()
            } else {
                Color.clear
                    .frame(width: metrics.centerGapWidth, height: metrics.height)
            }
        }
    }

    @ViewBuilder
    private var rightSegment: some View {
        switch presentation.rightSegmentMode {
        case .hidden:
            Color.clear

        case .loading:
            LoadingPulseIcon(
                reduceMotion: reduceMotion,
                containerHeight: max(14, min(24, metrics.height - 6)),
                containerWidth: max(14, min(20, metrics.rightSegmentWidth - 10))
            )
            .opacity(0.95)

        case .liveWave, .outro:
            MiniWaveformIcon(
                level: engineCoordinator.audioLevel,
                waveformSamples: engineCoordinator.waveformSamples,
                isActive: engineCoordinator.isRecording || presentation.displayState == .recording,
                reduceMotion: reduceMotion,
                collapseProgress: rightOutroProgress,
                outroOpacity: rightOutroOpacity,
                barContainerHeight: max(14, min(24, metrics.height - 6)),
                barContainerWidth: max(14, min(20, metrics.rightSegmentWidth - 10))
            )
        }
    }

    private var contentWidth: CGFloat {
        let widths = OverlayContainerWidthPolicy.resolve(
            OverlayContainerWidthInput(
                leftSegmentWidth: metrics.leftSegmentWidth,
                centerGapWidth: metrics.centerGapWidth,
                rightSegmentWidth: metrics.rightSegmentWidth
            )
        )
        return switch presentation.layoutMode {
        case .splitAroundNotch:
            widths.expandedWidth
        case .leftExtension:
            widths.collapsedWidth
        }
    }

    private var accessibilityLabel: String {
        switch presentation.displayState {
        case .recording:
            "Transcribing"
        case .warming:
            "Warming up"
        case .processing:
            "Processing transcription"
        case .success:
            "Transcription complete"
        case .error:
            "Transcription failed"
        }
    }

    private func startRightOutro() {
        guard !reduceMotion else {
            rightOutroProgress = 1
            rightOutroOpacity = 0
            return
        }

        rightOutroProgress = 0
        rightOutroOpacity = 1

        withAnimation(.easeInOut(duration: OverlayAnimationTiming.rightOutroDuration)) {
            rightOutroProgress = 1
        }
        withAnimation(.easeOut(duration: OverlayAnimationTiming.rightOutroDuration)) {
            rightOutroOpacity = 0
        }
    }

    private func resetRightOutroState() {
        rightOutroProgress = 0
        rightOutroOpacity = 1
    }
}

private struct OverlayStateIcon: View {
    let displayState: OverlayDisplayState
    let iconSize: CGFloat
    let reduceMotion: Bool

    @State private var currentState: OverlayDisplayState
    @State private var outgoingState: OverlayDisplayState?
    @State private var morphProgress: CGFloat = 1
    @State private var morphToken = 0

    init(displayState: OverlayDisplayState, iconSize: CGFloat, reduceMotion: Bool) {
        self.displayState = displayState
        self.iconSize = iconSize
        self.reduceMotion = reduceMotion
        _currentState = State(initialValue: displayState)
    }

    var body: some View {
        ZStack {
            if let outgoingState {
                OverlayStateGlyph(
                    state: outgoingState,
                    iconSize: iconSize,
                    reduceMotion: reduceMotion
                )
                .scaleEffect(1 + (0.06 * morphProgress))
                .opacity(max(0, 1 - morphProgress))
                .blur(radius: reduceMotion ? 0 : (0.6 * morphProgress))
            }

            OverlayStateGlyph(
                state: currentState,
                iconSize: iconSize,
                reduceMotion: reduceMotion
            )
            .scaleEffect(incomingScale)
            .opacity(0.2 + (0.8 * morphProgress))
            .blur(radius: reduceMotion ? 0 : (0.35 * (1 - morphProgress)))
        }
        .frame(width: iconSize + 8, height: iconSize + 8, alignment: .center)
        .onChange(of: displayState) { _, newValue in
            startMorph(to: newValue)
        }
    }

    private var incomingScale: CGFloat {
        let base = 0.9 + (0.1 * morphProgress)
        guard !reduceMotion else { return base }

        let overshoot = max(0, sin(Double(max(0, morphProgress - 0.7)) * .pi * 3.6)) * 0.025
        return base + CGFloat(overshoot)
    }

    private func startMorph(to newState: OverlayDisplayState) {
        guard newState != currentState else { return }

        morphToken += 1
        let token = morphToken

        outgoingState = currentState
        currentState = newState
        morphProgress = 0

        if reduceMotion {
            withAnimation(.easeOut(duration: 0.13)) {
                morphProgress = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
                guard token == morphToken else { return }
                outgoingState = nil
            }
            return
        }

        withAnimation(.easeOut(duration: 0.07)) {
            morphProgress = 0.84
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
            guard token == morphToken else { return }
            withAnimation(.interpolatingSpring(stiffness: 520, damping: 27)) {
                morphProgress = 1
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard token == morphToken else { return }
            outgoingState = nil
        }
    }
}

private struct OverlayStateGlyph: View {
    let state: OverlayDisplayState
    let iconSize: CGFloat
    let reduceMotion: Bool

    var body: some View {
        Group {
            switch state {
            case .recording:
                Image(systemName: "mic.fill")
                    .font(.system(size: iconSize, weight: .semibold))

            case .warming, .processing:
                ProcessingSpinnerIcon(iconSize: iconSize, reduceMotion: reduceMotion)

            case .success:
                SuccessCheckIcon(iconSize: iconSize, reduceMotion: reduceMotion)

            case .error:
                Image(systemName: "xmark")
                    .font(.system(size: iconSize, weight: .bold))
            }
        }
        .foregroundStyle(.white)
    }
}

private struct ProcessingSpinnerIcon: View {
    let iconSize: CGFloat
    let reduceMotion: Bool

    @State private var rotating = false

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: iconSize, weight: .semibold))
            .rotationEffect(.degrees(rotating ? 360 : 0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 0.82).repeatForever(autoreverses: false)) {
                    rotating = true
                }
            }
    }
}

private struct SuccessCheckIcon: View {
    let iconSize: CGFloat
    let reduceMotion: Bool

    @State private var settled = false

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: iconSize, weight: .bold))
            .scaleEffect(settled ? 1.0 : 0.56)
            .opacity(settled ? 1.0 : 0.5)
            .onAppear {
                guard !reduceMotion else {
                    settled = true
                    return
                }
                withAnimation(.interpolatingSpring(stiffness: 420, damping: 18)) {
                    settled = true
                }
            }
    }
}

private struct LoadingPulseIcon: View {
    let reduceMotion: Bool
    let containerHeight: CGFloat
    let containerWidth: CGFloat

    var body: some View {
        if reduceMotion {
            bars(at: 0)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 40.0)) { timeline in
                bars(at: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func bars(at time: TimeInterval) -> some View {
        let phase = time * 4.4
        return HStack(spacing: 1.6) {
            ForEach(0 ..< 4, id: \.self) { index in
                let wave = 0.5 + 0.5 * sin(phase + Double(index) * 0.72)
                let height = max(3.0, 4.0 + wave * Double(containerHeight - 6))

                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.6 + 0.3 * wave))
                    .frame(width: 2.2, height: height)
            }
        }
        .frame(width: containerWidth, height: containerHeight, alignment: .center)
    }
}

private struct MiniWaveformIcon: View {
    let level: Float
    let waveformSamples: [Float]
    let isActive: Bool
    let reduceMotion: Bool
    let collapseProgress: CGFloat
    let outroOpacity: CGFloat
    let barContainerHeight: CGFloat
    let barContainerWidth: CGFloat

    var body: some View {
        Group {
            if reduceMotion {
                waveformBars(at: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 50.0)) { timeline in
                    waveformBars(at: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .opacity((isActive ? 0.96 : 0.18) * outroOpacity)
    }

    private func waveformBars(at time: TimeInterval) -> some View {
        let raw = max(0.0, Double(level))
        let clampedLevel = min(1.0, raw * 6.0)
        let levelNorm = min(1.0, max(0.0, pow(clampedLevel, 1.20)))
        let activity = isActive ? max(0.03, levelNorm) : 0.0

        let phase = time * (2.6 + activity * 0.95)
        let sampleBuckets = bucketedSamples(count: 6)
        let centerIndex = Double(sampleBuckets.count - 1) * 0.5
        let collapse = Double(max(0, min(1, collapseProgress)))
        let bounce = sin(collapse * .pi) * 0.14
        let maxHeight = Double(max(10, barContainerHeight))
        let dotHeight = 2.1
        let amplitudeRange = max(0, maxHeight - dotHeight)

        return HStack(spacing: 1.3) {
            ForEach(0 ..< sampleBuckets.count, id: \.self) { index in
                let sample = Double(sampleBuckets[index])
                let bucketNorm = min(1.0, max(0.0, sample * 2.0))
                let combined = min(1.0, max(0.0, (0.65 * bucketNorm) + (0.35 * levelNorm)))
                let jitter = 0.82 + 0.18 * sin(phase + Double(index) * 0.52)
                let height = max(dotHeight, dotHeight + (amplitudeRange * combined * jitter))
                let centered = Double(index) - centerIndex
                let direction = centered < 0 ? 1.0 : (centered > 0 ? -1.0 : 0.0)
                let travel = (abs(centered) + 0.5) * 2.3
                let inwardOffset = direction * travel * (collapse + bounce * collapse)

                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.72 + (0.22 * combined)))
                    .frame(width: 2.1, height: height)
                    .offset(x: inwardOffset)
                    .scaleEffect(
                        x: max(0.58, 1 - (collapse * 0.5)),
                        y: max(0.62, 1 - (collapse * 0.32))
                    )
                    .opacity(max(0, 1 - (collapse * 0.88)))
            }
        }
        .frame(width: barContainerWidth, height: barContainerHeight, alignment: .center)
    }

    private func bucketedSamples(count: Int) -> [Float] {
        if waveformSamples.isEmpty {
            return Array(repeating: 0, count: count)
        }

        let bucketSize = max(1, waveformSamples.count / count)
        var buckets: [Float] = []
        buckets.reserveCapacity(count)

        var index = 0
        while index < waveformSamples.count, buckets.count < count {
            let end = min(waveformSamples.count, index + bucketSize)
            var peak: Float = 0
            var i = index
            while i < end {
                peak = max(peak, abs(waveformSamples[i]))
                i += 1
            }
            buckets.append(min(1, peak))
            index = end
        }

        while buckets.count < count {
            buckets.append(0)
        }

        return buckets
    }
}

private struct BottomRoundedRect: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let clampedRadius = min(radius, rect.width * 0.5, rect.height)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - clampedRadius))
        path.addArc(
            center: CGPoint(x: rect.maxX - clampedRadius, y: rect.maxY - clampedRadius),
            radius: clampedRadius,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + clampedRadius, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + clampedRadius, y: rect.maxY - clampedRadius),
            radius: clampedRadius,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}
