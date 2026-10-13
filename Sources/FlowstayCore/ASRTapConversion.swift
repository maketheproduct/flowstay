@preconcurrency import AVFoundation

private let liveTapChannelPeakFloor: Float = 0.0001
private let downmixCancellationPeakRatio: Float = 0.25

private func monoFloatPCMFormat(sampleRate: Double) -> AVAudioFormat? {
    AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    )
}

/// AVAudioConverter invokes its input block serially during a conversion call.
private final class OneShotConverterInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func nextBuffer(outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else {
            outStatus.pointee = .noDataNow
            return nil
        }

        self.buffer = nil
        outStatus.pointee = .haveData
        return buffer
    }
}

func makeASRTapConverter(
    from inputFormat: AVAudioFormat,
    to outputFormat: AVAudioFormat
) -> AVAudioConverter? {
    // Direct N-channel -> mono conversion reports haveData but emits silence
    // for discrete 16ch layouts (Universal Audio Thunderbolt tap).
    guard let sourceFormat = monoFloatPCMFormat(sampleRate: inputFormat.sampleRate) else {
        return nil
    }

    return AVAudioConverter(from: sourceFormat, to: outputFormat)
}

private func downmixToMonoPCMBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    let channelCount = Int(buffer.format.channelCount)
    guard let monoFormat = monoFloatPCMFormat(sampleRate: buffer.format.sampleRate),
          let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
          let destination = monoBuffer.floatChannelData?[0]
    else {
        return nil
    }

    monoBuffer.frameLength = buffer.frameLength
    let frameLength = Int(buffer.frameLength)
    guard frameLength > 0 else {
        return monoBuffer
    }

    if buffer.format.isInterleaved {
        guard let interleaved = buffer.floatChannelData?[0] else {
            return nil
        }
        mixInterleavedFloatToMono(
            source: interleaved,
            channelCount: channelCount,
            frameLength: frameLength,
            destination: destination
        )
        return monoBuffer
    }

    guard let channels = buffer.floatChannelData else {
        return nil
    }

    mixDeinterleavedFloatToMono(
        source: channels,
        channelCount: channelCount,
        frameLength: frameLength,
        destination: destination
    )
    return monoBuffer
}

func convertTapBufferToASRMono(
    _ buffer: AVAudioPCMBuffer,
    converter: AVAudioConverter,
    outputFormat: AVAudioFormat
) -> AVAudioPCMBuffer? {
    guard let monoBuffer = downmixToMonoPCMBuffer(buffer) else {
        return nil
    }

    let frameCapacity = convertedOutputFrameCapacity(
        inputFrameCount: monoBuffer.frameLength,
        inputSampleRate: monoBuffer.format.sampleRate,
        outputSampleRate: outputFormat.sampleRate
    )
    guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
        return nil
    }

    var error: NSError?
    let input = OneShotConverterInput(buffer: monoBuffer)
    _ = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
        input.nextBuffer(outStatus: outStatus)
    }

    if error != nil {
        return nil
    }

    return convertedBuffer
}

private func mixDeinterleavedFloatToMono(
    source: UnsafePointer<UnsafeMutablePointer<Float>>,
    channelCount: Int,
    frameLength: Int,
    destination: UnsafeMutablePointer<Float>
) {
    guard let plan = downmixPlan(
        channelCount: channelCount,
        peakForChannel: { channel in
            peak(of: source[channel], frameLength: frameLength)
        }
    ) else {
        return
    }

    let scale = 1 / Float(plan.channels.count)
    var mixedPeak: Float = 0
    for frame in 0 ..< frameLength {
        var sum: Float = 0
        for channel in plan.channels {
            sum += source[channel][frame]
        }
        let sample = sum * scale
        destination[frame] = sample
        mixedPeak = max(mixedPeak, abs(sample))
    }

    if mixedPeak < plan.strongestPeak * downmixCancellationPeakRatio {
        for frame in 0 ..< frameLength {
            destination[frame] = source[plan.strongestChannel][frame]
        }
    }
}

private func mixInterleavedFloatToMono(
    source: UnsafeMutablePointer<Float>,
    channelCount: Int,
    frameLength: Int,
    destination: UnsafeMutablePointer<Float>
) {
    guard let plan = downmixPlan(
        channelCount: channelCount,
        peakForChannel: { channel in
            var channelPeak: Float = 0
            var offset = channel
            for _ in 0 ..< frameLength {
                channelPeak = max(channelPeak, abs(source[offset]))
                offset += channelCount
            }
            return channelPeak
        }
    ) else {
        return
    }

    let scale = 1 / Float(plan.channels.count)
    var mixedPeak: Float = 0
    for frame in 0 ..< frameLength {
        var sum: Float = 0
        let base = frame * channelCount
        for channel in plan.channels {
            sum += source[base + channel]
        }
        let sample = sum * scale
        destination[frame] = sample
        mixedPeak = max(mixedPeak, abs(sample))
    }

    if mixedPeak < plan.strongestPeak * downmixCancellationPeakRatio {
        for frame in 0 ..< frameLength {
            destination[frame] = source[frame * channelCount + plan.strongestChannel]
        }
    }
}

private struct DownmixPlan {
    let channels: [Int]
    let strongestChannel: Int
    let strongestPeak: Float
}

private func downmixPlan(
    channelCount: Int,
    peakForChannel: (Int) -> Float
) -> DownmixPlan? {
    let allChannels = Array(0 ..< channelCount)
    guard !allChannels.isEmpty else {
        return nil
    }

    let channelPeaks = allChannels.map(peakForChannel)
    let channels: [Int]
    if channelCount > 2 {
        let liveChannels = allChannels.filter { channelPeaks[$0] > liveTapChannelPeakFloor }
        channels = liveChannels.isEmpty ? allChannels : liveChannels
    } else {
        channels = allChannels
    }

    var strongestChannel = channels[0]
    for channel in channels.dropFirst() where channelPeaks[channel] > channelPeaks[strongestChannel] {
        strongestChannel = channel
    }

    return DownmixPlan(
        channels: channels,
        strongestChannel: strongestChannel,
        strongestPeak: channelPeaks[strongestChannel]
    )
}

private func peak(of samples: UnsafeMutablePointer<Float>, frameLength: Int) -> Float {
    var channelPeak: Float = 0
    for frame in 0 ..< frameLength {
        channelPeak = max(channelPeak, abs(samples[frame]))
    }
    return channelPeak
}
