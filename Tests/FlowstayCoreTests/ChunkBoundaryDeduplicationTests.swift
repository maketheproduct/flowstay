@testable import FlowstayCore
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
}
