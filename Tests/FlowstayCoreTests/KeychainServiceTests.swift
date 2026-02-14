@testable import FlowstayCore
import XCTest

final class KeychainServiceTests: XCTestCase {
    // Use a unique test provider name to avoid conflicts with real data
    private let testProvider = "test-provider-\(UUID().uuidString.prefix(8))"
    private var keychainService: KeychainService!

    override func setUp() async throws {
        keychainService = KeychainService.shared
        // Clean up any existing test data
        await keychainService.deleteAPIKey(for: testProvider)
    }

    override func tearDown() async throws {
        // Clean up test data
        await keychainService.deleteAPIKey(for: testProvider)
    }

    // MARK: - Save and Retrieve Tests

    func testSaveAndRetrieveAPIKey() async {
        let testKey = "test-api-key-12345"

        await keychainService.saveAPIKey(testKey, for: testProvider)

        let retrieved = await keychainService.getAPIKey(for: testProvider)
        XCTAssertEqual(retrieved, testKey)
    }

    func testRetrieveNonExistentKey() async {
        let retrieved = await keychainService.getAPIKey(for: "non-existent-provider-xyz")
        XCTAssertNil(retrieved)
    }

    func testHasAPIKeyWhenKeyExists() async {
        await keychainService.saveAPIKey("test-key", for: testProvider)

        let hasKey = await keychainService.hasAPIKey(for: testProvider)
        XCTAssertTrue(hasKey)
    }

    func testHasAPIKeyWhenKeyDoesNotExist() async {
        let hasKey = await keychainService.hasAPIKey(for: "non-existent-provider-xyz")
        XCTAssertFalse(hasKey)
    }

    // MARK: - Delete Tests

    func testDeleteAPIKey() async {
        // First save a key
        await keychainService.saveAPIKey("test-key", for: testProvider)
        let existsBefore = await keychainService.hasAPIKey(for: testProvider)
        XCTAssertTrue(existsBefore)

        // Delete it
        await keychainService.deleteAPIKey(for: testProvider)

        // Verify it's gone
        let existsAfter = await keychainService.hasAPIKey(for: testProvider)
        XCTAssertFalse(existsAfter)
    }

    func testDeleteNonExistentKeyDoesNotThrow() async {
        // This should not throw or crash
        await keychainService.deleteAPIKey(for: "non-existent-provider-xyz")
    }

    // MARK: - Overwrite Tests

    func testOverwriteExistingKey() async {
        let originalKey = "original-key"
        let newKey = "new-key"

        await keychainService.saveAPIKey(originalKey, for: testProvider)
        await keychainService.saveAPIKey(newKey, for: testProvider)

        let retrieved = await keychainService.getAPIKey(for: testProvider)
        XCTAssertEqual(retrieved, newKey)
    }

    // MARK: - Edge Cases

    func testSaveEmptyKey() async {
        await keychainService.saveAPIKey("", for: testProvider)

        let retrieved = await keychainService.getAPIKey(for: testProvider)
        XCTAssertEqual(retrieved, "")
    }

    func testSaveSpecialCharacterKey() async {
        let specialKey = "sk-🔑-test!@#$%^&*()_+-=[]{}|;':\",./<>?"

        await keychainService.saveAPIKey(specialKey, for: testProvider)

        let retrieved = await keychainService.getAPIKey(for: testProvider)
        XCTAssertEqual(retrieved, specialKey)
    }

    func testSaveVeryLongKey() async {
        let longKey = String(repeating: "a", count: 10000)

        await keychainService.saveAPIKey(longKey, for: testProvider)

        let retrieved = await keychainService.getAPIKey(for: testProvider)
        XCTAssertEqual(retrieved, longKey)
    }

    // MARK: - Concurrent Access Tests

    func testConcurrentSaveAndRetrieve() async {
        let iterations = 50
        let provider = testProvider

        // Perform concurrent saves
        await withTaskGroup(of: Void.self) { group in
            for i in 0 ..< iterations {
                let keychainService = self.keychainService!
                group.addTask { @Sendable in
                    await keychainService.saveAPIKey("key-\(i)", for: provider)
                }
            }
        }

        // Should have some value (the last one that won the race)
        let result = await keychainService.getAPIKey(for: testProvider)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.hasPrefix("key-") ?? false)
    }
}

// MARK: - Mock Keychain Service for Unit Tests

/// A mock implementation of KeychainServiceProtocol for unit testing
/// This allows testing components that depend on KeychainService without touching the real Keychain
public final class MockKeychainService: KeychainServiceProtocol, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func saveAPIKey(_ key: String, for provider: String) async {
        lock.withLock {
            storage[provider] = key
        }
    }

    public func getAPIKey(for provider: String) async -> String? {
        lock.withLock {
            storage[provider]
        }
    }

    public func deleteAPIKey(for provider: String) async {
        lock.withLock {
            storage[provider] = nil
        }
    }

    public func hasAPIKey(for provider: String) async -> Bool {
        lock.withLock {
            storage[provider] != nil
        }
    }

    /// Clear all stored keys (useful for test setup)
    public func clearAll() {
        lock.withLock {
            storage.removeAll()
        }
    }
}

// MARK: - Mock Keychain Service Tests

final class MockKeychainServiceTests: XCTestCase {
    var mockService: MockKeychainService!

    override func setUp() {
        mockService = MockKeychainService()
    }

    func testMockSaveAndRetrieve() async {
        await mockService.saveAPIKey("test-key", for: "test-provider")
        let retrieved = await mockService.getAPIKey(for: "test-provider")
        XCTAssertEqual(retrieved, "test-key")
    }

    func testMockDelete() async {
        await mockService.saveAPIKey("test-key", for: "test-provider")
        await mockService.deleteAPIKey(for: "test-provider")
        let retrieved = await mockService.getAPIKey(for: "test-provider")
        XCTAssertNil(retrieved)
    }

    func testMockClearAll() async {
        await mockService.saveAPIKey("key1", for: "provider1")
        await mockService.saveAPIKey("key2", for: "provider2")

        mockService.clearAll()

        let key1 = await mockService.getAPIKey(for: "provider1")
        let key2 = await mockService.getAPIKey(for: "provider2")
        XCTAssertNil(key1)
        XCTAssertNil(key2)
    }
}
