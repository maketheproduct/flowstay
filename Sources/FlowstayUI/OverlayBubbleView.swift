import FlowstayCore
import SwiftUI

public struct OverlayBubbleView: View {
    @ObservedObject var engineCoordinator: EngineCoordinatorViewModel

    let onDragStart: () -> Void
    let onDragChange: (CGSize) -> Void
    let onDragEnd: (CGSize, CGSize) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var didStartDrag = false

    public init(
        engineCoordinator: EngineCoordinatorViewModel,
        onDragStart: @escaping () -> Void,
        onDragChange: @escaping (CGSize) -> Void,
        onDragEnd: @escaping (CGSize, CGSize) -> Void
    ) {
        self.engineCoordinator = engineCoordinator
        self.onDragStart = onDragStart
        self.onDragChange = onDragChange
        self.onDragEnd = onDragEnd
    }

    public var body: some View {
        WaveformOrbView(
            level: engineCoordinator.audioLevel,
            waveformSamples: engineCoordinator.waveformSamples,
            isActive: engineCoordinator.isRecording,
            reduceMotion: reduceMotion
        )
        .frame(width: 52, height: 52)
        .contentShape(Circle())
        .gesture(dragGesture)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !didStartDrag {
                    didStartDrag = true
                    onDragStart()
                }
                onDragChange(value.translation)
            }
            .onEnded { value in
                onDragEnd(value.translation, value.predictedEndTranslation)
                didStartDrag = false
            }
    }

    private var isMicActive: Bool {
        engineCoordinator.audioLevel > 0.08
    }

    private var accessibilityLabel: String {
        if engineCoordinator.isRecording {
            return "Transcribing"
        }
        return isMicActive ? "Mic active" : "Mic idle"
    }
}

private struct WaveformOrbView: View {
    let level: Float
    let waveformSamples: [Float]
    let isActive: Bool
    let reduceMotion: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Circle()
                .fill(.bar)

            if reduceMotion {
                waveformBars(at: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 45.0)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    waveformBars(at: time)
                }
            }
        }
        .opacity(isActive ? 1.0 : 0.0)
    }

    private func waveformBars(at time: TimeInterval) -> some View {
        let raw = max(0.0005, Double(level))
        let boosted = min(1.0, pow(raw * 6.0, 0.9))
        let activity = isActive ? max(0.05, boosted) : 0.0

        let phase = time * (1.8 + activity * 0.6)
        let sampleBuckets = bucketedSamples(count: 5)
        return HStack(spacing: 3) {
            ForEach(0 ..< 5, id: \.self) { index in
                let sample = Double(sampleBuckets[index])
                let mod = 0.9 + 0.1 * sin(phase + Double(index) * 0.5)
                let height = max(2, 2 + (28 * sample * mod))

                Capsule(style: .continuous)
                    .fill(waveformBarColor(activity: activity))
                    .frame(width: 3, height: height)
            }
        }
        .shadow(color: waveformShadowColor, radius: 5, x: 0, y: 0)
        .frame(width: 30, height: 16)
    }

    private func waveformBarColor(activity: Double) -> Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.6 + (0.35 * activity))
        }
        return Color.black.opacity(0.45 + (0.4 * activity))
    }

    private var waveformShadowColor: Color {
        colorScheme == .dark ? Color.blue.opacity(0.18) : Color.black.opacity(0.14)
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
            var sum: Float = 0
            var bucketCount: Float = 0
            var i = index
            while i < end {
                sum += waveformSamples[i]
                bucketCount += 1
                i += 1
            }
            buckets.append(bucketCount > 0 ? (sum / bucketCount) : 0)
            index = end
        }

        while buckets.count < count {
            buckets.append(0)
        }

        return buckets
    }
}
