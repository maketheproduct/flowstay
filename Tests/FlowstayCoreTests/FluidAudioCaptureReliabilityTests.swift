import AVFoundation
import CoreAudio
@testable import FlowstayCore
import XCTest

final class FluidAudioCaptureReliabilityTests: XCTestCase {
    func testConvertedOutputFrameCapacityUsesCeilFor48kTo16k() {
        let capacity = convertedOutputFrameCapacity(
            inputFrameCount: 1024,
            inputSampleRate: 48000,
            outputSampleRate: 16000
        )

        XCTAssertEqual(capacity, 342)
    }

    func testConvertedOutputFrameCapacityUsesCeilFor44100To16k() {
        let capacity = convertedOutputFrameCapacity(
            inputFrameCount: 1024,
            inputSampleRate: 44100,
            outputSampleRate: 16000
        )

        XCTAssertEqual(capacity, 372)
    }

    func testRecordingStartupRetryPolicyAllowsOneRecoveryAttempt() {
        XCTAssertTrue(
            shouldRetryRecordingStartupAfterInitialBufferTimeout(
                completedAttempts: 1,
                maximumAttempts: 2
            )
        )

        XCTAssertFalse(
            shouldRetryRecordingStartupAfterInitialBufferTimeout(
                completedAttempts: 2,
                maximumAttempts: 2
            )
        )
    }

    @MainActor
    func testRecognizerNeverOpensInputWhileIdle() async {
        let halBackend = FakeAudioInputCaptureBackend(behavior: .succeedsImmediately)
        let fallbackBackend = FakeAudioInputCaptureBackend(behavior: .succeedsImmediately)
        let recognizer = FluidAudioSpeechRecognition(
            appState: nil,
            halCaptureBackend: halBackend,
            avAudioEngineFallbackBackend: fallbackBackend
        )

        let didPrewarm = await recognizer.prewarmRecordingPipeline()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertFalse(didPrewarm)
        XCTAssertEqual(halBackend.startCount(), 0)
        XCTAssertEqual(fallbackBackend.startCount(), 0)
        recognizer.shutdown()
    }

    func testSixteenChannelSignalOnNonZeroChannelSurvivesToMono16k() throws {
        let input = try makeDeinterleavedFloatBuffer(
            sampleRate: 44100,
            channelCount: 16,
            frameCount: 4410,
            liveChannel: 2,
            amplitude: 0.3
        )
        let converted = try convertToASRMono16k(input)

        XCTAssertEqual(converted.format.sampleRate, 16000, accuracy: 0.1)
        XCTAssertEqual(converted.format.channelCount, 1)
        XCTAssertGreaterThan(converted.frameLength, 0)
        XCTAssertGreaterThan(maxAbsAmplitude(converted), 0.05)
    }

    func testStereoRightChannelSignalSurvivesToMono16k() throws {
        let input = try makeDeinterleavedFloatBuffer(
            sampleRate: 44100,
            channelCount: 2,
            frameCount: 4410,
            liveChannel: 1,
            amplitude: 0.3
        )
        let converted = try convertToASRMono16k(input)

        XCTAssertEqual(converted.format.channelCount, 1)
        XCTAssertGreaterThan(maxAbsAmplitude(converted), 0.05)
    }

    func testMonoSignalSurvivesResampleTo16k() throws {
        let input = try makeDeinterleavedFloatBuffer(
            sampleRate: 44100,
            channelCount: 1,
            frameCount: 4410,
            liveChannel: 0,
            amplitude: 0.3
        )
        let converted = try convertToASRMono16k(input)

        XCTAssertEqual(converted.format.channelCount, 1)
        XCTAssertGreaterThan(maxAbsAmplitude(converted), 0.05)
    }

    func testReusedConverterDoesNotReplayPreviousTapBuffer() throws {
        let firstInput = try makeDeinterleavedFloatBuffer(
            sampleRate: 44100,
            channelCount: 1,
            frameCount: 4410,
            liveChannel: 0,
            amplitude: 0.2
        )
        let secondInput = try makeDeinterleavedFloatBuffer(
            sampleRate: 44100,
            channelCount: 1,
            frameCount: 4410,
            liveChannel: 0,
            amplitude: 0.8
        )
        let outputFormat = try makeASRMono16kFormat()
        let converter = try XCTUnwrap(makeASRTapConverter(from: firstInput.format, to: outputFormat))

        _ = try XCTUnwrap(
            convertTapBufferToASRMono(
                firstInput,
                converter: converter,
                outputFormat: outputFormat
            )
        )
        let secondOutput = try XCTUnwrap(
            convertTapBufferToASRMono(
                secondInput,
                converter: converter,
                outputFormat: outputFormat
            )
        )

        let expectedMean = Float(0.8 * 2 / Double.pi)
        XCTAssertEqual(meanAbsAmplitude(secondOutput), expectedMean, accuracy: 0.04)
    }

