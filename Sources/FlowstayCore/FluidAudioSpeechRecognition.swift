@preconcurrency import AVFoundation
import Combine
import FluidAudio
import Foundation
import os
import UserNotifications

/// Errors that can occur during FluidAudio speech recognition
public enum FluidAudioError: Error {
    case microphoneSetupFailed
    case modelsNotLoaded
    case transcriptionFailed
}

/// FluidAudio-based Speech Recognition using Parakeet TDT ASR
/// Provides fast, accurate, local speech recognition with better real-time performance than Whisper
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

    /// Callback when transcription is complete (with duration)
    public var onTranscriptionComplete: (@Sendable (String, TimeInterval) -> Void)?

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
    private nonisolated(unsafe) var models: AsrModels?

    /// Chunked recording manager for unlimited-length recordings
    private let chunkedRecordingManager = ChunkedRecordingManager()

    /// Audio components
    private var audioEngine: AVAudioEngine?

    private var audioLevelTimer: Timer?

    /// Audio tap proxy for non-isolated processing
    private var tapProxy: FluidAudioTapProxy?

    /// Download monitoring task
    private var downloadMonitorTask: Task<Void, Never>?

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

    /// Silence detection timer
    private var silenceDetectionTimer: Timer?

    // Reference to AppState for silence timeout configuration
    private weak var appState: AppState?
    private var hasDetectedSpeechInCurrentSession = false
    private var lastSpeechDetectedAt: Date?

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
    }

    override public convenience init() {
        self.init(appState: nil)
    }

    deinit {
        cleanup()
    }

    /// Clean up resources when done
    public nonisolated func cleanup() {
        Task { @MainActor in
            // Cancel download monitoring task
            downloadMonitorTask?.cancel()

            // Clean up timers to prevent leaks
            audioLevelTimer?.invalidate()
            audioLevelTimer = nil
            silenceDetectionTimer?.invalidate()
            silenceDetectionTimer = nil

            // Clean up audio engine safely
            cleanupAudioEngine()

            // Reset chunked recording manager
            await chunkedRecordingManager.reset()

            logger.info("[FluidAudioSpeechRecognition] Cleaned up resources")
        }
    }

    /// Safely cleanup audio engine with proper state checks
    private func cleanupAudioEngine() {
        guard let engine = audioEngine else { return }

        // Remove tap first (safe even if not installed)
        engine.inputNode.removeTap(onBus: 0)

        // Only stop if running
        if engine.isRunning {
            engine.stop()
        }

        audioEngine = nil
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
        throw lastError ?? NSError(
            domain: "FluidAudioSpeechRecognition",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Failed to download models after \(maxRetries) attempts"]
        )
    }

    /// Fast-path: Load models if they already exist on disk (no download)
    func loadModelsIfAvailable() async throws {
        logger.info("[FluidAudioSpeechRecognition] Attempting to load cached models...")

        // Try to load models directly without downloading
        do {
            models = try await AsrModels.loadFromCache()

            guard let loadedModels = models else {
                throw NSError(
                    domain: "FluidAudioSpeechRecognition",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Models loaded but unexpectedly nil"]
                )
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
                throw NSError(
                    domain: "FluidAudioSpeechRecognition",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Models downloaded but unexpectedly nil"]
                )
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

        guard let warmProxy = FluidAudioTapProxy(
            owner: self,
            inputFormat: inputFormat,
            outputFormat: outputFormat
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
            try await Task.sleep(nanoseconds: 30_000_000) // 30ms
            try warmEngine.start()
            try? await Task.sleep(nanoseconds: 40_000_000) // brief warm-up run
            logger.info("[FluidAudioSpeechRecognition] Recording pipeline pre-warmed")
            inputNode.removeTap(onBus: 0)
            if warmEngine.isRunning {
                warmEngine.stop()
            }
            return true
        } catch {
            logger.warning("[FluidAudioSpeechRecognition] Pre-warm failed: \(error.localizedDescription, privacy: .public)")
            inputNode.removeTap(onBus: 0)
            if warmEngine.isRunning {
                warmEngine.stop()
            }
            return false
        }
    }

    public func startRecording() async throws {
        // Initialize FluidAudio if not already done
        if asrManager == nil {
            try await setupFluidAudio()
        }

        guard asrManager != nil else {
            throw NSError(
                domain: "FluidAudioSpeechRecognition",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "FluidAudio ASR not available. Models may need to be downloaded."]
            )
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
            hasDetectedSpeechInCurrentSession = false
            lastSpeechDetectedAt = nil
        }

        // Clear UI transcription for fresh start
        await MainActor.run {
            self.transcription = ""
        }

        // Create fresh audio engine - it will use the system default input device
        // This ensures we don't degrade Bluetooth audio quality when not recording
        audioEngine = AVAudioEngine()

        guard let audioEngine else {
            throw NSError(
                domain: "FluidAudioSpeechRecognition",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create audio engine"]
            )
        }

        // Access inputNode - it will use the current system default
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

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

        // Install tap via proxy to avoid MainActor isolation issues
        guard let proxy = FluidAudioTapProxy(
            owner: self,
            inputFormat: inputFormat,
            outputFormat: outputFormat
        ) else {
            logger.error("[FluidAudioSpeechRecognition] Failed to create audio tap proxy")
            throw FluidAudioError.microphoneSetupFailed
        }
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
        if !audioEngine.isRunning {
            logger.debug("[FluidAudioSpeechRecognition] Preparing audio engine...")

            // Prepare the engine - this configures the audio hardware
            audioEngine.prepare()

            // CRITICAL: Wait for hardware configuration to complete
            // This prevents kAudioUnitErr_CannotDoInCurrentContext (-10877)
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms - minimum delay to avoid race condition

            logger.info("[FluidAudioSpeechRecognition] Starting audio engine...")
            try audioEngine.start()
            logger.info("[FluidAudioSpeechRecognition] Audio engine started successfully")
        } else {
            logger.debug("[FluidAudioSpeechRecognition] Audio engine already running")
        }

        isRecording = true
        startAudioLevelMonitoring()

        // Start chunked recording for unlimited-length support
        await chunkedRecordingManager.startRecording()

        // Arm silence detection (actual timer starts after first detected speech).
        startSilenceDetectionTimer()

        logger.info("[FluidAudioSpeechRecognition] Recording started successfully")
        logger.debug("[FluidAudioSpeechRecognition] Waiting for audio data...")
    }

    public func stopRecording() {
        logger.info("[FluidAudioSpeechRecognition] Stopping recording...")

        userInitiatedStop = true
        let stopRequestedAt = Date()
        let stopDecision = RecordingStopFinalizationPolicy.resolve(
            RecordingStopFinalizationInput(
                stopRequestedAt: stopRequestedAt,
                lastSpeechDetectedAt: lastSpeechDetectedAt,
                minimumFlushDelay: trailingBufferDelay,
                requiredSpeechTailGap: requiredSpeechTailGap,
                maximumFlushDelay: maximumTrailingBufferDelay
            )
        )

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
                self.logger.warning("[FluidAudio] Safety timeout — forcing completion after 40s")
                self.onTranscriptionComplete?(self.transcription, 0)
            }
        }

        // CRITICAL: Don't immediately stop audio engine
        // Audio tap has internal buffers that need time to be delivered
        // Stopping engine immediately would lose trailing audio
        Task { @MainActor in
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

            // Step 3: Wait for ALL pending audio processing tasks to complete
            // This is the key fix - ensures no audio samples are lost in transit
            if let proxy {
                await proxy.waitForPendingTasks()
            }

            let finalChunkSampleCount = await self.chunkedRecordingManager.getCurrentBufferSize()
            await self.chunkedRecordingManager.forceChunkBoundary()

            // Step 4: NOW clean up audio engine safely (all audio has been processed)
            logger.debug("[FluidAudio] Cleaning up audio engine...")
            if let engine = self.audioEngine, engine.isRunning {
                engine.stop()
            }
            self.audioEngine = nil

            // Note: On macOS, we don't need to manually deactivate audio sessions
            // The system automatically manages audio resources when the engine stops

            // Step 5: Finalize chunked recording and get complete transcription
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

    /// Process audio buffer - forward samples to chunked recording manager
    fileprivate func processAudioBuffer(_ samples: [Float], rms: Float? = nil) async {
        let computedRms = rms ?? sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
        let peakAmplitude = samples.map { abs($0) }.max() ?? 0
        let now = Date()
        let hasStrongSpeechSignal = computedRms > silenceThreshold || peakAmplitude > peakSpeechThreshold
        let hasWeakSpeechSignal = computedRms > lowSignalThreshold || peakAmplitude > (peakSpeechThreshold * 0.6)

        let hasAudioActivity: Bool
        if hasStrongSpeechSignal {
            hasAudioActivity = true
            lastSpeechDetectedAt = now
        } else if let lastSpeechDetectedAt,
                  now.timeIntervalSince(lastSpeechDetectedAt) <= speechHangoverDuration,
                  hasWeakSpeechSignal
        {
            // Hangover window prevents cutting off at brief low-volume tails between words.
            hasAudioActivity = true
        } else {
            hasAudioActivity = false
        }

        await updateAudioLevel(rms: computedRms)
        updateWaveformSamples(from: samples, rms: computedRms)

        if hasAudioActivity {
            if !hasDetectedSpeechInCurrentSession {
                hasDetectedSpeechInCurrentSession = true
                logger.info("[FluidAudioSpeechRecognition] First speech detected - starting silence timeout tracking")
            }
            resetSilenceDetectionTimer()
        }

        // Forward samples to chunked recording manager for memory-efficient processing
        await chunkedRecordingManager.appendSamples(samples, hasAudioActivity: hasAudioActivity)
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

            logger.info("[FluidAudioSpeechRecognition] Transcription complete (\(trimmedText.count, privacy: .public) chars, \(metrics.chunkCount, privacy: .public) chunks, \(String(format: "%.1f", metrics.totalDuration), privacy: .public)s)")
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

    /// Update audio level from RMS value
    private func updateAudioLevel(rms: Float) async {
        // Convert to decibels and normalize with a higher noise floor
        // so ambient room noise maps near zero and only speech drives the visualization
        let avgPower = 20 * log10(max(0.0001, rms))
        let noiseFloor: Float = -35 // dB — typical quiet room is ~-40dB
        let normalizedPower = (avgPower - noiseFloor) / -noiseFloor // 0 at floor, 1 at 0dB

        audioLevel = max(0, min(1, normalizedPower))
    }

    private func updateWaveformSamples(from samples: [Float], rms: Float) {
        guard !samples.isEmpty else {
            waveformSamples = []
            return
        }

        if rms < waveformNoiseFloorRms {
            waveformSamples = Array(repeating: 0, count: 32)
            return
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

        if waveformSamples.isEmpty {
            waveformSamples = next
            return
        }

        let smoothing: Float = 0.7
        waveformSamples = zip(waveformSamples, next).map { old, new in
            (old * smoothing) + (new * (1 - smoothing))
        }
    }

    private func startAudioLevelMonitoring() {
        audioLevelTimer?.invalidate()
        audioLevelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Smooth decay when no audio
                if audioLevel > 0.01 {
                    audioLevel *= 0.9
                }
            }
        }
    }

    private func stopAudioLevelMonitoring() {
        audioLevelTimer?.invalidate()
        audioLevelTimer = nil
    }

    // Removed continuous audio injection - it was causing buffer issues

    private func startSilenceDetectionTimer() {
        guard let appState else { return }

        let timeoutInterval = appState.silenceTimeoutSeconds
        if timeoutInterval <= 0 {
            logger.debug("[FluidAudioSpeechRecognition] Silence detection disabled (timeout: \(timeoutInterval, privacy: .public)s)")
            return
        }

        guard hasDetectedSpeechInCurrentSession else {
            logger.debug("[FluidAudioSpeechRecognition] Silence timer armed (starts after first speech)")
            return
        }

        silenceDetectionTimer?.invalidate()
        logger.debug("[FluidAudioSpeechRecognition] Starting silence detection timer with timeout: \(timeoutInterval, privacy: .public)s")

        silenceDetectionTimer = Timer.scheduledTimer(withTimeInterval: timeoutInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, isRecording else { return }

                logger.info("[FluidAudioSpeechRecognition] Silence timeout reached after \(timeoutInterval, privacy: .public)s, stopping recording")
                stopRecording()
            }
        }
    }

    /// Reset the silence detection timer - called when audio activity is detected
    private func resetSilenceDetectionTimer() {
        guard let appState, isRecording else { return }
        guard hasDetectedSpeechInCurrentSession else { return }

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
        hasDetectedSpeechInCurrentSession = false
        lastSpeechDetectedAt = nil
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
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let logger = Logger(subsystem: "com.flowstay.app", category: "FluidAudioTapProxy")
    /// SAFETY: nonisolated(unsafe) to allow use from audio render thread
    /// with explicit locking where needed.
    private nonisolated(unsafe) var tapCount = 0

    /// Track pending audio processing tasks to ensure all audio is processed before finalization
    private let pendingTasksLock = NSLock()
    private nonisolated(unsafe) var pendingTaskCount: Int = 0

    /// Signal when all pending tasks have completed
    private nonisolated(unsafe) var allTasksCompletedContinuation: CheckedContinuation<Bool, Never>?

    init?(owner: FluidAudioSpeechRecognition, inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            // Cannot use self.logger before all stored properties are initialized,
            // so use a local Logger instance for the early-return path.
            Logger(subsystem: "com.flowstay.app", category: "FluidAudioTapProxy")
                .error("[FluidAudioTapProxy] Failed to create audio converter from \(inputFormat.sampleRate, privacy: .public)Hz to \(outputFormat.sampleRate, privacy: .public)Hz")
            return nil
        }
        self.owner = owner
        self.outputFormat = outputFormat
        self.converter = converter

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
                self.pendingTasksLock.withLock {
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
    private nonisolated func incrementPendingTasks() {
        pendingTasksLock.withLock {
            pendingTaskCount += 1
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

    nonisolated func handleTap(buffer: AVAudioPCMBuffer, time _: AVAudioTime) {
        tapCount += 1

        // Log every tap for debugging microphone issues
        if tapCount <= 10 || tapCount % 10 == 0 { // Log first 10 taps, then every 10th
            logger.debug("[FluidAudioTapProxy] Tap #\(self.tapCount, privacy: .public): buffer frameLength=\(buffer.frameLength, privacy: .public), format=\(buffer.format, privacy: .public)")
        }

        // Convert to 16kHz mono
        let frameCapacity = UInt32(Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate)
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            logger.error("[FluidAudioTapProxy] Failed to create converted buffer")
            return
        }

        var error: NSError?
        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            if tapCount % 10 == 0 { // Log occasionally to avoid spam
                logger.error("[FluidAudioTapProxy] Conversion error: \(error, privacy: .public)")
            }
            return
        }

        // Extract samples
        guard let channelData = convertedBuffer.floatChannelData,
              convertedBuffer.frameLength > 0
        else {
            if tapCount <= 10 {
                logger.debug("[FluidAudioTapProxy] No channel data or zero frame length")
            }
            return
        }

        let samples = Array(UnsafeBufferPointer(
            start: channelData.pointee,
            count: Int(convertedBuffer.frameLength)
        ))

        let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))

        // Log periodically for debugging - more frequent initially
        if tapCount <= 10 || tapCount % 10 == 0 { // Log first 10 taps, then every 10th
            let maxAmplitude = samples.map { abs($0) }.max() ?? 0
            logger.debug("[FluidAudioTapProxy] Tap #\(self.tapCount, privacy: .public): \(samples.count, privacy: .public) samples, max amplitude: \(maxAmplitude, privacy: .public), RMS: \(rms, privacy: .public)")
        }

        // Track pending task before starting
        incrementPendingTasks()

        // Send to owner for processing
        Task { @MainActor [weak self, weak owner] in
            defer { self?.decrementPendingTasks() }
            await owner?.processAudioBuffer(samples, rms: rms)
        }
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
