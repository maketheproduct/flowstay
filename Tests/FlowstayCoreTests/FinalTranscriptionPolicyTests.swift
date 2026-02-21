@testable import FlowstayCore
import XCTest

@MainActor
final class FinalTranscriptionPolicyTests: XCTestCase {
    func testClassifiesTrimmedEmptyAsNoSpeech() {
        XCTAssertEqual(FinalTranscriptionPolicy.classify("   \n\t  "), .noSpeech)
    }

    func testClassifiesNonEmptyTextAsTranscriptWithTrimmedPayload() {
        XCTAssertEqual(
            FinalTranscriptionPolicy.classify("  hello world  "),
            .transcript("hello world")
        )
    }
}
