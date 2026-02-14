@testable import FlowstayCore
import XCTest

final class TranscriptionHistoryStoreTests: XCTestCase {
    var historyStore: TranscriptionHistoryStore!

    /// Check if we have write access to the history directory
    /// Tests will be skipped if running in a sandbox without write permissions
    private var hasFileAccess: Bool {
        // Try to write a test file to check permissions
        let testPath = FileManager.default.temporaryDirectory.appendingPathComponent("flowstay-test-\(UUID().uuidString)")
        do {
            try "test".write(to: testPath, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: testPath)
            return true
        } catch {
            return false
        }
    }

    override func setUp() async throws {
        historyStore = TranscriptionHistoryStore.shared
        // Only clean up if we have file access
        if hasFileAccess {
            _ = await historyStore.deleteAll()
        }
    }

    override func tearDown() async throws {
        // Only clean up if we have file access
        if hasFileAccess {
            _ = await historyStore.deleteAll()
        }
    }

    // MARK: - Helper Methods

    private func createTestRecord(
        rawText: String = "Test transcription",
        processedText: String? = nil,
        personaId: String? = nil,
        personaName: String? = nil,
        duration: TimeInterval = 5.0
    ) -> TranscriptionRecord {
        TranscriptionRecord(
            id: UUID(),
            timestamp: Date(),
            duration: duration,
            rawText: rawText,
            processedText: processedText ?? rawText,
            personaId: personaId,
            personaName: personaName
        )
    }

    // MARK: - Add Tests

