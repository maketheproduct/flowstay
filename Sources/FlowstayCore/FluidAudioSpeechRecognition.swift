@preconcurrency import AVFoundation
import Combine
import CoreAudio
import FluidAudio
import Foundation
import os
import UserNotifications

private final class TranscriptionCompletionSink {
    var handler: (@Sendable (String, TimeInterval) -> Void)?
}

private let recordingPipelineWarmStateValidityDuration: TimeInterval = 300

struct DefaultInputSnapshot: Equatable, Sendable {
    let deviceID: AudioDeviceID
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
}

struct RecordingPipelineWarmState: Equatable, Sendable {
    let snapshot: DefaultInputSnapshot
    let didReceiveConvertedBuffer: Bool
    let completedAt: Date

    func isValid(
        for currentSnapshot: DefaultInputSnapshot,
        now: Date = Date(),
        maximumAge: TimeInterval = recordingPipelineWarmStateValidityDuration
    ) -> Bool {
        didReceiveConvertedBuffer &&
            snapshot == currentSnapshot &&
            now.timeIntervalSince(completedAt) <= maximumAge
    }
}

func convertedOutputFrameCapacity(
    inputFrameCount: AVAudioFrameCount,
    inputSampleRate: Double,
    outputSampleRate: Double
) -> AVAudioFrameCount {
    guard inputSampleRate > 0, outputSampleRate > 0 else {
        return max(1, inputFrameCount)
    }

    let scaledFrameCount = Double(inputFrameCount) * outputSampleRate / inputSampleRate
    return AVAudioFrameCount(max(1, Int(ceil(scaledFrameCount))))
}

func shouldForceRecordingPipelinePrewarm(
    currentSnapshot: DefaultInputSnapshot,
    warmState: RecordingPipelineWarmState?,
    now: Date = Date()
) -> Bool {
    guard let warmState else {
        return true
    }

    return !warmState.isValid(for: currentSnapshot, now: now)
}

func shouldRetryRecordingStartupAfterInitialBufferTimeout(
    completedAttempts: Int,
    maximumAttempts: Int
) -> Bool {
    completedAttempts < maximumAttempts
}

private func defaultInputDevicePropertyAddress() -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}

private final class PrewarmObservationState: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedConvertedBuffer = false

    func markReceived() {
        lock.withLock {
            receivedConvertedBuffer = true
        }
    }

    var hasReceivedConvertedBuffer: Bool {
        lock.withLock { receivedConvertedBuffer }
    }
}

private struct AudioVisualizationUpdate: Sendable {
    let audioLevel: Float
    let waveformSamples: [Float]
}

private struct AudioBufferProcessingResult: Sendable {
    let hasAudioActivity: Bool
    let didDetectSpeechTransition: Bool
    let visualizationUpdate: AudioVisualizationUpdate?

    var requiresMainActorUpdate: Bool {
        hasAudioActivity || didDetectSpeechTransition || visualizationUpdate != nil
    }
}

private struct AudioProcessingSnapshot: Sendable {
    let lastSpeechDetectedAt: Date?
}

private actor FluidAudioBufferProcessor {
    private let chunkedRecordingManager: ChunkedRecordingManager
    private let silenceThreshold: Float
    private let lowSignalThreshold: Float
    private let peakSpeechThreshold: Float
    private let speechHangoverDuration: TimeInterval
    private let waveformNoiseFloorRms: Float
    private let visualizationUpdateMinimumInterval: TimeInterval

    private var lastSpeechDetectedAt: Date?
    private var hasDetectedSpeechInCurrentSession = false
    private var lastVisualizationUpdateAt: Date?
    private var previousWaveformSamples: [Float] = []

    init(
        chunkedRecordingManager: ChunkedRecordingManager,
        silenceThreshold: Float,
        lowSignalThreshold: Float,
        peakSpeechThreshold: Float,
        speechHangoverDuration: TimeInterval,
        waveformNoiseFloorRms: Float,
        visualizationUpdateMinimumInterval: TimeInterval = 0.1
    ) {
        self.chunkedRecordingManager = chunkedRecordingManager
        self.silenceThreshold = silenceThreshold
        self.lowSignalThreshold = lowSignalThreshold
        self.peakSpeechThreshold = peakSpeechThreshold
        self.speechHangoverDuration = speechHangoverDuration
        self.waveformNoiseFloorRms = waveformNoiseFloorRms
        self.visualizationUpdateMinimumInterval = visualizationUpdateMinimumInterval
    }

    func resetSession() {
        lastSpeechDetectedAt = nil
        hasDetectedSpeechInCurrentSession = false
        lastVisualizationUpdateAt = nil
        previousWaveformSamples = []
    }

    func snapshot() -> AudioProcessingSnapshot {
        AudioProcessingSnapshot(lastSpeechDetectedAt: lastSpeechDetectedAt)
    }

    func process(
        samples: [Float],
        rms: Float?,
        suppressVisualization: Bool
    ) async -> AudioBufferProcessingResult {
        guard !samples.isEmpty else {
            return AudioBufferProcessingResult(
                hasAudioActivity: false,
                didDetectSpeechTransition: false,
                visualizationUpdate: nil
            )
        }

        let computedRms = rms ?? sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
        let peakAmplitude = samples.map { abs($0) }.max() ?? 0
        let now = Date()
        let hasStrongSpeechSignal = computedRms > silenceThreshold || peakAmplitude > peakSpeechThreshold
        let hasWeakSpeechSignal = computedRms > lowSignalThreshold || peakAmplitude > (peakSpeechThreshold * 0.6)

        let didDetectSpeechTransition: Bool
        let hasAudioActivity: Bool
        if hasStrongSpeechSignal {
            didDetectSpeechTransition = !hasDetectedSpeechInCurrentSession
            hasDetectedSpeechInCurrentSession = true
            hasAudioActivity = true
            lastSpeechDetectedAt = now
        } else if let lastSpeechDetectedAt,
                  now.timeIntervalSince(lastSpeechDetectedAt) <= speechHangoverDuration,
                  hasWeakSpeechSignal
        {
            didDetectSpeechTransition = false
            hasAudioActivity = true
        } else {
            didDetectSpeechTransition = false
            hasAudioActivity = false
        }

        await chunkedRecordingManager.appendSamples(samples, hasAudioActivity: hasAudioActivity)

        let visualizationUpdate = makeVisualizationUpdateIfNeeded(
            samples: samples,
            rms: computedRms,
            now: now,
            suppressVisualization: suppressVisualization
        )

        return AudioBufferProcessingResult(
            hasAudioActivity: hasAudioActivity,
            didDetectSpeechTransition: didDetectSpeechTransition,
            visualizationUpdate: visualizationUpdate
        )
    }

    private func makeVisualizationUpdateIfNeeded(
        samples: [Float],
        rms: Float,
        now: Date,
        suppressVisualization: Bool
    ) -> AudioVisualizationUpdate? {
        guard !suppressVisualization else { return nil }

        if let lastVisualizationUpdateAt,
           now.timeIntervalSince(lastVisualizationUpdateAt) < visualizationUpdateMinimumInterval
        {
            return nil
        }

        lastVisualizationUpdateAt = now
        return AudioVisualizationUpdate(
            audioLevel: normalizedAudioLevel(for: rms),
            waveformSamples: makeWaveformSamples(from: samples, rms: rms)
        )
    }

    private func normalizedAudioLevel(for rms: Float) -> Float {
        let avgPower = 20 * log10(max(0.0001, rms))
        let noiseFloor: Float = -35
        let normalizedPower = (avgPower - noiseFloor) / -noiseFloor
        return max(0, min(1, normalizedPower))
    }

    private func makeWaveformSamples(from samples: [Float], rms: Float) -> [Float] {
        guard !samples.isEmpty else {
            previousWaveformSamples = []
            return []
        }

        if rms < waveformNoiseFloorRms {
            previousWaveformSamples = Array(repeating: 0, count: 32)
            return previousWaveformSamples
        }

        let targetCount = 32
        let stride = max(1, samples.count / targetCount)
        var normalized: [Float] = []
        normalized.reserveCapacity(targetCount)

        var index = 0
        while index < samples.count, normalized.count < targetCount {
            let end = min(samples.count, index + stride)
            var sum: Float = 0
            var count: Float = 0
            var i = index
            while i < end {
                sum += abs(samples[i])
                count += 1
                i += 1
            }
            normalized.append(count > 0 ? (sum / count) : 0)
            index = end
        }

        let maxValue = normalized.max() ?? 1
        let scale = maxValue > 0 ? (1 / maxValue) : 1
        let next = normalized.map { min(1, $0 * scale) }

        if previousWaveformSamples.isEmpty {
            previousWaveformSamples = next
            return next
        }

        let smoothing: Float = 0.7
        let smoothed = zip(previousWaveformSamples, next).map { old, new in
            (old * smoothing) + (new * (1 - smoothing))
        }
        previousWaveformSamples = smoothed
        return smoothed
    }
}

