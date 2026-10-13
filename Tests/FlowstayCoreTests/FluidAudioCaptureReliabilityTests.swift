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
