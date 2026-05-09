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

    func testActivationProofDoesNotActivateUntilSamplesArrive() async throws {
        let backend = FakeAudioInputCaptureBackend(behavior: .succeedsImmediately)
        let proof = AudioInputActivationProof(backend: backend, timeout: 0.2, retryDelayNanoseconds: 1_000_000)
        let activationState = LockedTestState()

        _ = try await proof.start(
            onActivated: { activationState.markActivated() },
            onSamples: { _ in }
        )

        let isActive = await proof.activeState()
        XCTAssertTrue(activationState.wasActivated)
        XCTAssertTrue(isActive)
    }

    func testActivationProofRetriesOnceAfterFirstTimeout() async throws {
        let backend = FakeAudioInputCaptureBackend(behavior: .firstAttemptTimesOutSecondSucceeds)
        let proof = AudioInputActivationProof(backend: backend, timeout: 0.03, retryDelayNanoseconds: 1_000_000)

        _ = try await proof.start(onSamples: { _ in })

        let startCount = backend.startCount()
        let stopCount = backend.stopCount()
        let isActive = await proof.activeState()
        XCTAssertEqual(startCount, 2)
        XCTAssertEqual(stopCount, 1)
        XCTAssertTrue(isActive)
    }

    func testActivationProofRestartsWhenDefaultInputChangesDuringStartup() async throws {
        let backend = FakeAudioInputCaptureBackend(behavior: .deviceChangesDuringStartup)
        let proof = AudioInputActivationProof(backend: backend, timeout: 0.2, retryDelayNanoseconds: 1_000_000)

        let snapshot = try await proof.start(onSamples: { _ in })

        XCTAssertEqual(snapshot.deviceID, AudioDeviceID(601))
        XCTAssertEqual(backend.startCount(), 2)
        XCTAssertEqual(backend.stopCount(), 1)
    }

    func testActivationProofFailsVisiblyWhenBothAttemptsProduceNoSamples() async {
        let backend = FakeAudioInputCaptureBackend(behavior: .neverProducesSamples)
        let proof = AudioInputActivationProof(backend: backend, timeout: 0.01, retryDelayNanoseconds: 1_000_000)
        let sampleState = LockedTestState()

        do {
            _ = try await proof.start { _ in
                sampleState.incrementSamples()
            }
            XCTFail("Expected startup timeout")
        } catch {
            let isActive = await proof.activeState()
            XCTAssertFalse(isActive)
            XCTAssertEqual(sampleState.sampleCount, 0)
            XCTAssertEqual(backend.startCount(), 2)
            XCTAssertEqual(backend.stopCount(), 2)
        }
    }

    func testActivationProofRunsActivationCallbackOnlyAfterSamples() async throws {
        let backend = FakeAudioInputCaptureBackend(behavior: .succeedsImmediately)
        let proof = AudioInputActivationProof(backend: backend, timeout: 0.2, retryDelayNanoseconds: 1_000_000)
        let sampleState = LockedTestState()

        _ = try await proof.start(
            onActivated: {
                sampleState.captureActivationOrdering()
            },
            onSamples: { _ in
                sampleState.incrementSamples()
            }
        )

        XCTAssertTrue(sampleState.receivedSamplesBeforeActivation)
    }

    func testActivationProofStopReleasesBackend() async throws {
        let backend = FakeAudioInputCaptureBackend(behavior: .succeedsImmediately)
        let proof = AudioInputActivationProof(backend: backend, timeout: 0.2, retryDelayNanoseconds: 1_000_000)

        _ = try await proof.start(onSamples: { _ in })
        await proof.stop()

        let isActive = await proof.activeState()
        XCTAssertFalse(isActive)
        XCTAssertEqual(backend.stopCount(), 1)
    }

    func testIdleActivationProofStopsBackendImmediatelyAfterSamples() async {
        let backend = FakeAudioInputCaptureBackend(behavior: .succeedsImmediately)
        let coordinator = AudioInputActivationCoordinator(
            backend: backend,
            debounceNanoseconds: 0,
            timeout: 0.2,
            retryDelayNanoseconds: 1_000_000,
            persistMetrics: false
        )

        let metric = await coordinator.proveNow(reason: .defaultInputChanged)

        XCTAssertTrue(metric.succeeded)
        XCTAssertEqual(metric.reason, AudioInputDeviceChangeReason.defaultInputChanged.rawValue)
        XCTAssertEqual(backend.startCount(), 1)
        XCTAssertEqual(backend.stopCount(), 2)
        XCTAssertEqual(backend.sampleCallbackCount(), 1)
    }

    func testIdleActivationProofRetriesOnceOnNoSamplesAndRecordsFailure() async {
        let backend = FakeAudioInputCaptureBackend(behavior: .neverProducesSamples)
        let coordinator = AudioInputActivationCoordinator(
            backend: backend,
            debounceNanoseconds: 0,
            timeout: 0.01,
            retryDelayNanoseconds: 1_000_000,
            persistMetrics: false
        )

        let metric = await coordinator.proveNow(reason: .devicesChanged)

        XCTAssertFalse(metric.succeeded)
        XCTAssertEqual(metric.reason, AudioInputDeviceChangeReason.devicesChanged.rawValue)
        XCTAssertEqual(metric.attemptCount, 2)
        XCTAssertEqual(backend.startCount(), 2)
        XCTAssertEqual(backend.stopCount(), 3)
    }

    func testIdleActivationDefersWhileRecordingAndRunsAfterStop() async {
        let backend = FakeAudioInputCaptureBackend(behavior: .succeedsImmediately)
        let coordinator = AudioInputActivationCoordinator(
            backend: backend,
            debounceNanoseconds: 0,
            timeout: 0.2,
            retryDelayNanoseconds: 1_000_000,
            persistMetrics: false
        )

        await coordinator.setRecordingActive(true)
        await coordinator.requestProof(reason: .defaultInputChanged)
        await coordinator.waitForScheduledWork()
        XCTAssertEqual(backend.startCount(), 0)

        await coordinator.setRecordingActive(false)
        await coordinator.waitForScheduledWork()

        let metrics = await coordinator.recentMetrics()
        XCTAssertEqual(backend.startCount(), 1)
        XCTAssertEqual(metrics.first?.reason, AudioInputDeviceChangeReason.postRecordingPending.rawValue)
        XCTAssertTrue(metrics.first?.succeeded == true)
    }

    func testRapidIdleActivationEventsDebounceToLatestReason() async {
        let backend = FakeAudioInputCaptureBackend(behavior: .succeedsImmediately)
        let coordinator = AudioInputActivationCoordinator(
            backend: backend,
            debounceNanoseconds: 20_000_000,
            timeout: 0.2,
            retryDelayNanoseconds: 1_000_000,
            persistMetrics: false
        )

        await coordinator.requestProof(reason: .defaultInputChanged)
        await coordinator.requestProof(reason: .devicesChanged)
        await coordinator.requestProof(reason: .serviceRestarted)
        await coordinator.waitForScheduledWork()

        let metrics = await coordinator.recentMetrics()
        XCTAssertEqual(backend.startCount(), 1)
        XCTAssertEqual(metrics.first?.reason, AudioInputDeviceChangeReason.serviceRestarted.rawValue)
    }

    func testIdleActivationRetriesLatestDefaultInputWhenDeviceChangesDuringProof() async {
        let backend = FakeAudioInputCaptureBackend(behavior: .deviceChangesDuringStartup)
        let coordinator = AudioInputActivationCoordinator(
            backend: backend,
            debounceNanoseconds: 0,
            timeout: 0.2,
            retryDelayNanoseconds: 1_000_000,
            persistMetrics: false
        )

        let metric = await coordinator.proveNow(reason: .sampleRateChanged)

        XCTAssertTrue(metric.succeeded)
        XCTAssertEqual(metric.deviceID, 601)
        XCTAssertEqual(backend.startCount(), 2)
        XCTAssertEqual(backend.stopCount(), 3)
    }

    func testDevicePropertyListenersUseMainElementForDeviceObject() {
        let aliveAddress = AudioInputDeviceMonitor.devicePropertyAddress(
            selector: kAudioDevicePropertyDeviceIsAlive
        )
        let sampleRateAddress = AudioInputDeviceMonitor.devicePropertyAddress(
            selector: kAudioDevicePropertyNominalSampleRate
        )

        XCTAssertEqual(aliveAddress.mElement, kAudioObjectPropertyElementMain)
        XCTAssertEqual(sampleRateAddress.mElement, kAudioObjectPropertyElementMain)
        XCTAssertEqual(aliveAddress.mScope, kAudioObjectPropertyScopeGlobal)
        XCTAssertEqual(sampleRateAddress.mScope, kAudioObjectPropertyScopeGlobal)
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

private final class LockedTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var activated = false
    private var samples = 0
    private var samplesBeforeActivation = false

    func markActivated() {
        lock.withLock {
            activated = true
        }
    }

    func incrementSamples() {
        lock.withLock {
            samples += 1
        }
    }

    func captureActivationOrdering() {
        lock.withLock {
            samplesBeforeActivation = samples > 0
            activated = true
        }
    }

    var wasActivated: Bool {
        lock.withLock { activated }
    }

    var sampleCount: Int {
        lock.withLock { samples }
    }

    var receivedSamplesBeforeActivation: Bool {
        lock.withLock { samplesBeforeActivation }
    }
}