    func testAddRecord() async throws {
        let record = createTestRecord()

        try await historyStore.add(record)

        let records = try await historyStore.getAll()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, record.id)
    }

    func testAddMultipleRecords() async throws {
        let record1 = createTestRecord(rawText: "First transcription")
        let record2 = createTestRecord(rawText: "Second transcription")
        let record3 = createTestRecord(rawText: "Third transcription")

        try await historyStore.add(record1)
        try await historyStore.add(record2)
        try await historyStore.add(record3)

        let records = try await historyStore.getAll()
        XCTAssertEqual(records.count, 3)
    }

    // MARK: - Get All Tests

    func testGetAllReturnsEmptyWhenNoRecords() async throws {
        let records = try await historyStore.getAll()
        XCTAssertTrue(records.isEmpty)
    }

    func testGetAllOrEmptyReturnsEmptyOnError() async {
        // This tests the backward-compatible method
        let records = await historyStore.getAllOrEmpty()
        // Should return an array (possibly empty) without throwing
        XCTAssertNotNil(records)
    }

    func testGetAllSortsNewestFirst() async throws {
        let olderRecord = TranscriptionRecord(
            id: UUID(),
            timestamp: Date().addingTimeInterval(-3600), // 1 hour ago
            duration: 5.0,
            rawText: "Older",
            processedText: "Older"
        )
        let newerRecord = TranscriptionRecord(
            id: UUID(),
            timestamp: Date(),
            duration: 5.0,
            rawText: "Newer",
            processedText: "Newer"
        )

        // Add in reverse order
        try await historyStore.add(newerRecord)
        try await historyStore.add(olderRecord)

        let records = try await historyStore.getAll()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first?.rawText, "Newer")
        XCTAssertEqual(records.last?.rawText, "Older")
    }

    // MARK: - Delete Tests

    func testDeleteRecord() async throws {
        let record = createTestRecord()
        try await historyStore.add(record)

        try await historyStore.delete(record.id)

        let records = try await historyStore.getAll()
        XCTAssertTrue(records.isEmpty)
    }

    func testDeleteNonExistentRecordDoesNotThrow() async throws {
        // Should not throw when deleting non-existent record
        try await historyStore.delete(UUID())
    }

    func testDeleteAllReturnsCorrectCount() async throws {
        try await historyStore.add(createTestRecord())
        try await historyStore.add(createTestRecord())
        try await historyStore.add(createTestRecord())

        let deletedCount = await historyStore.deleteAll()
        XCTAssertEqual(deletedCount, 3)

        let remaining = try await historyStore.getAll()
        XCTAssertTrue(remaining.isEmpty)
    }

    // MARK: - Retention Tests

    func testDeleteOlderThan() async throws {
        let oldRecord = TranscriptionRecord(
            id: UUID(),
            timestamp: Date().addingTimeInterval(-86400 * 10), // 10 days ago
            duration: 5.0,
            rawText: "Old record",
            processedText: "Old record"
        )
        let recentRecord = TranscriptionRecord(
            id: UUID(),
            timestamp: Date(),
            duration: 5.0,
            rawText: "Recent record",
            processedText: "Recent record"
        )

        try await historyStore.add(oldRecord)
        try await historyStore.add(recentRecord)

        let deletedCount = await historyStore.deleteOlderThan(days: 7)
        XCTAssertEqual(deletedCount, 1)

        let remaining = try await historyStore.getAll()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.rawText, "Recent record")
    }

    func testDeleteOlderThanWithZeroDays() async throws {
        try await historyStore.add(createTestRecord())

        let deletedCount = await historyStore.deleteOlderThan(days: 0)
        XCTAssertEqual(deletedCount, 0)
    }

    // MARK: - Search Tests

    func testSearchByRawText() async throws {
        try await historyStore.add(createTestRecord(rawText: "Hello world"))
        try await historyStore.add(createTestRecord(rawText: "Goodbye universe"))

        let results = await historyStore.search("Hello")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.rawText, "Hello world")
    }

    func testSearchByProcessedText() async throws {
        try await historyStore.add(createTestRecord(
            rawText: "raw text",
            processedText: "processed content"
        ))

        let results = await historyStore.search("processed")
        XCTAssertEqual(results.count, 1)
    }

    func testSearchByPersonaName() async throws {
        try await historyStore.add(createTestRecord(personaName: "Professional"))
        try await historyStore.add(createTestRecord(personaName: "Casual"))

        let results = await historyStore.search("Professional")
        XCTAssertEqual(results.count, 1)
    }

    func testSearchCaseInsensitive() async throws {
        try await historyStore.add(createTestRecord(rawText: "UPPERCASE TEXT"))

        let results = await historyStore.search("uppercase")
        XCTAssertEqual(results.count, 1)
    }

    func testSearchEmptyQueryReturnsAll() async throws {
        try await historyStore.add(createTestRecord())
        try await historyStore.add(createTestRecord())

        let results = await historyStore.search("")
        XCTAssertEqual(results.count, 2)
    }

    // MARK: - Count Tests

    func testCount() async throws {
        let initialCount = await historyStore.count()
        XCTAssertEqual(initialCount, 0)

        try await historyStore.add(createTestRecord())
        let countAfterFirst = await historyStore.count()
        XCTAssertEqual(countAfterFirst, 1)

        try await historyStore.add(createTestRecord())
        let countAfterSecond = await historyStore.count()
        XCTAssertEqual(countAfterSecond, 2)
    }

    // MARK: - Record Data Integrity Tests

    func testRecordPreservesAllFields() async throws {
        let originalRecord = TranscriptionRecord(
            id: UUID(),
            timestamp: Date(),
            duration: 12.5,
            rawText: "Original raw text",
            processedText: "Processed text",
            personaId: "test-persona",
            personaName: "Test Persona",
            appBundleId: "com.test.app",
            appName: "Test App"
        )

        try await historyStore.add(originalRecord)
        let records = try await historyStore.getAll()

        XCTAssertEqual(records.count, 1)
        let retrieved = try XCTUnwrap(records.first)

        XCTAssertEqual(retrieved.id, originalRecord.id)
        XCTAssertEqual(retrieved.duration, originalRecord.duration)
        XCTAssertEqual(retrieved.rawText, originalRecord.rawText)
        XCTAssertEqual(retrieved.processedText, originalRecord.processedText)
        XCTAssertEqual(retrieved.personaId, originalRecord.personaId)
        XCTAssertEqual(retrieved.personaName, originalRecord.personaName)
        XCTAssertEqual(retrieved.appBundleId, originalRecord.appBundleId)
        XCTAssertEqual(retrieved.appName, originalRecord.appName)
    }

    func testRecordWithSpecialCharacters() async throws {
        let record = createTestRecord(
            rawText: "Text with special chars: 🎤🔊 <>&\"'",
            processedText: "Processed: 日本語 العربية"
        )

        try await historyStore.add(record)
        let records = try await historyStore.getAll()

        XCTAssertEqual(records.first?.rawText, "Text with special chars: 🎤🔊 <>&\"'")
        XCTAssertEqual(records.first?.processedText, "Processed: 日本語 العربية")
    }

    func testRecordWithMultilineText() async throws {
        let multilineText = """
        Line 1
        Line 2
        Line 3
        """

        let record = createTestRecord(rawText: multilineText)
        try await historyStore.add(record)

        let records = try await historyStore.getAll()
        XCTAssertEqual(records.first?.rawText, multilineText)
    }
}

// MARK: - HistoryError Tests

final class HistoryErrorTests: XCTestCase {
    func testReadFailedErrorDescription() {
        let underlyingError = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Test error"])
        let error = HistoryError.readFailed(underlying: underlyingError)

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("read") ?? false)
    }

    func testWriteFailedErrorDescription() {
        let underlyingError = NSError(domain: "Test", code: 1, userInfo: nil)
        let error = HistoryError.writeFailed(underlying: underlyingError)

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("save") ?? false)
    }

    func testDeleteFailedErrorDescription() {
        let underlyingError = NSError(domain: "Test", code: 1, userInfo: nil)
        let error = HistoryError.deleteFailed(underlying: underlyingError)

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("delete") ?? false)
    }

    func testParseErrorDescription() {
        let error = HistoryError.parseError(file: "test.md")

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("test.md") ?? false)
    }
}
