import FluidAudio
import Foundation

/// Manages chunked audio recording for memory-efficient, unlimited-length transcription
///
/// This actor handles:
/// - Accumulating audio samples into bounded chunks (~3 min each)
/// - Detecting natural chunk boundaries at silence points
/// - Maintaining overlap between chunks for accurate ASR at boundaries
/// - Background transcription of completed chunks while recording continues
/// - Deduplicating overlapping text when stitching chunk results
public actor ChunkedRecordingManager {
    // MARK: - Configuration

    /// Target chunk duration before looking for a silence boundary
    private let targetChunkDuration: TimeInterval = 180 // 3 minutes

    /// Maximum chunk duration - force boundary regardless of silence
    private let maxChunkDuration: TimeInterval = 300 // 5 minutes

    /// Minimum chunk duration before allowing silence-based boundary
    private let minChunkDuration: TimeInterval = 30 // 30 seconds

    /// Audio overlap between chunks to ensure accurate word boundaries
    private let overlapDuration: TimeInterval = 5 // 5 seconds

    /// Silence duration that triggers chunk boundary (when duration > minChunkDuration)
    private let silenceThresholdForChunk: TimeInterval = 0.5 // 500ms

    /// Sample rate (must match FluidAudio expectation)
    private let sampleRate: Double = 16000

    /// Placeholder text for failed chunk transcriptions
    private let failedChunkPlaceholder = "[transcription chunk failed - please file an issue on GitHub if this persists]"

    // MARK: - State

    /// Current chunk's audio buffer
    private var currentChunkBuffer: [Float] = []

    /// When the current chunk started
    private var currentChunkStartTime: Date?

    /// Last time we detected audio activity (non-silence)
    private var lastAudioActivityTime: Date?

    /// Completed chunks with their transcription results
    private var completedChunks: [ChunkResult] = []

    /// Audio overlap from previous chunk (prepended to next chunk)
    private var overlapBuffer: [Float] = []

    /// Currently running transcription task
    private var pendingTranscription: Task<Void, Never>?

    /// Reference to ASR manager for transcription
    /// SAFETY: nonisolated(unsafe) because AsrManager doesn't conform to Sendable.
    /// Thread safety is guaranteed by actor isolation - all access to this property
    /// happens within ChunkedRecordingManager actor's serialized execution context.
    private nonisolated(unsafe) weak var asrManager: AsrManager?

    /// Metrics for this recording session
    private var chunkDurations: [TimeInterval] = []
    private var transcriptionTimes: [TimeInterval] = []
    private var errorMessages: [String] = []

    /// Recording start time for total duration calculation
    private var recordingStartTime: Date?

    // MARK: - Types

    /// Result of transcribing a single chunk
    private struct ChunkResult {
        let index: Int
        let text: String
        let hadError: Bool
    }

    // MARK: - Initialization

    public init() {}

    /// Configure the manager with an ASR manager reference
    public func configure(asrManager: AsrManager?) {
        self.asrManager = asrManager
    }

    // MARK: - Public Interface

    /// Start a new recording session
    public func startRecording() {
        reset()
        recordingStartTime = Date()
        currentChunkStartTime = Date()
        lastAudioActivityTime = Date()
        print("[ChunkedRecordingManager] Started new recording session")
    }

    /// Append audio samples from the microphone
    /// - Parameters:
    ///   - samples: Audio samples at 16kHz mono
    ///   - hasAudioActivity: Whether these samples contain speech (RMS > threshold)
    public func appendSamples(_ samples: [Float], hasAudioActivity: Bool) async {
        currentChunkBuffer.append(contentsOf: samples)

        if hasAudioActivity {
            lastAudioActivityTime = Date()
        }

        // Check if we should finalize the current chunk
        if shouldFinalizeChunk() {
            await finalizeCurrentChunk()
        }
    }

    /// Force a chunk boundary (used when recording stops)
    public func forceChunkBoundary() async {
        if !currentChunkBuffer.isEmpty {
            await finalizeCurrentChunk()
        }
    }

    /// Finalize recording and get the complete transcription
    /// - Returns: The full transcription text from all chunks
    public func finalize() async -> (text: String, metrics: RecordingMetrics) {
        print("[ChunkedRecordingManager] Finalizing recording...")

        // Process any remaining audio in the current chunk
        if !currentChunkBuffer.isEmpty {
            await finalizeCurrentChunk()
        }

        // Wait for any pending transcription to complete
        if let pending = pendingTranscription {
            print("[ChunkedRecordingManager] Waiting for pending transcription...")
            await pending.value
        }

        // Calculate total duration
        let totalDuration: TimeInterval = if let start = recordingStartTime {
            Date().timeIntervalSince(start)
        } else {
            chunkDurations.reduce(0, +)
        }

        // Stitch all chunk results together
        let allTexts = completedChunks.sorted { $0.index < $1.index }.map(\.text)
        let finalText = deduplicateBoundaries(allTexts)

        // Create metrics
        let metrics = RecordingMetrics(
            totalDuration: totalDuration,
            chunkCount: completedChunks.count,
            chunkDurations: chunkDurations,
            transcriptionTimes: transcriptionTimes,
            finalTextLength: finalText.count,
            hadErrors: completedChunks.contains { $0.hadError },
            errorMessages: errorMessages
        )

        print("[ChunkedRecordingManager] Finalized: \(completedChunks.count) chunks, \(finalText.count) chars")

        return (finalText, metrics)
    }

    /// Reset all state for a new recording
    public func reset() {
        currentChunkBuffer.removeAll()
        currentChunkBuffer.reserveCapacity(0) // Release memory
        currentChunkStartTime = nil
        lastAudioActivityTime = nil
        completedChunks.removeAll()
        overlapBuffer.removeAll()
        overlapBuffer.reserveCapacity(0)
        pendingTranscription?.cancel()
        pendingTranscription = nil
        chunkDurations.removeAll()
        transcriptionTimes.removeAll()
        errorMessages.removeAll()
        recordingStartTime = nil
        print("[ChunkedRecordingManager] Reset complete")
    }

    /// Get current buffer size in samples
    public func getCurrentBufferSize() -> Int {
        currentChunkBuffer.count
    }

    /// Get current chunk duration in seconds
    public func getCurrentChunkDuration() -> TimeInterval {
        guard let start = currentChunkStartTime else { return 0 }
        return Date().timeIntervalSince(start)
    }

    // MARK: - Internal Logic

    /// Determine if the current chunk should be finalized
    private func shouldFinalizeChunk() -> Bool {
        guard let startTime = currentChunkStartTime else { return false }

        let chunkDuration = Date().timeIntervalSince(startTime)

        // Hard limit: always finalize at max duration
        if chunkDuration >= maxChunkDuration {
            print("[ChunkedRecordingManager] Chunk hit max duration (\(Int(maxChunkDuration))s), finalizing")
            return true
        }

        // Don't finalize if chunk is too short
        if chunkDuration < minChunkDuration {
            return false
        }

        // Check for silence-based boundary after target duration
        if chunkDuration >= targetChunkDuration {
            if let lastActivity = lastAudioActivityTime {
                let silenceDuration = Date().timeIntervalSince(lastActivity)
                if silenceDuration >= silenceThresholdForChunk {
                    print("[ChunkedRecordingManager] Natural silence boundary detected after \(String(format: "%.1f", chunkDuration))s")
                    return true
                }
            }
        }

        return false
    }

    /// Finalize the current chunk and start background transcription
    private func finalizeCurrentChunk() async {
        let chunkIndex = completedChunks.count
        let chunkDuration = getCurrentChunkDuration()

        print("[ChunkedRecordingManager] Finalizing chunk \(chunkIndex) (\(String(format: "%.1f", chunkDuration))s, \(currentChunkBuffer.count) samples)")

        // Prepare samples for transcription
        var samplesToTranscribe: [Float] = []

        // Prepend overlap from previous chunk (if any)
        if !overlapBuffer.isEmpty {
            samplesToTranscribe.append(contentsOf: overlapBuffer)
            print("[ChunkedRecordingManager] Prepended \(overlapBuffer.count) overlap samples")
        }

        // Add current chunk's audio
        samplesToTranscribe.append(contentsOf: currentChunkBuffer)

        // Save overlap for next chunk (last N seconds)
        let overlapSamples = Int(overlapDuration * sampleRate)
        if currentChunkBuffer.count > overlapSamples {
            overlapBuffer = Array(currentChunkBuffer.suffix(overlapSamples))
        } else {
            overlapBuffer = currentChunkBuffer
        }

        // Record chunk duration
        chunkDurations.append(chunkDuration)

        // Clear current buffer and reset for next chunk
        currentChunkBuffer.removeAll()
        currentChunkBuffer.reserveCapacity(0) // Release memory immediately
        currentChunkStartTime = Date()

        // Wait for any previous transcription to complete
        if let pending = pendingTranscription {
            await pending.value
        }

        // Start background transcription
        let transcriptionStart = Date()
        pendingTranscription = Task { [weak self, samplesToTranscribe, chunkIndex] in
            guard let self else { return }

            let result = await transcribeChunk(samplesToTranscribe, chunkIndex: chunkIndex)

            let transcriptionTime = Date().timeIntervalSince(transcriptionStart)
            await recordChunkResult(result, transcriptionTime: transcriptionTime)
        }
    }

    /// Transcribe a single chunk's audio
    private func transcribeChunk(_ samples: [Float], chunkIndex: Int) async -> ChunkResult {
        guard let manager = asrManager else {
            let error = "ASR manager not available for chunk \(chunkIndex)"
            print("[ChunkedRecordingManager] ❌ \(error)")
            return ChunkResult(
                index: chunkIndex,
                text: failedChunkPlaceholder,
                hadError: true
            )
        }

        // Try transcription with one retry
        for attempt in 1 ... 2 {
            do {
                let result = try await manager.transcribe(samples, source: .system)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

                print("[ChunkedRecordingManager] ✅ Chunk \(chunkIndex) transcribed (\(text.count) chars)")

                return ChunkResult(
                    index: chunkIndex,
                    text: text,
                    hadError: false
                )
            } catch {
                print("[ChunkedRecordingManager] ⚠️ Chunk \(chunkIndex) transcription attempt \(attempt) failed: \(error)")

                if attempt < 2 {
                    // Retry after brief delay
                    try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                }
            }
        }

        // Both attempts failed
        let error = "Chunk \(chunkIndex) transcription failed after 2 attempts"
        print("[ChunkedRecordingManager] ❌ \(error)")

        return ChunkResult(
            index: chunkIndex,
            text: failedChunkPlaceholder,
            hadError: true
        )
    }

    /// Record a completed chunk's result
    private func recordChunkResult(_ result: ChunkResult, transcriptionTime: TimeInterval) {
        completedChunks.append(result)
        transcriptionTimes.append(transcriptionTime)

        if result.hadError {
            errorMessages.append("Chunk \(result.index) failed")
        }
    }

    /// Deduplicate overlapping text at chunk boundaries
    ///
    /// When chunks are processed with overlapping audio, the same words may appear
    /// at the end of one chunk and the beginning of the next. This method finds
    /// and removes these duplicates.
    private func deduplicateBoundaries(_ chunks: [String]) -> String {
        guard chunks.count > 1 else {
            return chunks.first ?? ""
        }

        var result = chunks[0]

        for i in 1 ..< chunks.count {
            let nextChunk = chunks[i]

            // Skip empty chunks or placeholder chunks
            if nextChunk.isEmpty || nextChunk == failedChunkPlaceholder {
                if nextChunk == failedChunkPlaceholder {
                    result += " " + nextChunk
                }
                continue
            }

            // Find overlap between end of result and start of nextChunk
            let overlap = findOverlap(result, nextChunk)

            if let overlap, overlap.count > 0 {
                // Remove duplicate words from the start of nextChunk
                let words = nextChunk.split(separator: " ").map(String.init)
                let remainingWords = Array(words.dropFirst(overlap.count))

                if !remainingWords.isEmpty {
                    result += " " + remainingWords.joined(separator: " ")
                }

                print("[ChunkedRecordingManager] Deduplicated \(overlap.count) words at boundary")
            } else {
                // No overlap found, just concatenate with space
                result += " " + nextChunk
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Find overlapping words between the end of one text and the start of another
    /// - Returns: The overlapping words from the end of text1, or nil if no significant overlap
    private func findOverlap(_ text1: String, _ text2: String) -> [String]? {
        let words1 = text1.split(separator: " ").map { String($0).lowercased() }
        let words2 = text2.split(separator: " ").map { String($0).lowercased() }

        // Look for overlap in the last 15 words of text1 and first 15 words of text2
        let searchWindow = 15
        let endWords = Array(words1.suffix(searchWindow))
        let startWords = Array(words2.prefix(searchWindow))

        // Find longest common sequence at boundary
        var bestOverlap: [String]? = nil
        var bestLength = 0

        // Try different overlap lengths (minimum 2 words to avoid false positives)
        for overlapLength in (2 ... min(endWords.count, startWords.count)).reversed() {
            let endSlice = Array(endWords.suffix(overlapLength))
            let startSlice = Array(startWords.prefix(overlapLength))

            // Check if sequences match (case-insensitive)
            if endSlice == startSlice {
                if overlapLength > bestLength {
                    bestLength = overlapLength
                    bestOverlap = startSlice
                }
                break // Found longest match
            }
        }

        return bestOverlap
    }
}