enum FlushResult: Sendable {
    case completed
    case iterationCapHit(iterations: Int)
    case timeLimitHit(elapsed: TimeInterval, iterations: Int)
    case conversionError
}

/// Errors that can occur during FluidAudio speech recognition
public enum FluidAudioError: Error {
    case microphoneSetupFailed
    case modelsNotLoaded
    case transcriptionFailed
    case noInputDeviceAvailable
}

extension FluidAudioError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .microphoneSetupFailed:
            "Failed to configure the microphone input."
        case .modelsNotLoaded:
            "Speech recognition models are not loaded."
        case .transcriptionFailed:
            "Speech transcription failed."
        case .noInputDeviceAvailable:
            "No audio input device is available. Connect a microphone or choose an input device in System Settings."
        }
    }
}

private enum FluidAudioInternalError: LocalizedError {
    case modelDownloadFailed(attempts: Int)
    case loadedModelsUnavailable
    case downloadedModelsUnavailable
    case shuttingDown
    case asrUnavailable
    case audioEngineCreationFailed
    case audioEngineRecreationFailed
    case startupTimedOut

    var errorDescription: String? {
        switch self {
        case let .modelDownloadFailed(attempts):
            "Failed to download models after \(attempts) attempts."
        case .loadedModelsUnavailable:
            "Models loaded but were unexpectedly unavailable."
        case .downloadedModelsUnavailable:
            "Models downloaded but were unexpectedly unavailable."
        case .shuttingDown:
            "Speech recognition is shutting down."
        case .asrUnavailable:
            "FluidAudio ASR not available. Models may need to be downloaded."
        case .audioEngineCreationFailed:
            "Failed to create audio engine."
        case .audioEngineRecreationFailed:
            "Failed to recreate audio engine after forced prewarm."
        case .startupTimedOut:
            "Timed out waiting for audio from the selected input device. Try reconnecting the device and starting recording again."
        }
    }
}

/// FluidAudio-based Speech Recognition using Parakeet TDT ASR
/// Provides fast, accurate, local speech recognition with better real-time performance than Whisper
@MainActor
public final class FluidAudioSpeechRecognition: NSObject, ObservableObject {
    private struct StopFinalizationDiagnostics {
        let stopRequestedAt: Date
        let timeSinceLastSpeechAtStop: TimeInterval?
        let chosenDelay: TimeInterval
        let finalChunkSampleCount: Int
    }

    @Published public var isRecording = false
    @Published public var transcription = ""
    @Published public var audioLevel: Float = 0.0
    @Published public var waveformSamples: [Float] = []
    private let transcriptionCompletionSink = TranscriptionCompletionSink()

    /// Callback when transcription is complete (with duration)
    public var onTranscriptionComplete: (@Sendable (String, TimeInterval) -> Void)? {
        get { transcriptionCompletionSink.handler }
        set { transcriptionCompletionSink.handler = newValue }
    }

    /// Thread-safe completion tracking using OSAllocatedUnfairLock
    private let completionLock = OSAllocatedUnfairLock()
    private let logger = Logger(subsystem: "com.flowstay.app", category: "FluidAudioSpeechRecognition")
    /// SAFETY: nonisolated(unsafe) because access is protected by completionLock
    private nonisolated(unsafe) var hasCalledCompletion = false

    /// Track if user has initiated stop
    private var userInitiatedStop = false

    /// Safety watchdog task — cancelled when real completion fires
    private var safetyWatchdogTask: Task<Void, Never>?

    // FluidAudio components - nonisolated(unsafe) because AsrManager/AsrModels aren't Sendable
    /// SAFETY: nonisolated(unsafe) for AsrManager/AsrModels because they don't conform to Sendable.
    /// Thread safety is guaranteed by MainActor isolation - all access to these properties
    /// happens on the main thread through the @MainActor-isolated class.
    private nonisolated(unsafe) var asrManager: AsrManager?
    /// SAFETY: same as `asrManager`; access remains confined to the main actor.
    private nonisolated(unsafe) var models: AsrModels?

    /// Chunked recording manager for unlimited-length recordings
    private let chunkedRecordingManager = ChunkedRecordingManager()
    /// SAFETY: this lazy property is only initialized from the enclosing `@MainActor`
    /// instance, so initialization remains single-threaded despite `lazy` storage.
    private lazy var audioBufferProcessor = FluidAudioBufferProcessor(
        chunkedRecordingManager: chunkedRecordingManager,
        silenceThreshold: silenceThreshold,
        lowSignalThreshold: lowSignalThreshold,
        peakSpeechThreshold: peakSpeechThreshold,
        speechHangoverDuration: speechHangoverDuration,
        waveformNoiseFloorRms: waveformNoiseFloorRms
    )

    /// Audio components
    private var audioEngine: AVAudioEngine?

    private var audioLevelTimer: Timer?

    /// Audio tap proxy for non-isolated processing
    private var tapProxy: FluidAudioTapProxy?

    /// Download monitoring task
    private var downloadMonitorTask: Task<Void, Never>?
    private var backgroundRewarmTask: Task<Void, Never>?
    private var pendingRewarmDebounceTask: Task<Void, Never>?
    private var needsBackgroundRewarmAfterCurrentTask = false
    private var defaultInputDeviceListener: AudioObjectPropertyListenerBlock?
    private let defaultInputDeviceListenerQueue = DispatchQueue(label: "com.flowstay.app.audio.default-input-listener")
    private var recordingPipelineWarmState: RecordingPipelineWarmState?
    /// One-way latch. After `shutdown()`, this instance is permanently unusable and
    /// subsequent entry points must bail out instead of attempting to rearm it.
    private var isShuttingDown = false

    // Processing configuration - optimized for FluidAudio/Parakeet accuracy
    private let sampleRate: Double = 16000.0 // FluidAudio expects 16kHz
    private let silenceThreshold: Float = 0.003 // Primary RMS threshold for speech activity
    private let lowSignalThreshold: Float = 0.0018 // Lower threshold used during hangover window
    private let peakSpeechThreshold: Float = 0.012 // Peak threshold catches consonants with low RMS
    private let speechHangoverDuration: TimeInterval = 1.2 // Keep speech "active" briefly between syllables
    private let waveformNoiseFloorRms: Float = 0.0035
    private let trailingBufferDelay: TimeInterval = 0.4 // Allow tap buffers to flush before stop
    private let requiredSpeechTailGap: TimeInterval = 0.65
    private let maximumTrailingBufferDelay: TimeInterval = 0.9
    private let hardwareSettleDelayNanoseconds: UInt64 = 50_000_000
    private let prewarmConvertedBufferTimeout: TimeInterval = 0.5
    private let recordingStartupConvertedBufferTimeout: TimeInterval = 0.75
    private let recordingStartupRetryDelayNanoseconds: UInt64 = 200_000_000
    private let maximumRecordingStartupAttempts = 2

