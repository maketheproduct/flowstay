@testable import FlowstayCore
import XCTest

final class ClaudeCodeRewriteParsingTests: XCTestCase {
    func testReadsStructuredOutputFromCLIEnvelope() {
        // Shape returned by `claude -p … --output-format json --json-schema …`
        let envelope: [String: Any] = [
            "type": "result",
            "subtype": "success",
            "result": #"{"rewritten_text":"Good day."}"#,
            "structured_output": ["rewritten_text": "Good day."],
        ]

        XCTAssertEqual(ClaudeCodeProvider.rewrittenText(in: envelope), "Good day.")
    }

    func testFallsBackToJSONEncodedResult() {
        let envelope: [String: Any] = ["result": #"{"rewritten_text":"Hello."}"#]

        XCTAssertEqual(ClaudeCodeProvider.rewrittenText(in: envelope), "Hello.")
    }

    func testRejectsEnvelopeWithoutRewrite() {
        let envelope: [String: Any] = ["result": "Not logged in · Please run /login"]

        XCTAssertNil(ClaudeCodeProvider.rewrittenText(in: envelope))
    }
}
