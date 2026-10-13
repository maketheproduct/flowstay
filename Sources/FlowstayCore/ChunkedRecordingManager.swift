@preconcurrency import FluidAudio
import Foundation
import os

/// Thrown when a transcription attempt exceeds the allowed timeout
private struct TranscriptionTimeoutError: Error {}

/// Wrapper to pass non-Sendable AsrManager across isolation boundaries.
/// SAFETY: Access is serialized by the enclosing ChunkedRecordingManager actor — only
/// one detached task touches the manager at a time.
private final class UnsafeAsrManagerBox: @unchecked Sendable {
    nonisolated(unsafe) let manager: AsrManager
    nonisolated init(_ manager: AsrManager) {
        self.manager = manager
    }
}

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

    private let logger = Logger(subsystem: "com.flowstay.app", category: "ChunkedRecordingManager")

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
    /// Bumped on every reset so transcriptions still running for a previous
    /// recording cannot append their text to the next one.
    private var sessionGeneration = 0

    /// Reference to ASR manager for transcription
    /// SAFETY: nonisolated(unsafe) because AsrManager doesn't conform to Sendable.
    /// The reference is only read from actor-isolated methods and is never shared
    /// directly with detached work except through `UnsafeAsrManagerBox` in
    /// `transcribeWithTimeout`, which preserves the single-request-at-a-time invariant.
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
        var timing: ChunkTiming?
    }

    /// When each word of a chunk's text was spoken, from the ASR token timings.
    struct ChunkTiming {
        /// Start of each word of the chunk text, in seconds into the chunk audio.
        let wordStartTimes: [TimeInterval]
        let audioDuration: TimeInterval
        /// Audio at the start of the chunk shared with the end of the previous chunk.
        let overlapSeconds: TimeInterval
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
        // Process any remaining audio in the current chunk
        if !currentChunkBuffer.isEmpty {
            await finalizeCurrentChunk()
        }

        // Wait for any pending transcription to complete (with 35s timeout)
        if let pending = pendingTranscription {
            let completed = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    await pending.value
                    return true
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 35_000_000_000)
                    return false
                }
                let first = await group.next()!
                group.cancelAll()
                return first
            }
            if !completed {
                logger.warning("[ChunkedRecordingManager] Pending transcription timed out after 35s, continuing with available results")
                pending.cancel()
            }
        }

        // Calculate total duration
        let totalDuration: TimeInterval = if let start = recordingStartTime {
            Date().timeIntervalSince(start)
        } else {
            chunkDurations.reduce(0, +)
        }

        // Stitch all chunk results together
        let orderedChunks = completedChunks.sorted { $0.index < $1.index }
        let finalText = deduplicateBoundaries(orderedChunks.map(\.text), timings: orderedChunks.map(\.timing))

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

        // swiftformat:disable:next redundantSelf
        logger.info("[ChunkedRecordingManager] Finalized: \(self.completedChunks.count, privacy: .public) chunks, \(finalText.count, privacy: .public) chars")

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
        sessionGeneration += 1
        chunkDurations.removeAll()
        transcriptionTimes.removeAll()
        errorMessages.removeAll()
        recordingStartTime = nil
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

        // Prepare samples for transcription
        var samplesToTranscribe: [Float] = []

        // Prepend overlap from previous chunk (if any)
        let overlapSeconds = Double(overlapBuffer.count) / sampleRate
        if !overlapBuffer.isEmpty {
            samplesToTranscribe.append(contentsOf: overlapBuffer)
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
        let generation = sessionGeneration
        pendingTranscription = Task { [weak self, samplesToTranscribe, chunkIndex] in
            guard let self else { return }

            let result = await transcribeChunk(samplesToTranscribe, chunkIndex: chunkIndex, overlapSeconds: overlapSeconds)

            let transcriptionTime = Date().timeIntervalSince(transcriptionStart)
            await recordChunkResult(result, transcriptionTime: transcriptionTime, generation: generation)
        }
    }

    /// Timeout for a single transcription attempt (seconds)
    private let transcriptionTimeout: UInt64 = 30_000_000_000 // 30 seconds

    /// Transcribe a single chunk's audio
    private func transcribeChunk(_ samples: [Float], chunkIndex: Int, overlapSeconds: TimeInterval) async -> ChunkResult {
        guard let manager = asrManager else {
            logger.error("[ChunkedRecordingManager] ASR manager not available for chunk \(chunkIndex, privacy: .public)")
            return ChunkResult(
                index: chunkIndex,
                text: failedChunkPlaceholder,
                hadError: true
            )
        }

        // Try transcription with one retry, each attempt with a 30s timeout
        for attempt in 1 ... 2 {
            do {
                let result = try await transcribeWithTimeout(
                    manager: manager,
                    samples: samples,
                    timeoutNanoseconds: transcriptionTimeout
                )
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

                return ChunkResult(
                    index: chunkIndex,
                    text: text,
                    hadError: false,
                    timing: wordStartTimes(in: result.tokenTimings).map {
                        ChunkTiming(
                            wordStartTimes: $0,
                            audioDuration: Double(samples.count) / sampleRate,
                            overlapSeconds: overlapSeconds
                        )
                    }
                )
            } catch is TranscriptionTimeoutError {
                logger.warning("[ChunkedRecordingManager] Chunk \(chunkIndex, privacy: .public) transcription attempt \(attempt, privacy: .public) timed out after 30s — not retrying (ASR may still be running)")
                break
            } catch {
                logger.warning("[ChunkedRecordingManager] Chunk \(chunkIndex, privacy: .public) transcription attempt \(attempt, privacy: .public) failed: \(error, privacy: .public)")
            }

            if attempt < 2 {
                // Retry after brief delay
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            }
        }

        // Both attempts failed
        logger.error("[ChunkedRecordingManager] Chunk \(chunkIndex, privacy: .public) transcription failed after 2 attempts")

        return ChunkResult(
            index: chunkIndex,
            text: failedChunkPlaceholder,
            hadError: true
        )
    }

    /// Run transcription with a timeout. Uses a continuation + detached tasks
    /// to race the transcription against a timeout watchdog.
    /// SAFETY: AsrManager is wrapped in UnsafeSendableBox; actual access is
    /// serialized by the detached task (only one touches it).
    private func transcribeWithTimeout(
        manager: AsrManager,
        samples: [Float],
        timeoutNanoseconds: UInt64
    ) async throws -> ASRResult {
        let box = UnsafeAsrManagerBox(manager)
        let finished = OSAllocatedUnfairLock(initialState: false)

        return try await withCheckedThrowingContinuation { continuation in
            // Transcription task
            let work = Task.detached {
                do {
                    // Chunks overlap and are deduplicated afterwards, so each one
                    // starts from a fresh decoder state (as FluidAudio 0.7 did).
                    var decoderState = TdtDecoderState.make()
                    let result = try await box.manager.transcribe(samples, decoderState: &decoderState)
                    let shouldResume = finished.withLock { done -> Bool in
                        guard !done else { return false }
                        done = true
                        return true
                    }
                    if shouldResume {
                        continuation.resume(returning: result)
                    }
                } catch {
                    let shouldResume = finished.withLock { done -> Bool in
                        guard !done else { return false }
                        done = true
                        return true
                    }
                    if shouldResume {
                        continuation.resume(throwing: error)
                    }
                }
            }

            // Timeout watchdog
            Task.detached {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                let shouldResume = finished.withLock { done -> Bool in
                    guard !done else { return false }
                    done = true
                    return true
                }
                if shouldResume {
                    work.cancel()
                    continuation.resume(throwing: TranscriptionTimeoutError())
                }
            }
        }
    }

    /// Record a completed chunk's result
    private func recordChunkResult(_ result: ChunkResult, transcriptionTime: TimeInterval, generation: Int) {
        guard generation == sessionGeneration else {
            logger.info("[ChunkedRecordingManager] Dropping chunk \(result.index, privacy: .public) result from a previous recording")
            return
        }
        completedChunks.append(result)
        transcriptionTimes.append(transcriptionTime)

        if result.hadError {
            errorMessages.append("Chunk \(result.index) failed")
        }
    }

    /// Deduplicate overlapping text at chunk boundaries
    ///
    /// Consecutive chunks share `overlapDuration` of audio, so the same words appear at the
    /// end of one chunk's text and the start of the next. A word cut off at the end of a
    /// chunk is often misheard there, so with timings on both sides the texts are joined in
    /// the middle of the shared audio, where each chunk has heard about 2.5s either side.
    func deduplicateBoundaries(_ chunks: [String], timings: [ChunkTiming?] = []) -> String {
        guard chunks.count > 1 else {
            return chunks.first ?? ""
        }

        func validTiming(_ index: Int) -> ChunkTiming? {
            guard index < timings.count, let timing = timings[index],
                  timing.wordStartTimes.count == chunks[index].split(separator: " ").count
            else { return nil }
            return timing
        }

        var words = chunks[0].split(separator: " ").map(String.init)
        // Timing of the chunk whose words end `words`, and start times of those words.
        var tailTiming = validTiming(0)
        var tailStartTimes = tailTiming?.wordStartTimes ?? []

        for i in 1 ..< chunks.count {
            let nextChunk = chunks[i]

            // Skip empty chunks or placeholder chunks
            if nextChunk.isEmpty || nextChunk == failedChunkPlaceholder {
                if nextChunk == failedChunkPlaceholder {
                    words.append(nextChunk)
                }
                // The next chunk overlaps this one, not the text before it.
                tailTiming = nil
                continue
            }

            let nextWords = nextChunk.split(separator: " ").map(String.init)
            let nextTiming = validTiming(i)

            if let previous = tailTiming, let next = nextTiming, next.overlapSeconds > 0 {
                let (dropFromPrevious, skipInNext) = midpointSplit(
                    previousStartTimes: tailStartTimes,
                    previousDuration: previous.audioDuration,
                    next: next
                )
                words.removeLast(min(dropFromPrevious, words.count))
                words.append(contentsOf: nextWords.dropFirst(skipInNext))
                tailStartTimes = Array(next.wordStartTimes.dropFirst(skipInNext))
                tailTiming = next
                continue
            }

            // Words from the shared audio: from the next chunk's timings when available,
            // otherwise from matching the end of the text so far against the start of nextChunk.
            let result = words.joined(separator: " ")
            let timedOverlap = nextTiming.map { timing in
                timing.wordStartTimes.count { $0 < timing.overlapSeconds }
            }
            let overlapCount = timedOverlap.map { refinedOverlapCount(result, nextChunk, expected: $0) }
                ?? findOverlap(result, nextChunk)?.count ?? 0
            words.append(contentsOf: nextWords.dropFirst(overlapCount))
            tailTiming = nextTiming
            tailStartTimes = Array(nextTiming?.wordStartTimes.dropFirst(overlapCount) ?? [])
        }

        return words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where to join two chunks: how many trailing words to drop from the previous chunk
    /// and how many leading words to skip in the next one.
    private func midpointSplit(
        previousStartTimes: [TimeInterval],
        previousDuration: TimeInterval,
        next: ChunkTiming
    ) -> (dropFromPrevious: Int, skipInNext: Int) {
        let midpoint = next.overlapSeconds / 2
        let skipInNext = next.wordStartTimes.firstIndex { $0 >= midpoint } ?? next.wordStartTimes.count
        // Same moment on the previous chunk's clock.
        let offset = previousDuration - next.overlapSeconds
        let splitTime = (skipInNext < next.wordStartTimes.count ? next.wordStartTimes[skipInNext] : midpoint) + offset

        // The previous chunk heard the first kept word too; cut just before its copy of it.
        let nearest = previousStartTimes.indices.min { abs(previousStartTimes[$0] - splitTime) < abs(previousStartTimes[$1] - splitTime) }
        let keepCount = if let nearest, abs(previousStartTimes[nearest] - splitTime) <= 0.3 {
            nearest
        } else {
            previousStartTimes.firstIndex { $0 >= splitTime } ?? previousStartTimes.count
        }
        return (previousStartTimes.count - keepCount, skipInNext)
    }

    /// Start time of each word in the transcript. SentencePiece word-initial tokens start
    /// with a space (a lone space token precedes digits).
    func wordStartTimes(in timings: [TokenTiming]?) -> [TimeInterval]? {
        guard let timings, !timings.isEmpty else { return nil }
        return timings.filter { $0.token.hasPrefix(" ") }.map(\.startTime)
    }

    /// Timing gives the overlap to within a word or two; settle the exact cut on the
    /// nearby length whose words best match the end of the previous text.
    private func refinedOverlapCount(_ text1: String, _ text2: String, expected: Int) -> Int {
        let words1 = text1.split(separator: " ").map(normalizedOverlapWord)
        let words2 = text2.split(separator: " ").map(normalizedOverlapWord)
        let candidates = max(0, expected - 2) ... min(words2.count, expected + 2)
        guard expected > 0, !candidates.isEmpty else { return min(max(expected, 0), words2.count) }

        var best = min(expected, words2.count)
        var bestScore = -1.0
        for length in candidates where length > 0 && length <= words1.count {
            let matches = zip(words1.suffix(length), words2.prefix(length)).count(where: { $0 == $1 })
            // Prefer the timed estimate when scores tie.
            let score = Double(matches) / Double(length) - (length == expected ? 0 : 0.01)
            if score > bestScore {
                best = length
                bestScore = score
            }
        }
        return best
    }

    /// Find overlapping words between the end of one text and the start of another.
    /// Chunks share 5s of audio (often more than 15 words), and the ASR can render the
    /// seam slightly differently in each chunk ("release" vs "released"), so the
    /// alignment tolerates a few mismatched words.
    /// - Returns: The overlapping words from the start of text2, or nil if no significant overlap
    private func findOverlap(_ text1: String, _ text2: String) -> [String]? {
        let words1 = text1.split(separator: " ").map(normalizedOverlapWord)
        let words2 = text2.split(separator: " ").map(normalizedOverlapWord)

        let searchWindow = 40
        let endWords = Array(words1.suffix(searchWindow))
        let startWords = Array(words2.prefix(searchWindow))
        let maximumLength = min(endWords.count, startWords.count)

        // Minimum 2 words to avoid false positives
        guard maximumLength >= 2 else {
            return nil
        }

        var bestLength = 0
        var bestMatches = 0
        for overlapLength in 2 ... maximumLength {
            let endSlice = endWords.suffix(overlapLength)
            let startSlice = startWords.prefix(overlapLength)
            let matches = zip(endSlice, startSlice).count(where: { $0 == $1 })
            let isMatch = overlapLength < 4
                ? matches == overlapLength
                : Double(matches) / Double(overlapLength) >= 0.75
            if isMatch, matches >= bestMatches {
                bestLength = overlapLength
                bestMatches = matches
            }
        }

        return bestLength > 0 ? Array(startWords.prefix(bestLength)) : nil
    }
}

/// Lowercased word with surrounding punctuation removed, so "meeting." and
/// "Meeting" match when deduplicating chunk overlaps.
private func normalizedOverlapWord(_ word: Substring) -> String {
    word.lowercased().trimmingCharacters(in: .punctuationCharacters)
}