    func testDiscreteMonoLayoutConvertsAndPreservesSignal() throws {
        let layoutTag = AudioChannelLayoutTag(kAudioChannelLayoutTag_DiscreteInOrder | 1)
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: layoutTag))
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100,
            interleaved: false,
            channelLayout: layout
        )
        let input = try makeSineBuffer(
            format: format,
            frameCount: 4410,
            channelAmplitudes: [0.3]
        )

        let converted = try convertToASRMono16k(input)

        XCTAssertEqual(maxAbsAmplitude(converted), 0.3, accuracy: 0.03)
    }

    func testOppositePolarityStereoFallsBackToStrongestChannel() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 44100,
                channels: 2,
                interleaved: false
            )
        )
        let input = try makeSineBuffer(
            format: format,
            frameCount: 4410,
            channelAmplitudes: [0.3, -0.3]
        )

        let converted = try convertToASRMono16k(input)

        XCTAssertGreaterThan(maxAbsAmplitude(converted), 0.2)
    }
}

final class FakeAudioInputCaptureBackend: AudioInputCaptureBackend, @unchecked Sendable {
    enum Behavior {
        case succeedsImmediately
        case firstAttemptTimesOutSecondSucceeds
        case deviceChangesDuringStartup
        case neverProducesSamples
    }

    private let behavior: Behavior
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    private var callbacks = 0

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func currentDefaultInputSnapshot() throws -> AudioInputDeviceSnapshot {
        let startCount = lock.withLock { starts }
        let deviceID: AudioDeviceID = if behavior == .deviceChangesDuringStartup {
            startCount == 0 ? AudioDeviceID(600) : AudioDeviceID(601)
        } else {
            AudioDeviceID(500)
        }
        return AudioInputDeviceSnapshot(
            deviceID: deviceID,
            uid: "fake-input-\(deviceID)",
            name: "Fake Input",
            transportType: nil,
            nominalSampleRate: 48000,
            inputChannelCount: 1
        )
    }

    func start(
        snapshot: AudioInputDeviceSnapshot,
        onHALCallback: @escaping @Sendable () -> Void,
        onSamples: @escaping @Sendable ([Float]) -> Void
    ) async throws {
        let currentStart = lock.withLock {
            starts += 1
            return starts
        }
        switch behavior {
        case .succeedsImmediately:
            onHALCallback()
            onSamples([0.1, 0.2])
            lock.withLock { callbacks += 1 }
        case .firstAttemptTimesOutSecondSucceeds:
            if currentStart == 2 {
                onHALCallback()
                onSamples([0.1, 0.2])
                lock.withLock { callbacks += 1 }
            }
        case .deviceChangesDuringStartup:
            onHALCallback()
            onSamples([0.1, 0.2])
            lock.withLock { callbacks += 1 }
        case .neverProducesSamples:
            onHALCallback()
        }
        _ = snapshot
    }

    func stop() async {
        lock.withLock {
            stops += 1
        }
    }

    func startCount() -> Int {
        lock.withLock { starts }
    }

    func stopCount() -> Int {
        lock.withLock { stops }
    }

    func sampleCallbackCount() -> Int {
        lock.withLock { callbacks }
    }
}

private func makeASRMono16kFormat() throws -> AVAudioFormat {
    try XCTUnwrap(
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )
    )
}

private func convertToASRMono16k(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
    let outputFormat = try makeASRMono16kFormat()
    let converter = try XCTUnwrap(makeASRTapConverter(from: buffer.format, to: outputFormat))
    return try XCTUnwrap(
        convertTapBufferToASRMono(
            buffer,
            converter: converter,
            outputFormat: outputFormat
        )
    )
}

private func makeDeinterleavedFloatBuffer(
    sampleRate: Double,
    channelCount: AVAudioChannelCount,
    frameCount: AVAudioFrameCount,
    liveChannel: Int,
    amplitude: Float
) throws -> AVAudioPCMBuffer {
    let format: AVAudioFormat
    if channelCount <= 2 {
        format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channelCount,
                interleaved: false
            )
        )
    } else {
        let layoutTag = AudioChannelLayoutTag(kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channelCount))
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: layoutTag))
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            interleaved: false,
            channelLayout: layout
        )
    }

    var channelAmplitudes = Array(repeating: Float.zero, count: Int(channelCount))
    channelAmplitudes[liveChannel] = amplitude
    return try makeSineBuffer(
        format: format,
        frameCount: frameCount,
        channelAmplitudes: channelAmplitudes
    )
}

private func makeSineBuffer(
    format: AVAudioFormat,
    frameCount: AVAudioFrameCount,
    channelAmplitudes: [Float]
) throws -> AVAudioPCMBuffer {
    precondition(channelAmplitudes.count == Int(format.channelCount))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
    buffer.frameLength = frameCount
    let channels = try XCTUnwrap(buffer.floatChannelData)
    let step = Float(2.0 * Double.pi * 440.0 / format.sampleRate)
    for frame in 0 ..< Int(frameCount) {
        let sample = sin(step * Float(frame))
        for channel in channelAmplitudes.indices {
            channels[channel][frame] = channelAmplitudes[channel] * sample
        }
    }
    return buffer
}

private func maxAbsAmplitude(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let samples = buffer.floatChannelData?[0] else {
        return 0
    }

    var peak: Float = 0
    for frame in 0 ..< Int(buffer.frameLength) {
        peak = max(peak, abs(samples[frame]))
    }
    return peak
}

private func meanAbsAmplitude(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else {
        return 0
    }

    var sum: Float = 0
    for frame in 0 ..< Int(buffer.frameLength) {
        sum += abs(samples[frame])
    }
    return sum / Float(buffer.frameLength)
}
