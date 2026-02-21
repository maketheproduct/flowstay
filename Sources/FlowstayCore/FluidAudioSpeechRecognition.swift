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
    @Published public var isRecording = false
    @Published public var transcription = ""
    @Published public var audioLevel: Float = 0.0
    @Published public var waveformSamples: [Float] = []

    /// Callback when transcription is complete (with duration)
    public var onTranscriptionComplete: (@Sendable (String, TimeInterval) -> Void)?

    /// Thread-safe completion tracking using OSAllocatedUnfairLock
    private let completionLock = OSAllocatedUnfairLock()
    /// SAFETY: nonisolated(unsafe) because access is protected by completionLock
    private nonisolated(unsafe) var hasCalledCompletion = false

    /// Track if user has initiated stop
    private var userInitiatedStop = false

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

            print("[FluidAudioSpeechRecognition] Cleaned up resources")
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
                print("[FluidAudioSpeechRecognition] Model download failed on attempt \(attempt + 1): \(error.localizedDescription)")

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
        print("[FluidAudioSpeechRecognition] Attempting to load cached models...")

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

            print("[FluidAudioSpeechRecognition] ✅ Models loaded from cache successfully")
        } catch {
            print("[FluidAudioSpeechRecognition] ⚠️ Failed to load cached models: \(error)")
            throw error
        }
    }

    /// Initialize FluidAudio models and manager
    func setupFluidAudio() async throws {
        print("[FluidAudioSpeechRecognition] Setting up FluidAudio ASR...")

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
            print("[FluidAudioSpeechRecognition] ❌ Failed to initialize FluidAudio: \(error)")
            print("[FluidAudioSpeechRecognition] Error details: \(String(describing: error))")
            throw error
        }
    }

    /// Pre-warm audio hardware and converter pipeline so first hotkey press
    /// doesn't pay the full cold-start penalty.
    public func prewarmRecordingPipeline() async {
        guard asrManager != nil else {
            return
        }

        guard !isRecording else {
            return
        }

        print("[FluidAudioSpeechRecognition] Pre-warming recording pipeline...")

        let warmEngine = AVAudioEngine()
        let inputNode = warmEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            print("[FluidAudioSpeechRecognition] Pre-warm skipped: failed to create output format")
            return
        }

        guard let warmProxy = FluidAudioTapProxy(
            owner: self,
            inputFormat: inputFormat,
            outputFormat: outputFormat
        ) else {
            print("[FluidAudioSpeechRecognition] Pre-warm skipped: failed to create tap proxy")
            return
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
            print("[FluidAudioSpeechRecognition] ✅ Recording pipeline pre-warmed")
        } catch {
            print("[FluidAudioSpeechRecognition] ⚠️ Pre-warm failed: \(error.localizedDescription)")
        }

        inputNode.removeTap(onBus: 0)
        if warmEngine.isRunning {
            warmEngine.stop()
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
            print("[FluidAudioSpeechRecognition] Already recording, stopping first...")
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
        print("[FluidAudioSpeechRecognition] 📊 Input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) channel(s)")

        // Convert to 16kHz mono for FluidAudio
        // This automatically handles ANY input sample rate (44.1kHz, 48kHz, 96kHz, etc.)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            print("[FluidAudioSpeechRecognition] Failed to create output audio format")
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
            print("[FluidAudioSpeechRecognition] Failed to create audio tap proxy")
            throw FluidAudioError.microphoneSetupFailed
        }
        tapProxy = proxy

        print("[FluidAudioSpeechRecognition] Installing audio tap...")
        installFluidAudioTap(
            inputNode: inputNode,
            bufferSize: 1024,
            format: inputFormat,
            proxy: proxy
        )

        // Start audio engine with proper timing to avoid -10877 error
        // On macOS, we don't need AVAudioSession (iOS-only)
        if !audioEngine.isRunning {
            print("[FluidAudioSpeechRecognition] Preparing audio engine...")

            // Prepare the engine - this configures the audio hardware
            audioEngine.prepare()

            // CRITICAL: Wait for hardware configuration to complete
            // This prevents kAudioUnitErr_CannotDoInCurrentContext (-10877)
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms - minimum delay to avoid race condition

            print("[FluidAudioSpeechRecognition] Starting audio engine...")
            try audioEngine.start()
            print("[FluidAudioSpeechRecognition] ✅ Audio engine started successfully")
        } else {
            print("[FluidAudioSpeechRecognition] Audio engine already running")
        }

        isRecording = true
        startAudioLevelMonitoring()

        // Start chunked recording for unlimited-length support
        await chunkedRecordingManager.startRecording()

        // Arm silence detection (actual timer starts after first detected speech).
        startSilenceDetectionTimer()

        print("[FluidAudioSpeechRecognition] Recording started successfully")
        print("[FluidAudioSpeechRecognition] Waiting for audio data...")
    }

    public func stopRecording() {
        print("[FluidAudioSpeechRecognition] Stopping recording...")

        userInitiatedStop = true

        // Mark as stopped for UI immediately
        isRecording = false
        audioLevel = 0.0
        waveformSamples = []
        stopAudioLevelMonitoring()
        stopSilenceDetectionTimer()

        // Capture the tap proxy reference before cleanup
        let proxy = tapProxy

        // CRITICAL: Don't immediately stop audio engine
        // Audio tap has internal buffers that need time to be delivered
        // Stopping engine immediately would lose trailing audio
        Task { @MainActor in
            // Step 1: Wait for audio tap to deliver remaining buffers
            // 400ms provides margin for slower systems and Bluetooth audio latency
            print("[FluidAudioSpeechRecognition] Waiting for audio tap buffer delivery...")
            try? await Task.sleep(nanoseconds: UInt64(trailingBufferDelay * 1_000_000_000))

            // Step 2: Remove the tap first to stop new audio from being processed
            // This is safer than stopping the engine immediately
            if let engine = self.audioEngine {
                engine.inputNode.removeTap(onBus: 0)
                print("[FluidAudioSpeechRecognition] Audio tap removed")
            }

            // Step 3: Wait for ALL pending audio processing tasks to complete
            // This is the key fix - ensures no audio samples are lost in transit
            if let proxy {
                await proxy.waitForPendingTasks()
            }

            // Step 4: NOW clean up audio engine safely (all audio has been processed)
            print("[FluidAudioSpeechRecognition] Cleaning up audio engine...")
            if let engine = self.audioEngine, engine.isRunning {
                engine.stop()
            }
            self.audioEngine = nil

            // Note: On macOS, we don't need to manually deactivate audio sessions
            // The system automatically manages audio resources when the engine stops

            // Step 5: Finalize chunked recording and get complete transcription
            await self.finalizeChunkedTranscription()
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
                print("[FluidAudioSpeechRecognition] First speech detected - starting silence timeout tracking")
            }
            resetSilenceDetectionTimer()
        }

        // Forward samples to chunked recording manager for memory-efficient processing
        await chunkedRecordingManager.appendSamples(samples, hasAudioActivity: hasAudioActivity)
    }

    /// Finalize chunked recording and get complete transcription
    private func finalizeChunkedTranscription() async {
        print("[FluidAudioSpeechRecognition] Finalizing chunked transcription...")

        // Get final transcription and metrics from chunked recording manager
        let (finalText, metrics) = await chunkedRecordingManager.finalize()

        // Log metrics for debugging
        await MetricsLogger.shared.log(metrics)

        let trimmedText = finalText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedText.isEmpty {
            // Update UI with final transcription
            transcription = trimmedText

            print("[FluidAudioSpeechRecognition] ✅ Transcription complete (\(trimmedText.count) chars, \(metrics.chunkCount) chunks, \(String(format: "%.1f", metrics.totalDuration))s)")
        } else {
            print("[FluidAudioSpeechRecognition] ⚠️ Transcription returned empty text")
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
            print("[FluidAudioSpeechRecognition] Silence detection disabled (timeout: \(timeoutInterval)s)")
            return
        }

        guard hasDetectedSpeechInCurrentSession else {
            print("[FluidAudioSpeechRecognition] Silence timer armed (starts after first speech)")
            return
        }

        silenceDetectionTimer?.invalidate()
        print("[FluidAudioSpeechRecognition] Starting silence detection timer with timeout: \(timeoutInterval)s")

        silenceDetectionTimer = Timer.scheduledTimer(withTimeInterval: timeoutInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, isRecording else { return }

                print("[FluidAudioSpeechRecognition] ⏱️ Silence timeout reached after \(timeoutInterval)s, stopping recording")
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
            print("[FluidAudioSpeechRecognition] Silence detection disabled (timeout: \(timeoutInterval)s)")
            return
        }
        silenceDetectionTimer = Timer.scheduledTimer(withTimeInterval: timeoutInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, isRecording else { return }

                print("[FluidAudioSpeechRecognition] ⏱️ Silence detected for \(timeoutInterval)s, stopping recording")
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
    /// SAFETY: nonisolated(unsafe) to allow use from audio render thread
    /// with explicit locking where needed.
    private nonisolated(unsafe) var tapCount = 0

    /// Track pending audio processing tasks to ensure all audio is processed before finalization
    private let pendingTasksLock = NSLock()
    private nonisolated(unsafe) var pendingTaskCount: Int = 0

    /// Signal when all pending tasks have completed
    private nonisolated(unsafe) var allTasksCompletedContinuation: CheckedContinuation<Void, Never>?

    init?(owner: FluidAudioSpeechRecognition, inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            print("[FluidAudioTapProxy] Failed to create audio converter from \(inputFormat.sampleRate)Hz to \(outputFormat.sampleRate)Hz")
            return nil
        }
        self.owner = owner
        self.outputFormat = outputFormat
        self.converter = converter

        print("[FluidAudioTapProxy] Initialized - converting \(inputFormat.sampleRate)Hz to \(outputFormat.sampleRate)Hz")
    }

    /// Wait for all pending audio processing tasks to complete
    /// Call this before finalizing transcription to ensure no audio is lost
    func waitForPendingTasks() async {
        let count = pendingTasksLock.withLock { pendingTaskCount }
        if count == 0 {
            print("[FluidAudioTapProxy] No pending tasks to wait for")
            return
        }

        print("[FluidAudioTapProxy] Waiting for \(count) pending audio processing tasks...")

        await withCheckedContinuation { continuation in
            pendingTasksLock.withLock {
                if pendingTaskCount == 0 {
                    continuation.resume()
                } else {
                    allTasksCompletedContinuation = continuation
                }
            }
        }

        print("[FluidAudioTapProxy] All pending tasks completed")
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
                continuation.resume()
            }
        }
    }

    nonisolated func handleTap(buffer: AVAudioPCMBuffer, time _: AVAudioTime) {
        tapCount += 1

        // Log every tap for debugging microphone issues
        if tapCount <= 10 || tapCount % 10 == 0 { // Log first 10 taps, then every 10th
            print("[FluidAudioTapProxy] Tap #\(tapCount): buffer frameLength=\(buffer.frameLength), format=\(buffer.format)")
        }

        // Convert to 16kHz mono
        let frameCapacity = UInt32(Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate)
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            print("[FluidAudioTapProxy] Failed to create converted buffer")
            return
        }

        var error: NSError?
        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            if tapCount % 10 == 0 { // Log occasionally to avoid spam
                print("[FluidAudioTapProxy] Conversion error: \(error)")
            }
            return
        }

        // Extract samples
        guard let channelData = convertedBuffer.floatChannelData,
              convertedBuffer.frameLength > 0
        else {
            if tapCount <= 10 {
                print("[FluidAudioTapProxy] No channel data or zero frame length")
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
            print("[FluidAudioTapProxy] Tap #\(tapCount): \(samples.count) samples, max amplitude: \(maxAmplitude), RMS: \(rms)")
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