    /// Silence detection timer
    private var silenceDetectionTimer: Timer?

    // Reference to AppState for silence timeout configuration
    private weak var appState: AppState?

    /// Check if models are ready for transcription (loaded in memory)
    public var isModelsReady: Bool {
        models != nil && asrManager != nil
    }

    /// Check if models exist on disk (cached)
    /// Uses FluidAudio's built-in model detection for accuracy
    public func areModelsCached() -> Bool {
        // Use FluidAudio's authoritative model checking with correct filenames
        let cacheDir = AsrModels.defaultCacheDirectory()
        return AsrModels.modelsExist(at: cacheDir)
    }

    public init(appState: AppState? = nil) {
        self.appState = appState
        super.init()
        registerDefaultInputDeviceListenerIfNeeded()
    }

    override public convenience init() {
        self.init(appState: nil)
    }

    /// Clean up resources when done
    /// Callers must invoke this before releasing the instance. We intentionally do not
    /// trigger it from `deinit` because the work is async/main-actor-bound and cannot
    /// safely retain `self` during object destruction.
    public nonisolated func cleanup() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let proxy = tapProxy
            shutdown()
            if let proxy {
                await proxy.waitForPendingTasks()
            }
            await drainAndResetAfterShutdown()
            logger.info("[FluidAudioSpeechRecognition] Cleaned up resources")
        }
    }

    public func shutdown() {
        completionLock.withLock {
            hasCalledCompletion = true
        }
        transcriptionCompletionSink.handler = nil
        isShuttingDown = true
        downloadMonitorTask?.cancel()
        downloadMonitorTask = nil
        backgroundRewarmTask?.cancel()
        backgroundRewarmTask = nil
        pendingRewarmDebounceTask?.cancel()
        pendingRewarmDebounceTask = nil
        needsBackgroundRewarmAfterCurrentTask = false
        recordingPipelineWarmState = nil
        safetyWatchdogTask?.cancel()
        safetyWatchdogTask = nil
        audioLevelTimer?.invalidate()
        audioLevelTimer = nil
        silenceDetectionTimer?.invalidate()
        silenceDetectionTimer = nil
        unregisterDefaultInputDeviceListener()
        cleanupAudioEngine()
        isRecording = false
        userInitiatedStop = false
        audioLevel = 0.0
        waveformSamples = []
    }

    func drainAndResetAfterShutdown() async {
        await audioBufferProcessor.resetSession()
        await chunkedRecordingManager.reset()
    }

    /// Safely cleanup audio engine with proper state checks
    private func cleanupAudioEngine() {
        guard let engine = audioEngine else {
            tapProxy = nil
            return
        }

        // Remove tap first (safe even if not installed)
        engine.inputNode.removeTap(onBus: 0)

        // Only stop if running
        if engine.isRunning {
            engine.stop()
        }

        audioEngine = nil
        tapProxy = nil
    }

    private func registerDefaultInputDeviceListenerIfNeeded() {
        guard defaultInputDeviceListener == nil else { return }

        var address = defaultInputDevicePropertyAddress()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleDefaultInputDeviceChange()
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            defaultInputDeviceListenerQueue,
            listener
        )

        guard status == noErr else {
            logger.error("[FluidAudioSpeechRecognition] Failed to register default input listener: \(status, privacy: .public)")
            return
        }

        defaultInputDeviceListener = listener
    }

    private func unregisterDefaultInputDeviceListener() {
        guard let defaultInputDeviceListener else { return }

        var address = defaultInputDevicePropertyAddress()
        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            defaultInputDeviceListenerQueue,
            defaultInputDeviceListener
        )

        if status != noErr {
            logger.error("[FluidAudioSpeechRecognition] Failed to remove default input listener: \(status, privacy: .public)")
        }

        self.defaultInputDeviceListener = nil
    }

    private func handleDefaultInputDeviceChange() {
        let previousWarmState = recordingPipelineWarmState
        recordingPipelineWarmState = nil

        if let previousWarmState {
            logger.info(
                "[FluidAudioSpeechRecognition] Default input changed; invalidated warm state for device \(previousWarmState.snapshot.deviceID, privacy: .public)"
            )
        } else {
            logger.info("[FluidAudioSpeechRecognition] Default input changed; no existing warm state to invalidate")
        }

        guard !isRecording else {
            logger.info("[FluidAudioSpeechRecognition] Mid-recording device changes are not auto-recovered in this pass")
            return
        }

        guard !isShuttingDown else {
            logger.debug("[FluidAudioSpeechRecognition] Ignoring default input change during shutdown")
            return
        }

        guard AVAudioApplication.shared.recordPermission == .granted else {
            logger.debug("[FluidAudioSpeechRecognition] Skipping background re-prewarm: microphone permission not granted")
            return
        }

        guard isModelsReady else {
            logger.debug("[FluidAudioSpeechRecognition] Skipping background re-prewarm: models not ready")
            return
        }

        scheduleBackgroundRewarmDebounced()
    }

    private func scheduleBackgroundRewarmDebounced() {
        pendingRewarmDebounceTask?.cancel()
        pendingRewarmDebounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            pendingRewarmDebounceTask = nil

            guard !isShuttingDown else { return }
            guard !isRecording else { return }
            guard AVAudioApplication.shared.recordPermission == .granted else { return }
            guard isModelsReady else { return }

            if backgroundRewarmTask != nil {
                needsBackgroundRewarmAfterCurrentTask = true
                logger.debug("[FluidAudioSpeechRecognition] Queued follow-up background re-prewarm after current task")
                return
            }

            startBackgroundRewarmIfNeeded()
        }
    }

    private func startBackgroundRewarmIfNeeded() {
        guard backgroundRewarmTask == nil else {
            logger.debug("[FluidAudioSpeechRecognition] Background re-prewarm already running")
            return
        }

        backgroundRewarmTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let didPrewarm = await prewarmRecordingPipeline()
            let status: String
            if Task.isCancelled {
                status = "cancelled"
            } else {
                status = didPrewarm ? "completed" : "failed"
            }
            logger.info("[FluidAudioSpeechRecognition] Background re-prewarm \(status, privacy: .public)")
            backgroundRewarmTask = nil

            guard !isShuttingDown else { return }

            if needsBackgroundRewarmAfterCurrentTask {
                needsBackgroundRewarmAfterCurrentTask = false
                recordingPipelineWarmState = nil
                startBackgroundRewarmIfNeeded()
            }
        }
    }

    private func cancelBackgroundRewarmIfNeeded() async {
        pendingRewarmDebounceTask?.cancel()
        pendingRewarmDebounceTask = nil
        needsBackgroundRewarmAfterCurrentTask = false

        guard let backgroundRewarmTask else { return }

        logger.info("[FluidAudioSpeechRecognition] Cancelling background re-prewarm before recording start")
        self.backgroundRewarmTask = nil
        backgroundRewarmTask.cancel()
        _ = await backgroundRewarmTask.result
    }

    private func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(bitPattern: 0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = defaultInputDevicePropertyAddress()

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )

        guard status == noErr, propertySize == UInt32(MemoryLayout<AudioDeviceID>.size) else {
            return nil
        }

        guard deviceID != AudioDeviceID(bitPattern: 0), deviceID != kAudioObjectUnknown else {
            return nil
        }

        return deviceID
    }

    private func defaultInputSnapshot(for inputFormat: AVAudioFormat) -> DefaultInputSnapshot? {
        guard let deviceID = defaultInputDeviceID() else {
            return nil
        }

        return DefaultInputSnapshot(
            deviceID: deviceID,
            sampleRate: inputFormat.sampleRate,
            channelCount: inputFormat.channelCount
        )
    }

    private func describe(snapshot: DefaultInputSnapshot) -> String {
        "\(snapshot.deviceID) @ \(snapshot.sampleRate)Hz / \(snapshot.channelCount)ch"
    }

    private func updateRecordingPipelineWarmState(
        snapshot: DefaultInputSnapshot,
        didReceiveConvertedBuffer: Bool
    ) {
        recordingPipelineWarmState = RecordingPipelineWarmState(
            snapshot: snapshot,
            didReceiveConvertedBuffer: didReceiveConvertedBuffer,
            completedAt: Date()
        )
    }

    private func waitForConvertedBuffer(
        observation: PrewarmObservationState,
        timeout: TimeInterval
    ) async -> Bool {
        let timeoutDeadline = Date().addingTimeInterval(timeout)

        while Date() < timeoutDeadline {
            if Task.isCancelled {
                return false
            }

            if observation.hasReceivedConvertedBuffer {
                return true
            }

            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        return observation.hasReceivedConvertedBuffer
    }

    private func logFlushResult(_ result: FlushResult, context: String) {
        switch result {
        case .completed:
            logger.debug("[FluidAudioSpeechRecognition] EOS flush completed during \(context, privacy: .public)")
        case let .iterationCapHit(iterations):
            logger.fault(
                "[FluidAudioSpeechRecognition] EOS flush hit iteration cap (\(iterations, privacy: .public)) during \(context, privacy: .public)"
            )
        case let .timeLimitHit(elapsed, iterations):
            logger.fault(
                "[FluidAudioSpeechRecognition] EOS flush hit time limit (\(elapsed, privacy: .public)s, \(iterations, privacy: .public) iterations) during \(context, privacy: .public)"
            )
        case .conversionError:
            logger.fault("[FluidAudioSpeechRecognition] EOS flush conversion error during \(context, privacy: .public)")
        }
    }

    private func finishWarmEngine(
        warmEngine: AVAudioEngine,
        inputNode: AVAudioInputNode,
        warmProxy: FluidAudioTapProxy
    ) async {
        inputNode.removeTap(onBus: 0)
        let flushResult = await warmProxy.flushEndOfStream()
        logFlushResult(flushResult, context: "prewarm cleanup")
        await warmProxy.waitForPendingTasks()

        if warmEngine.isRunning {
            warmEngine.stop()
        }

        await chunkedRecordingManager.reset()
    }

    private func cleanupRecordingStartupAttempt(
        recordingEngine: AVAudioEngine,
        inputNode: AVAudioInputNode,
        proxy: FluidAudioTapProxy?
    ) async {
        inputNode.removeTap(onBus: 0)
        if let proxy {
            let flushResult = await proxy.flushEndOfStream()
            logFlushResult(flushResult, context: "recording startup cleanup")
            await proxy.waitForPendingTasks()
        }

        if recordingEngine.isRunning {
            recordingEngine.stop()
        }

        if audioEngine === recordingEngine {
            audioEngine = nil
        }

        if tapProxy === proxy {
            tapProxy = nil
        }

        await chunkedRecordingManager.reset()
    }

    /// Download models with retry logic and exponential backoff
    private func downloadModelsWithRetry(maxRetries: Int = 3, baseDelay: TimeInterval = 2.0, timeout: TimeInterval = 120.0) async throws -> AsrModels {
        var lastError: Error?

        for attempt in 0 ..< maxRetries {
            do {
                // Create a timeout task
                let downloadTask = Task {
                    try await AsrModels.downloadAndLoad()
                }

                let timeoutTask = Task {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    downloadTask.cancel()
                }

                // Wait for either download or timeout
                let result = try await downloadTask.value
                timeoutTask.cancel()
                return result

            } catch {
                lastError = error
                logger.error("[FluidAudioSpeechRecognition] Model download failed on attempt \(attempt + 1, privacy: .public): \(error.localizedDescription, privacy: .public)")

                // Don't retry on last attempt
                if attempt < maxRetries - 1 {
                    // Exponential backoff: 2s, 4s, 8s, etc.
                    let delay = baseDelay * pow(2.0, Double(attempt))
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }

        // If all retries failed, throw the last error
        throw lastError ?? FluidAudioInternalError.modelDownloadFailed(attempts: maxRetries)
    }

    /// Fast-path: Load models if they already exist on disk (no download)
    func loadModelsIfAvailable() async throws {
        logger.info("[FluidAudioSpeechRecognition] Attempting to load cached models...")

        // Try to load models directly without downloading
        do {
            models = try await AsrModels.loadFromCache()

            guard let loadedModels = models else {
                throw FluidAudioInternalError.loadedModelsUnavailable
            }

            // Initialize ASR manager with optimized config for better accuracy
            let config = ASRConfig(
                sampleRate: Int(sampleRate)
            )

            asrManager = AsrManager(config: config)
            try await asrManager?.initialize(models: loadedModels)

            // Configure chunked recording manager with ASR manager reference
            await chunkedRecordingManager.configure(asrManager: asrManager)

            logger.info("[FluidAudioSpeechRecognition] Models loaded from cache successfully")
        } catch {
            logger.warning("[FluidAudioSpeechRecognition] Failed to load cached models: \(error, privacy: .public)")
            throw error
        }
    }

    /// Initialize FluidAudio models and manager
    func setupFluidAudio() async throws {
        logger.info("[FluidAudioSpeechRecognition] Setting up FluidAudio ASR...")

        do {
            // Download models if needed with retry logic and exponential backoff
            models = try await downloadModelsWithRetry()

            guard let downloadedModels = models else {
                throw FluidAudioInternalError.downloadedModelsUnavailable
            }

            // Initialize ASR manager with optimized config for better accuracy
            let config = ASRConfig(
                sampleRate: Int(sampleRate)
            )

            asrManager = AsrManager(config: config)
            try await asrManager?.initialize(models: downloadedModels)

            // Configure chunked recording manager with ASR manager reference
            await chunkedRecordingManager.configure(asrManager: asrManager)
        } catch {
            logger.error("[FluidAudioSpeechRecognition] Failed to initialize FluidAudio: \(error, privacy: .public)")
            logger.error("[FluidAudioSpeechRecognition] Error details: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Pre-warm audio hardware and converter pipeline so first hotkey press
    /// doesn't pay the full cold-start penalty.
    ///
    /// Returns true when prewarm completed successfully. Returns false when
    /// prewarm is skipped (e.g. microphone not authorized) or fails.
    @discardableResult
    public func prewarmRecordingPipeline() async -> Bool {
        guard !Task.isCancelled else {
            return false
        }

        guard !isShuttingDown else {
            return false
        }

        guard asrManager != nil else {
            return false
        }

        guard !isRecording else {
            return false
        }

        // Never touch AVAudioEngine input hardware until microphone permission
        // has already been granted by explicit user action.
        guard AVAudioApplication.shared.recordPermission == .granted else {
            logger.warning("[FluidAudioSpeechRecognition] Pre-warm skipped: microphone permission not granted")
            return false
        }

        guard defaultInputDeviceID() != nil else {
            logger.warning("[FluidAudioSpeechRecognition] Pre-warm skipped: no default audio input device")
            return false
        }

        logger.info("[FluidAudioSpeechRecognition] Pre-warming recording pipeline...")

        let warmEngine = AVAudioEngine()
        let inputNode = warmEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            logger.warning("[FluidAudioSpeechRecognition] Pre-warm skipped: failed to create output format")
            return false
        }

        let prewarmObservation = PrewarmObservationState()
        guard let warmProxy = FluidAudioTapProxy(
            owner: self,
            audioBufferProcessor: nil,
            inputFormat: inputFormat,
            outputFormat: outputFormat,
            onFirstConvertedBuffer: {
                prewarmObservation.markReceived()
            }
        ) else {
            logger.warning("[FluidAudioSpeechRecognition] Pre-warm skipped: failed to create tap proxy")
            return false
        }

        inputNode.removeTap(onBus: 0)
        installFluidAudioTap(
            inputNode: inputNode,
            bufferSize: 1024,
            format: inputFormat,
            proxy: warmProxy
        )

        do {
            warmEngine.prepare()
            try await Task.sleep(nanoseconds: hardwareSettleDelayNanoseconds)
            guard !Task.isCancelled else {
                await finishWarmEngine(
                    warmEngine: warmEngine,
                    inputNode: inputNode,
                    warmProxy: warmProxy
                )
                return false
            }
            try warmEngine.start()

            let didReceiveConvertedBuffer = await waitForConvertedBuffer(
                observation: prewarmObservation,
                timeout: prewarmConvertedBufferTimeout
            )
            let snapshot = defaultInputSnapshot(for: inputNode.outputFormat(forBus: 0))

            await finishWarmEngine(
                warmEngine: warmEngine,
                inputNode: inputNode,
                warmProxy: warmProxy
            )

            if let snapshot {
                updateRecordingPipelineWarmState(
                    snapshot: snapshot,
                    didReceiveConvertedBuffer: didReceiveConvertedBuffer
                )
            }

            if didReceiveConvertedBuffer {
                if let snapshot {
                    logger.info(
                        "[FluidAudioSpeechRecognition] Recording pipeline pre-warmed for \(self.describe(snapshot: snapshot), privacy: .public)"
                    )
                } else {
                    logger.info("[FluidAudioSpeechRecognition] Recording pipeline pre-warmed")
                }
                return true
            }

            if let snapshot {
                logger.warning(
                    "[FluidAudioSpeechRecognition] Pre-warm timed out before first converted buffer for \(self.describe(snapshot: snapshot), privacy: .public)"
                )
            } else {
                logger.warning("[FluidAudioSpeechRecognition] Pre-warm timed out before first converted buffer")
            }
            return false
        } catch {
            if let snapshot = defaultInputSnapshot(for: inputNode.outputFormat(forBus: 0)) {
                updateRecordingPipelineWarmState(
                    snapshot: snapshot,
                    didReceiveConvertedBuffer: false
                )
            } else {
                recordingPipelineWarmState = nil
            }
            logger.warning("[FluidAudioSpeechRecognition] Pre-warm failed: \(error.localizedDescription, privacy: .public)")
            await finishWarmEngine(
                warmEngine: warmEngine,
                inputNode: inputNode,
                warmProxy: warmProxy
            )
            return false
        }
    }

    public func startRecording() async throws {
        guard !isShuttingDown else {
            throw FluidAudioInternalError.shuttingDown
        }

        // Initialize FluidAudio if not already done
        if asrManager == nil {
            try await setupFluidAudio()
        }

        guard asrManager != nil else {
            throw FluidAudioInternalError.asrUnavailable
        }

        // Ensure we're not already recording
        if isRecording {
            logger.info("[FluidAudioSpeechRecognition] Already recording, stopping first...")
            stopRecording()
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }

        // Reset all state for fresh transcription
        await MainActor.run {
            completionLock.withLock {
                hasCalledCompletion = false
            }
            userInitiatedStop = false
        }
        await audioBufferProcessor.resetSession()

        // Clear UI transcription for fresh start
        await MainActor.run {
            self.transcription = ""
        }

        guard defaultInputDeviceID() != nil else {
            logger.error("[FluidAudioSpeechRecognition] Cannot start recording: no default audio input device")
            throw FluidAudioError.noInputDeviceAvailable
        }

        await cancelBackgroundRewarmIfNeeded()

        // Create fresh audio engine - it will use the system default input device
        // This ensures we don't degrade Bluetooth audio quality when not recording
        for startupAttempt in 1 ... maximumRecordingStartupAttempts {
            audioEngine = AVAudioEngine()

            guard let audioEngine else {
                throw FluidAudioInternalError.audioEngineCreationFailed
            }
            var recordingEngine = audioEngine

            // Access inputNode - it will use the current system default
            var inputNode = recordingEngine.inputNode
            var inputFormat = inputNode.outputFormat(forBus: 0)
            var startupProxy: FluidAudioTapProxy?
            var didCleanupAttempt = false

            func cleanupAttemptIfNeeded() async {
                guard !didCleanupAttempt else { return }
                didCleanupAttempt = true
                await cleanupRecordingStartupAttempt(
                    recordingEngine: recordingEngine,
                    inputNode: inputNode,
                    proxy: startupProxy
                )
            }

            do {
                if let currentSnapshot = defaultInputSnapshot(for: inputFormat),
                   shouldForceRecordingPipelinePrewarm(
                       currentSnapshot: currentSnapshot,
                       warmState: recordingPipelineWarmState
                   )
                {
                    logger.info(
                        "[FluidAudioSpeechRecognition] Warm state missing or stale for \(self.describe(snapshot: currentSnapshot), privacy: .public); forcing prewarm before recording"
                    )

                    cleanupAudioEngine()
                    let didPrewarm = await prewarmRecordingPipeline()
                    if !didPrewarm {
                        logger.warning("[FluidAudioSpeechRecognition] Forced prewarm did not complete before recording start; continuing with a fresh engine")
                    }

                    self.audioEngine = AVAudioEngine()

                    guard let refreshedAudioEngine = self.audioEngine else {
                        throw FluidAudioInternalError.audioEngineRecreationFailed
                    }

                    recordingEngine = refreshedAudioEngine
                    inputNode = refreshedAudioEngine.inputNode
                    inputFormat = inputNode.outputFormat(forBus: 0)
                }

                // Log input format
                logger.debug("[FluidAudioSpeechRecognition] Input format: \(inputFormat.sampleRate, privacy: .public)Hz, \(inputFormat.channelCount, privacy: .public) channel(s)")

                // Convert to 16kHz mono for FluidAudio
                // This automatically handles ANY input sample rate (44.1kHz, 48kHz, 96kHz, etc.)
                guard let outputFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: sampleRate,
                    channels: 1,
                    interleaved: false
                ) else {
                    logger.error("[FluidAudioSpeechRecognition] Failed to create output audio format")
                    throw FluidAudioError.microphoneSetupFailed
                }

                // Remove any existing tap
                inputNode.removeTap(onBus: 0)

                let startupObservation = PrewarmObservationState()

                // Install tap via proxy to avoid MainActor isolation issues
                guard let proxy = FluidAudioTapProxy(
                    owner: self,
                    audioBufferProcessor: audioBufferProcessor,
                    inputFormat: inputFormat,
                    outputFormat: outputFormat,
                    onFirstConvertedBuffer: {
                        startupObservation.markReceived()
                    }
                ) else {
                    logger.error("[FluidAudioSpeechRecognition] Failed to create audio tap proxy")
                    throw FluidAudioError.microphoneSetupFailed
                }
                startupProxy = proxy
                tapProxy = proxy

                logger.debug("[FluidAudioSpeechRecognition] Installing audio tap...")
                installFluidAudioTap(
                    inputNode: inputNode,
                    bufferSize: 1024,
                    format: inputFormat,
                    proxy: proxy
                )

                // Start audio engine with proper timing to avoid -10877 error
                // On macOS, we don't need AVAudioSession (iOS-only)
                if !recordingEngine.isRunning {
                    logger.debug("[FluidAudioSpeechRecognition] Preparing audio engine...")

                    // Prepare the engine - this configures the audio hardware
                    recordingEngine.prepare()

                    // CRITICAL: Wait for hardware configuration to complete
                    // This prevents kAudioUnitErr_CannotDoInCurrentContext (-10877)
                    try await Task.sleep(nanoseconds: hardwareSettleDelayNanoseconds)

                    logger.info("[FluidAudioSpeechRecognition] Starting audio engine...")
                    try recordingEngine.start()
                    logger.info("[FluidAudioSpeechRecognition] Audio engine started successfully")
                } else {
                    logger.debug("[FluidAudioSpeechRecognition] Audio engine already running")
                }

                await chunkedRecordingManager.startRecording()

                let didReceiveInitialBuffer = await waitForConvertedBuffer(
                    observation: startupObservation,
                    timeout: recordingStartupConvertedBufferTimeout
                )

                if let activeSnapshot = defaultInputSnapshot(for: inputNode.outputFormat(forBus: 0)) {
                    updateRecordingPipelineWarmState(
                        snapshot: activeSnapshot,
                        didReceiveConvertedBuffer: didReceiveInitialBuffer
                    )
                }

                if didReceiveInitialBuffer {
                    isRecording = true
                    startAudioLevelMonitoring()

                    // Arm silence detection (actual timer starts after first detected speech).
                    armSilenceDetection()

                    logger.info("[FluidAudioSpeechRecognition] Recording started successfully")
                    logger.debug("[FluidAudioSpeechRecognition] Waiting for audio data...")
                    return
                }

                logger.warning(
                    "[FluidAudioSpeechRecognition] No converted audio received within \(self.recordingStartupConvertedBufferTimeout, privacy: .public)s on startup attempt \(startupAttempt, privacy: .public)"
                )
                await cleanupAttemptIfNeeded()

                guard shouldRetryRecordingStartupAfterInitialBufferTimeout(
                    completedAttempts: startupAttempt,
                    maximumAttempts: maximumRecordingStartupAttempts
                ) else {
                    throw FluidAudioInternalError.startupTimedOut
                }

                logger.info("[FluidAudioSpeechRecognition] Retrying recording startup after initial buffer timeout")
                try? await Task.sleep(nanoseconds: recordingStartupRetryDelayNanoseconds)
            } catch {
                await cleanupAttemptIfNeeded()
                throw error
            }
        }

        // Unreachable with the current control flow, but retained as a defensive guard
        // so future edits cannot accidentally fall through without starting recording.
        throw FluidAudioError.microphoneSetupFailed
    }

    public func stopRecording() {
        logger.info("[FluidAudioSpeechRecognition] Stopping recording...")

        userInitiatedStop = true
        let stopRequestedAt = Date()

        // Mark as stopped for UI immediately
        isRecording = false
        audioLevel = 0.0
        waveformSamples = []
        stopAudioLevelMonitoring()
        stopSilenceDetectionTimer()

        // Capture the tap proxy reference before cleanup
        let proxy = tapProxy

        // Safety watchdog: if the cleanup chain below hasn't fired onTranscriptionComplete
        // within 40 seconds (must exceed 35s finalize timeout + margin), force-fire it so
        // the UI never gets stuck in "processing".
        safetyWatchdogTask = Task { @MainActor [weak self, completionLock] in
            try? await Task.sleep(nanoseconds: 40_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            let shouldForce = completionLock.withLock {
                let should = !self.hasCalledCompletion
                if should { self.hasCalledCompletion = true }
                return should
            }
            if shouldForce {
                logger.warning("[FluidAudio] Safety timeout — forcing completion after 40s")
                onTranscriptionComplete?(transcription, 0)
            }
        }

        // CRITICAL: Don't immediately stop audio engine
        // Audio tap has internal buffers that need time to be delivered
        // Stopping engine immediately would lose trailing audio
        Task { @MainActor in
            guard !isShuttingDown else {
                logger.debug("[FluidAudio] stop finalization skipped because shutdown is in progress")
                return
            }

            let speechSnapshot = await audioBufferProcessor.snapshot()
            let stopDecision = RecordingStopFinalizationPolicy.resolve(
                RecordingStopFinalizationInput(
                    stopRequestedAt: stopRequestedAt,
                    lastSpeechDetectedAt: speechSnapshot.lastSpeechDetectedAt,
                    minimumFlushDelay: trailingBufferDelay,
                    requiredSpeechTailGap: requiredSpeechTailGap,
                    maximumFlushDelay: maximumTrailingBufferDelay
                )
            )
            let lastSpeechDescription = stopDecision.timeSinceLastSpeechAtStop.map {
                String(format: "%.3f", $0)
            } ?? "none"
            let chosenDelayStr = String(format: "%.3f", stopDecision.delayBeforeTapRemoval)
            logger.debug(
                "[FluidAudio] stop requested; last speech delta: \(lastSpeechDescription, privacy: .public)s; delay: \(chosenDelayStr, privacy: .public)s"
            )

            // Step 1: Wait for audio tap to deliver remaining buffers and preserve short trailing speech.
            logger.debug("[FluidAudio] Waiting for audio tap buffer delivery...")
            try? await Task.sleep(nanoseconds: UInt64(stopDecision.delayBeforeTapRemoval * 1_000_000_000))

            // Step 2: Remove the tap first to stop new audio from being processed
            // This is safer than stopping the engine immediately
            if let engine = self.audioEngine {
                engine.inputNode.removeTap(onBus: 0)
                logger.debug("[FluidAudio] Audio tap removed")
            }

            // Step 3: Flush any residual converter output after tap removal.
            logger.debug("[FluidAudio] Flushing converter end-of-stream")
            if let proxy {
                let flushResult = await proxy.flushEndOfStream()
                logFlushResult(flushResult, context: "recording stop")
            }

            // Step 4: Wait for ALL pending audio processing tasks to complete
            // This is the key fix - ensures no audio samples are lost in transit
            if let proxy {
                await proxy.waitForPendingTasks()
            }

            let finalChunkSampleCount = await self.chunkedRecordingManager.getCurrentBufferSize()
            await self.chunkedRecordingManager.forceChunkBoundary()

            // Step 5: NOW clean up audio engine safely (all audio has been processed)
            logger.debug("[FluidAudio] Cleaning up audio engine...")
            if let engine = self.audioEngine, engine.isRunning {
                engine.stop()
            }
            self.audioEngine = nil
            self.tapProxy = nil

            // Note: On macOS, we don't need to manually deactivate audio sessions
            // The system automatically manages audio resources when the engine stops

            guard !isShuttingDown else {
                logger.debug("[FluidAudio] Suppressing final transcription delivery during shutdown")
                return
            }

            // Step 6: Finalize chunked recording and get complete transcription
            await self.finalizeChunkedTranscription(
                diagnostics: StopFinalizationDiagnostics(
                    stopRequestedAt: stopRequestedAt,
                    timeSinceLastSpeechAtStop: stopDecision.timeSinceLastSpeechAtStop,
                    chosenDelay: stopDecision.delayBeforeTapRemoval,
                    finalChunkSampleCount: finalChunkSampleCount
                )
            )
        }
    }

    fileprivate func applyProcessedAudioResult(_ result: AudioBufferProcessingResult) {
        guard !isShuttingDown else {
            return
        }

        if result.didDetectSpeechTransition {
            logger.info("[FluidAudioSpeechRecognition] First speech detected - starting silence timeout tracking")
        }

        if result.hasAudioActivity {
            resetSilenceDetectionTimer()
        }

        if let visualizationUpdate = result.visualizationUpdate {
            audioLevel = visualizationUpdate.audioLevel
            waveformSamples = visualizationUpdate.waveformSamples
        }
    }

    /// Finalize chunked recording and get complete transcription
    private func finalizeChunkedTranscription(diagnostics: StopFinalizationDiagnostics? = nil) async {
        logger.info("[FluidAudioSpeechRecognition] Finalizing chunked transcription...")

        // Cancel the safety watchdog — real completion is about to fire
        safetyWatchdogTask?.cancel()
        safetyWatchdogTask = nil

        // Get final transcription and metrics from chunked recording manager
        let (finalText, metrics) = await chunkedRecordingManager.finalize()

        // Log metrics for debugging
        await MetricsLogger.shared.log(metrics)

        let trimmedText = finalText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedText.isEmpty {
            // Update UI with final transcription
            transcription = trimmedText

            let duration = String(format: "%.1f", metrics.totalDuration)
            logger.info("[FluidAudioSpeechRecognition] Transcription complete (\(trimmedText.count, privacy: .public) chars, \(metrics.chunkCount, privacy: .public) chunks, \(duration, privacy: .public)s)")
        } else {
            logger.warning("[FluidAudioSpeechRecognition] Transcription returned empty text")
        }

        // Call completion callback with duration (thread-safe check) for both non-empty and empty
        // transcriptions so upper layers can resolve no-speech/error UI deterministically.
        let shouldCallCompletion = completionLock.withLock {
            let should = !hasCalledCompletion
            if should {
                hasCalledCompletion = true
            }
            return should
        }

        if shouldCallCompletion {
            if let diagnostics {
                let lastSpeechDescription = diagnostics.timeSinceLastSpeechAtStop.map {
                    String(format: "%.3f", $0)
                } ?? "none"
                let delayStr = String(format: "%.3f", diagnostics.chosenDelay)
                let samples = diagnostics.finalChunkSampleCount
                let textLen = trimmedText.count
                logger.debug(
                    "[FluidAudio] finalized; speech delta: \(lastSpeechDescription, privacy: .public)s; delay: \(delayStr, privacy: .public)s; samples: \(samples, privacy: .public); text len: \(textLen, privacy: .public)"
                )
            }
            onTranscriptionComplete?(trimmedText, metrics.totalDuration)
        }
    }

    private func startAudioLevelMonitoring() {
        audioLevelTimer?.invalidate()
        audioLevelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Smooth decay when no audio
                if self.audioLevel > 0.01 {
                    self.audioLevel *= 0.9
                }
            }
        }
    }

    private func stopAudioLevelMonitoring() {
        audioLevelTimer?.invalidate()
        audioLevelTimer = nil
    }

    // Removed continuous audio injection - it was causing buffer issues

    private func armSilenceDetection() {
        guard let appState else { return }

        let timeoutInterval = appState.silenceTimeoutSeconds
        if timeoutInterval <= 0 {
            logger.debug("[FluidAudioSpeechRecognition] Silence detection disabled (timeout: \(timeoutInterval, privacy: .public)s)")
            return
        }

        logger.debug("[FluidAudioSpeechRecognition] Silence timer armed (starts after first speech)")
    }

    /// Reset the silence detection timer - called when audio activity is detected
    private func resetSilenceDetectionTimer() {
        guard let appState, isRecording else { return }

        // Invalidate existing timer
        silenceDetectionTimer?.invalidate()

        // Start a fresh timer
        let timeoutInterval = appState.silenceTimeoutSeconds
        if timeoutInterval <= 0 {
            logger.debug("[FluidAudioSpeechRecognition] Silence detection disabled (timeout: \(timeoutInterval, privacy: .public)s)")
            return
        }
        silenceDetectionTimer = Timer.scheduledTimer(withTimeInterval: timeoutInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, isRecording else { return }

                logger.info("[FluidAudioSpeechRecognition] Silence detected for \(timeoutInterval, privacy: .public)s, stopping recording")
                sendSilenceTimeoutNotification()
                stopRecording()
            }
        }
    }

    /// Send a notification when recording stops due to silence timeout
    private func sendSilenceTimeoutNotification() {
        Task { @MainActor in
            NotificationManager.shared.sendNotification(
                title: "Transcription stopped",
                body: "Transcription automatically stopped after silence detected",
                identifier: "silence-timeout"
            )
        }
    }

    private func stopSilenceDetectionTimer() {
        silenceDetectionTimer?.invalidate()
        silenceDetectionTimer = nil
    }

    // Removed silence buffer injection - it was causing buffer corruption

    // MARK: - Audio Device Helpers
}

// MARK: - Audio Tap Proxy

/// Non-isolated proxy to handle audio tap callbacks without MainActor isolation
/// SAFETY: @unchecked Sendable is used because:
/// 1. Audio tap callbacks occur on audio render threads (not the main thread)
/// 2. Shared mutable state (pendingTaskCount, allTasksCompletedContinuation) is protected by NSLock
/// 3. The owner reference is weak and only accessed for dispatching to MainActor
/// 4. The converter and outputFormat are immutable after initialization
final class FluidAudioTapProxy: @unchecked Sendable {
    /// SAFETY: nonisolated(unsafe) because the owner is MainActor-isolated and we only
    /// dispatch back to it asynchronously. The weak reference prevents retain cycles.
    private nonisolated(unsafe) weak var owner: FluidAudioSpeechRecognition?
    private let audioBufferProcessor: FluidAudioBufferProcessor?
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let preferredOutputFrameCapacity: AVAudioFrameCount
    private let onFirstConvertedBuffer: (@Sendable () -> Void)?
    private let logger = Logger(subsystem: "com.flowstay.app", category: "FluidAudioTapProxy")
    private let converterLock = NSLock()
    private let firstConvertedBufferLock = NSLock()
    private let flushQueue = DispatchQueue(label: "com.flowstay.app.audio.tap-proxy.flush")
    private let processingBackpressureThreshold = 32
    private let tapCountLock = OSAllocatedUnfairLock()
    /// SAFETY: nonisolated(unsafe) to allow use from audio render thread
    /// with explicit locking where needed. `tapCount` is protected by `tapCountLock`.
    private nonisolated(unsafe) var tapCount = 0
    private nonisolated(unsafe) var didSignalFirstConvertedBuffer = false
    private nonisolated(unsafe) var hasLoggedUIBackpressureThisSession = false

    /// Track pending audio processing tasks to ensure all audio is processed before finalization
    private let pendingTasksLock = NSLock()
    private nonisolated(unsafe) var pendingTaskCount: Int = 0

    /// Signal when all pending tasks have completed
    private nonisolated(unsafe) var allTasksCompletedContinuation: CheckedContinuation<Bool, Never>?

    fileprivate init?(
        owner: FluidAudioSpeechRecognition,
        audioBufferProcessor: FluidAudioBufferProcessor?,
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        onFirstConvertedBuffer: (@Sendable () -> Void)? = nil
    ) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            // Cannot use self.logger before all stored properties are initialized,
            // so use a local Logger instance for the early-return path.
            Logger(subsystem: "com.flowstay.app", category: "FluidAudioTapProxy")
                .error("[FluidAudioTapProxy] Failed to create audio converter from \(inputFormat.sampleRate, privacy: .public)Hz to \(outputFormat.sampleRate, privacy: .public)Hz")
            return nil
        }
        self.owner = owner
        self.audioBufferProcessor = audioBufferProcessor
        self.outputFormat = outputFormat
        self.converter = converter
        self.preferredOutputFrameCapacity = convertedOutputFrameCapacity(
            inputFrameCount: 1024,
            inputSampleRate: inputFormat.sampleRate,
            outputSampleRate: outputFormat.sampleRate
        )
        self.onFirstConvertedBuffer = onFirstConvertedBuffer

        logger.info("[FluidAudioTapProxy] Initialized - converting \(inputFormat.sampleRate, privacy: .public)Hz to \(outputFormat.sampleRate, privacy: .public)Hz")
    }

    /// Wait for all pending audio processing tasks to complete (with 5-second timeout).
    /// If a pending task crashes before calling `decrementPendingTasks()`, the
    /// continuation would never resume — the timeout prevents an infinite hang.
    func waitForPendingTasks() async {
        let count = pendingTasksLock.withLock { pendingTaskCount }
        if count == 0 {
            logger.debug("[FluidAudioTapProxy] No pending tasks to wait for")
            return
        }

        logger.info("[FluidAudioTapProxy] Waiting for \(count) pending audio processing tasks...")

        let didComplete = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            // Try to register our continuation
            let alreadyDone = pendingTasksLock.withLock { () -> Bool in
                if pendingTaskCount == 0 {
                    return true
                }
                allTasksCompletedContinuation = continuation
                return false
            }

            if alreadyDone {
                continuation.resume(returning: true)
                return
            }

            // Start a timeout watchdog — if the continuation hasn't been resumed in 5s, force it.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                pendingTasksLock.withLock {
                    if let stale = self.allTasksCompletedContinuation {
                        self.allTasksCompletedContinuation = nil
                        stale.resume(returning: false)
                    }
                }
            }
        }

        if didComplete {
            logger.info("[FluidAudioTapProxy] All pending tasks completed")
        } else {
            let remaining = pendingTasksLock.withLock { pendingTaskCount }
            logger.warning("[FluidAudioTapProxy] Timed out waiting for \(remaining) pending tasks — continuing anyway")
        }
    }

    /// Increment pending task count
    private nonisolated func incrementPendingTasks() -> Int {
        pendingTasksLock.withLock {
            pendingTaskCount += 1
            return pendingTaskCount
        }
    }

    /// Decrement pending task count and signal completion if zero
    private nonisolated func decrementPendingTasks() {
        pendingTasksLock.withLock {
            pendingTaskCount -= 1
            if pendingTaskCount == 0, let continuation = allTasksCompletedContinuation {
                allTasksCompletedContinuation = nil
                continuation.resume(returning: true)
            }
        }
    }

    private nonisolated func signalFirstConvertedBufferIfNeeded() {
        let shouldSignal = firstConvertedBufferLock.withLock { () -> Bool in
            guard !didSignalFirstConvertedBuffer else {
                return false
            }

            didSignalFirstConvertedBuffer = true
            return true
        }

        if shouldSignal {
            onFirstConvertedBuffer?()
        }
    }

    @discardableResult
    private nonisolated func emitConvertedBuffer(
        _ convertedBuffer: AVAudioPCMBuffer,
        sourceDescription: String,
        logTapMetrics: Bool
    ) -> Bool {
        guard let channelData = convertedBuffer.floatChannelData,
              convertedBuffer.frameLength > 0
        else {
            logger.debug("[FluidAudioTapProxy] \(sourceDescription, privacy: .public): no channel data or zero frame length")
            return false
        }

        signalFirstConvertedBufferIfNeeded()

        guard let audioBufferProcessor else {
            if logTapMetrics {
                logger.debug("[FluidAudioTapProxy] \(sourceDescription, privacy: .public): converted buffer observed during prewarm")
            }
            return true
        }

        let samples = Array(UnsafeBufferPointer(
            start: channelData.pointee,
            count: Int(convertedBuffer.frameLength)
        ))

        let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))

        if logTapMetrics {
            let maxAmplitude = samples.map { abs($0) }.max() ?? 0
            logger.debug(
                "[FluidAudioTapProxy] \(sourceDescription, privacy: .public): \(samples.count, privacy: .public) samples, max amplitude: \(maxAmplitude, privacy: .public), RMS: \(rms, privacy: .public)"
            )
        }

        let pendingCount = incrementPendingTasks()
        let suppressVisualization = pendingCount > processingBackpressureThreshold
        if suppressVisualization {
            let shouldLog = pendingTasksLock.withLock { () -> Bool in
                guard !hasLoggedUIBackpressureThisSession else {
                    return false
                }
                hasLoggedUIBackpressureThisSession = true
                return true
            }

            if shouldLog {
                logger.warning(
                    "[FluidAudioTapProxy] UI backpressure activated at \(pendingCount, privacy: .public) pending tasks; preserving transcription and skipping visualization updates"
                )
            }
        }

        Task { [weak self, weak owner] in
            defer { self?.decrementPendingTasks() }
            let result = await audioBufferProcessor.process(
                samples: samples,
                rms: rms,
                suppressVisualization: suppressVisualization
            )
            guard result.requiresMainActorUpdate, let owner else { return }
            await owner.applyProcessedAudioResult(result)
        }

        return true
    }

    nonisolated func handleTap(buffer: AVAudioPCMBuffer, time _: AVAudioTime) {
        let currentTapCount = tapCountLock.withLock { () -> Int in
            tapCount += 1
            return tapCount
        }
        let shouldLogTapMetrics = currentTapCount <= 10 || currentTapCount % 10 == 0

        // Log every tap for debugging microphone issues
        if shouldLogTapMetrics {
            logger.debug("[FluidAudioTapProxy] Tap #\(currentTapCount, privacy: .public): buffer frameLength=\(buffer.frameLength, privacy: .public), format=\(buffer.format, privacy: .public)")
        }

        // Convert to 16kHz mono
        let frameCapacity = convertedOutputFrameCapacity(
            inputFrameCount: buffer.frameLength,
            inputSampleRate: buffer.format.sampleRate,
            outputSampleRate: outputFormat.sampleRate
        )
#if DEBUG
        if shouldLogTapMetrics {
            logger.debug(
                "[FluidAudioTapProxy] Tap #\(currentTapCount, privacy: .public): allocating \(frameCapacity, privacy: .public) output frames for \(buffer.frameLength, privacy: .public) input frames at \(buffer.format.sampleRate, privacy: .public)Hz -> \(self.outputFormat.sampleRate, privacy: .public)Hz"
            )
        }
#endif
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            logger.error("[FluidAudioTapProxy] Failed to create converted buffer")
            return
        }

        var error: NSError?
        let status: AVAudioConverterOutputStatus = converterLock.withLock {
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
        }

        if let error {
            if shouldLogTapMetrics {
                logger.error("[FluidAudioTapProxy] Conversion error: \(error, privacy: .public)")
            }
            return
        }

        if status != .haveData, shouldLogTapMetrics {
            logger.debug(
                "[FluidAudioTapProxy] Tap #\(currentTapCount, privacy: .public): conversion returned status \(String(describing: status), privacy: .public)"
            )
        }

        _ = emitConvertedBuffer(
            convertedBuffer,
            sourceDescription: "Tap #\(currentTapCount)",
            logTapMetrics: shouldLogTapMetrics
        )
    }

    func flushEndOfStream(
        maxIterations: Int = 100,
        maxDuration: TimeInterval = 1.0
    ) async -> FlushResult {
        await withCheckedContinuation { continuation in
            flushQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .completed)
                    return
                }

                continuation.resume(returning: self.performEndOfStreamFlush(
                    maxIterations: maxIterations,
                    maxDuration: maxDuration
                ))
            }
        }
    }

    private nonisolated func performEndOfStreamFlush(
        maxIterations: Int,
        maxDuration: TimeInterval
    ) -> FlushResult {
        logger.debug("[FluidAudioTapProxy] Starting converter EOS flush")

        let startedAt = Date()
        var iteration = 0

        while iteration < maxIterations {
            if Date().timeIntervalSince(startedAt) >= maxDuration {
                return .timeLimitHit(
                    elapsed: Date().timeIntervalSince(startedAt),
                    iterations: iteration
                )
            }

            iteration += 1

            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: preferredOutputFrameCapacity
            ) else {
                logger.error("[FluidAudioTapProxy] Failed to create EOS flush buffer")
                return .conversionError
            }

            var error: NSError?
            let status: AVAudioConverterOutputStatus = converterLock.withLock {
                converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    outStatus.pointee = .endOfStream
                    return nil
                }
            }

            if let error {
                logger.error("[FluidAudioTapProxy] EOS flush conversion error: \(error, privacy: .public)")
                return .conversionError
            }

            if convertedBuffer.frameLength > 0 {
                logger.debug(
                    "[FluidAudioTapProxy] EOS flush iteration \(iteration, privacy: .public) emitted \(convertedBuffer.frameLength, privacy: .public) frames"
                )
                _ = emitConvertedBuffer(
                    convertedBuffer,
                    sourceDescription: "EOS flush #\(iteration)",
                    logTapMetrics: true
                )
            } else {
                logger.debug("[FluidAudioTapProxy] EOS flush iteration \(iteration, privacy: .public) emitted no frames")
            }

            if status != .haveData || convertedBuffer.frameLength == 0 {
                return .completed
            }
        }

        return .iterationCapHit(iterations: iteration)
    }
}

/// Non-isolated helper to install tap without MainActor isolation
private func installFluidAudioTap(
    inputNode: AVAudioInputNode,
    bufferSize: AVAudioFrameCount,
    format: AVAudioFormat,
    proxy: FluidAudioTapProxy
) {
    inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: proxy.handleTap(buffer:time:))
}
