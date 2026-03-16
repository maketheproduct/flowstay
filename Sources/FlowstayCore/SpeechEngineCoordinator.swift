import AppKit
import AVFoundation
import Combine
import os
import Speech
import SwiftUI

// MARK: - Speech Engine Coordinator

/// Coordinates speech recognition engine lifecycle and manages recording state
public class EngineCoordinatorViewModel: ObservableObject {
    private let logger = Logger(subsystem: "com.flowstay.app", category: "EngineCoordinator")

    public enum PrewarmBehavior {
        case modelsOnly
        case modelsAndAudio
    }

    @Published public var isRecording = false
    @Published public private(set) var isTransitioningRecordingState = false
    @Published public var currentTranscript = ""
    @Published public var audioLevel: Float = 0.0
    @Published public var waveformSamples: [Float] = []
    @Published public var engineError: String?
    @Published public var isModelsReady = false
    @Published public var downloadProgress: Double = 0.0

    // Only FluidAudio speech recognition
    private var fluidAudioSpeechRecognition: FluidAudioSpeechRecognition?
    private var cancellables = Set<AnyCancellable>()
    private weak var appState: AppState?
    private var modelPreparationTask: Task<Void, Never>?
    private var recordingPipelinePrewarmTask: Task<Bool, Never>?

    // Callbacks
    /// SAFETY: nonisolated(unsafe) because this callback is set once during initialization
    /// and only invoked from MainActor-isolated code. The @Sendable closure ensures
    /// the callback itself is safe to call from any context.
    public nonisolated(unsafe) var onTranscriptionComplete: (@Sendable (String, TimeInterval) -> Void)?
    private var stopCallback: (() async -> Void)?

    public init(appState: AppState? = nil) {
        self.appState = appState
        // Create FluidAudio instance synchronously to avoid race conditions
        // This ensures isModelDownloaded() can be called immediately
        fluidAudioSpeechRecognition = FluidAudioSpeechRecognition(appState: appState)

        // Set up subscriptions immediately (no artificial delay needed)
        setupSubscriptions()
    }

    private func setupSubscriptions() {
        // Clear any existing subscriptions
        cancellables.removeAll()

        // Observe audio level changes
        fluidAudioSpeechRecognition?.$audioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.audioLevel = level
            }
            .store(in: &cancellables)

        fluidAudioSpeechRecognition?.$waveformSamples
            .receive(on: DispatchQueue.main)
            .sink { [weak self] samples in
                self?.waveformSamples = samples
            }
            .store(in: &cancellables)

