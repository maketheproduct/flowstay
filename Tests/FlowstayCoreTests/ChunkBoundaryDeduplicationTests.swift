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
            timings: [
                nil,
                .init(
                    wordStartTimes: [0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 5.5, 6.0, 6.5, 7.0, 7.5, 8.0],
                    audioDuration: 9,
                    overlapSeconds: 5
                ),
            ]
        )

        XCTAssertEqual(
            text,
            "Marker one. The weather says rain. Marker two. The weather says rain. Marker three. The weather says rain."
        )
    }

    func testJoinsMidOverlapWhenTheCutGarbledTheLastWord() async {
        let manager = ChunkedRecordingManager()

        // Real seam from a 5 minute recording: the first chunk ended mid "Marker forty-eight"
        // and heard "Marker 46.". Timings from the ASR; the chunks share 5s of audio.
        let previous = "Marker 46. The weather report says it will rain later today. "
            + "Marker 47. The weather report says it will rain later today. Marker 46."
        let previousTimes: [TimeInterval] = [
            180.3, 180.8, 181.6, 181.8, 182.1, 182.5, 182.7, 182.9, 183.1, 183.4, 183.7,
            184.40, 184.88, 185.76, 185.92, 186.24, 186.64, 186.88, 187.04, 187.20, 187.52, 187.84, 188.40, 188.88,
        ]
        let next = "Marker 47, the weather report says it will rain later today. "
            + "Marker 48, the weather report says it will rain later today."
        let nextTimes: [TimeInterval] = [
            0.40, 0.88, 1.76, 1.92, 2.24, 2.64, 2.88, 3.04, 3.20, 3.52, 3.84,
            4.40, 4.88, 5.60, 5.76, 6.08, 6.48, 6.72, 6.88, 7.04, 7.36, 7.68,
        ]

        let text = await manager.deduplicateBoundaries(
            [previous, next],
            timings: [
                .init(wordStartTimes: previousTimes, audioDuration: 189, overlapSeconds: 0),
                .init(wordStartTimes: nextTimes, audioDuration: 8.5, overlapSeconds: 5),
            ]
        )

        XCTAssertEqual(
            text,
            "Marker 46. The weather report says it will rain later today. "
                + "Marker 47. The weather report says it will rain later today. "
                + "Marker 48, the weather report says it will rain later today."
        )
    }

    func testWordStartTimesUseWordInitialTokens() async {
        let manager = ChunkedRecordingManager()
        let timings = [
            TokenTiming(token: " The", tokenId: 1, startTime: 0.0, endTime: 0.1, confidence: 1),
            TokenTiming(token: " qu", tokenId: 2, startTime: 0.1, endTime: 0.2, confidence: 1),
            TokenTiming(token: "ick", tokenId: 3, startTime: 0.2, endTime: 0.3, confidence: 1),
            TokenTiming(token: ".", tokenId: 4, startTime: 0.3, endTime: 0.4, confidence: 1),
            TokenTiming(token: " ", tokenId: 5, startTime: 4.9, endTime: 5.0, confidence: 1),
            TokenTiming(token: "4", tokenId: 6, startTime: 5.0, endTime: 5.1, confidence: 1),
            TokenTiming(token: "8", tokenId: 7, startTime: 5.1, endTime: 5.2, confidence: 1),
        ]

        let times = await manager.wordStartTimes(in: timings)
        let missing = await manager.wordStartTimes(in: nil)

        // "The quick. 48"
        XCTAssertEqual(times, [0.0, 0.1, 4.9])
        XCTAssertNil(missing)
    }
}
