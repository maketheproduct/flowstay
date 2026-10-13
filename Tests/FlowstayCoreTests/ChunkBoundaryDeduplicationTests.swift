@testable import FlowstayCore
import FluidAudio
import XCTest

final class ChunkBoundaryDeduplicationTests: XCTestCase {
    func testShortOrEmptyChunksDoNotCrash() async {
        let manager = ChunkedRecordingManager()

        let emptyFirst = await manager.deduplicateBoundaries(["", "hello there"])
        let oneWordLast = await manager.deduplicateBoundaries(["we should ship it", "Thanks."])

        XCTAssertEqual(emptyFirst, "hello there")
        XCTAssertEqual(oneWordLast, "we should ship it Thanks.")
    }

    func testOverlapMatchesAcrossPunctuationAndCase() async {
        let manager = ChunkedRecordingManager()

        let text = await manager.deduplicateBoundaries([
            "let's review the agenda for the meeting.",
            "For the meeting we need three slides",
        ])

        XCTAssertEqual(text, "let's review the agenda for the meeting. we need three slides")
    }

    func testLongOverlapWithSlightlyDifferentSeamIsRemoved() async {
        let manager = ChunkedRecordingManager()

        // Real output from two chunks sharing 5s of audio (from the local ASR E2E run).
        let text = await manager.deduplicateBoundaries([
            "The quick brown fox jumps over the lazy dog, we are testing the flow stay release today, and",
            "Quick brown fox jumps over the lazy dog, we are testing the flow stay released today, and it should transcribe this sentence.",
        ])

        XCTAssertEqual(
            text,
            "The quick brown fox jumps over the lazy dog, we are testing the flow stay release today, and it should transcribe this sentence."
        )
    }

    func testUnrelatedChunksAreConcatenated() async {
        let manager = ChunkedRecordingManager()

        let text = await manager.deduplicateBoundaries(["first part of the note", "completely different second part"])

        XCTAssertEqual(text, "first part of the note completely different second part")
    }

    func testTimedOverlapKeepsRepeatedSentences() async {
        let manager = ChunkedRecordingManager()

        // Repetitive speech fools text-only matching; the token timings say the first
        // six words of the second chunk were in the shared audio.
        let text = await manager.deduplicateBoundaries(
            [
                "Marker one. The weather says rain. Marker two. The weather says rain.",
                "Marker two. The weather says rain. Marker three. The weather says rain.",
            ],
            overlapWordCounts: [nil, 6]
        )

        XCTAssertEqual(
            text,
            "Marker one. The weather says rain. Marker two. The weather says rain. Marker three. The weather says rain."
        )
    }

    func testWordsStartedBeforeOverlapCountsWordInitialTokens() async {
        let manager = ChunkedRecordingManager()
        let timings = [
            TokenTiming(token: " The", tokenId: 1, startTime: 0.0, endTime: 0.1, confidence: 1),
            TokenTiming(token: " qu", tokenId: 2, startTime: 0.1, endTime: 0.2, confidence: 1),
            TokenTiming(token: "ick", tokenId: 3, startTime: 0.2, endTime: 0.3, confidence: 1),
            TokenTiming(token: ".", tokenId: 4, startTime: 0.3, endTime: 0.4, confidence: 1),
            TokenTiming(token: " Next", tokenId: 5, startTime: 5.2, endTime: 5.3, confidence: 1),
        ]

        let count = await manager.wordsStarted(before: 5.0, in: timings)
        let missing = await manager.wordsStarted(before: 5.0, in: nil)

        XCTAssertEqual(count, 2)
        XCTAssertNil(missing)
    }
}