        // Observe transcription changes
        fluidAudioSpeechRecognition?.$transcription
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                self?.currentTranscript = text
            }
            .store(in: &cancellables)

        // Observe recording state changes
        fluidAudioSpeechRecognition?.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] recording in
                self?.isRecording = recording
            }
            .store(in: &cancellables)

        // Set up completion callback
        fluidAudioSpeechRecognition?.onTranscriptionComplete = { [weak self] finalText, duration in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onTranscriptionComplete?(finalText, duration)
            }
        }

        engineError = nil
    }

    /// Check if speech recognition models are downloaded (exist on disk)
    public func isModelDownloaded() -> Bool {
        fluidAudioSpeechRecognition?.areModelsCached() ?? false
    }

    /// Pre-initialize all models during app startup to avoid first-run delays.
    /// Uses fast-path loading if models are already cached, otherwise downloads.
    public func preInitializeAllModels(prewarmBehavior: PrewarmBehavior = .modelsAndAudio) async {
        if let modelPreparationTask {
            await modelPreparationTask.value
            if prewarmBehavior == .modelsAndAudio {
                _ = await prewarmRecordingPipelineIfNeeded()
            }
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await performModelPreparation(prewarmBehavior: prewarmBehavior)
        }
        modelPreparationTask = task
        await task.value
        modelPreparationTask = nil
    }

    private func performModelPreparation(prewarmBehavior: PrewarmBehavior) async {
        guard let fluidAudio = fluidAudioSpeechRecognition else {
            engineError = "Speech recognition engine not initialized"
            return
        }

        do {
            // Fast-path: Try loading cached models first (avoids download)
            do {
                try await fluidAudio.loadModelsIfAvailable()
                isModelsReady = fluidAudio.isModelsReady
                if isModelsReady, prewarmBehavior == .modelsAndAudio {
                    _ = await prewarmRecordingPipelineIfNeeded()
                }
                engineError = nil
                return
            } catch {
                // Cache load failed, falling back to download
            }

            // Fallback: Download and initialize if cache load failed
            try await fluidAudio.setupFluidAudio()
            isModelsReady = fluidAudio.isModelsReady
            if isModelsReady, prewarmBehavior == .modelsAndAudio {
                _ = await prewarmRecordingPipelineIfNeeded()
            }
            engineError = nil

            // Send notification when download completes (not for cache loads)
            let hasPermission = await NotificationManager.shared.checkPermissionStatus()
            if hasPermission {
                await MainActor.run {
                    NotificationManager.shared.sendNotification(
                        title: "Models Ready!",
                        body: "Speech recognition is ready to use",
                        identifier: "models-downloaded"
                    )
                }
            }
        } catch {
            engineError = "Model download failed: \(error.localizedDescription)"
            isModelsReady = false
        }
    }

    @discardableResult
    public func prewarmRecordingPipelineIfNeeded() async -> Bool {
        guard isModelsReady else {
            return false
        }

        if let recordingPipelinePrewarmTask {
            return await recordingPipelinePrewarmTask.value
        }

        let task = Task { [weak self] () -> Bool in
            guard let self, isModelsReady, let fluidAudio = fluidAudioSpeechRecognition else {
                return false
            }

            return await fluidAudio.prewarmRecordingPipeline()
        }
        recordingPipelinePrewarmTask = task
        let didPrewarm = await task.value
        recordingPipelinePrewarmTask = nil
        return didPrewarm
    }

    public func setCallbacks(
        onStartRecording: @escaping () async -> Void,
        onStopRecording: @escaping () async -> Void
    ) {
        _ = onStartRecording
        stopCallback = onStopRecording
    }

    public func startRecording() async throws {
        if isTransitioningRecordingState { return }
        if isRecording { return }

        isTransitioningRecordingState = true
        defer { isTransitioningRecordingState = false }

        guard let fluidAudioSpeechRecognition else {
            engineError = "FluidAudio speech recognition not initialized"
            throw NSError(domain: "EngineCoordinatorViewModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "FluidAudio speech recognition not initialized"])
        }

        // Check if models are ready before attempting to record
        if !fluidAudioSpeechRecognition.isModelsReady {
            engineError = "Please download the speech recognition model first"
            throw NSError(domain: "EngineCoordinatorViewModel", code: 2, userInfo: [NSLocalizedDescriptionKey: "Speech recognition models not downloaded. Please complete onboarding first."])
        }

        do {
            try await fluidAudioSpeechRecognition.startRecording()
            isRecording = fluidAudioSpeechRecognition.isRecording

            // Play start cue only after recording is actually active.
            if isRecording, appState?.soundFeedbackEnabled == true {
                SoundManager.shared.playStartRecording()
            }
        } catch {
            engineError = "Failed to start FluidAudio recognition: \(error.localizedDescription)"
            isRecording = false

            // Play error sound
            if appState?.soundFeedbackEnabled == true {
                SoundManager.shared.playError()
            }
            throw error
        }
    }

    /// Stop recording and finalize transcription
    /// Note: Audio finalization happens asynchronously - completion is signaled via onTranscriptionComplete callback
    public func stopRecording() async {
        if isTransitioningRecordingState { return }
        if !isRecording { return }

        isTransitioningRecordingState = true
        defer { isTransitioningRecordingState = false }

        if let fluidAudioSpeechRecognition {
            // stopRecording() initiates async cleanup - completion signaled via onTranscriptionComplete
            fluidAudioSpeechRecognition.stopRecording()
            isRecording = fluidAudioSpeechRecognition.isRecording

            // Play stop recording sound immediately for user feedback
            if appState?.soundFeedbackEnabled == true {
                SoundManager.shared.playStopRecording()
            }
        }

        await stopCallback?()
    }

    /// FluidAudio is the only engine, so no switching needed
    /// This method is kept for compatibility but does nothing
    public func switchEngine(to _: SpeechEngineType) async {}
}
