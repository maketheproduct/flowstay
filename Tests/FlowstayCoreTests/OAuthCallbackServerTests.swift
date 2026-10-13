@testable import FlowstayCore
import Network
import XCTest

final class OAuthCallbackServerTests: XCTestCase {
    func testStartsOnSystemAssignedPort() async throws {
        let server = LocalCallbackServer()
        defer { server.stop() }

        let port = try await server.start { _, _ in }

        XCTAssertGreaterThan(port, 0)
    }

    func testBusyPortFailsFastWithAddressInUse() async throws {
        let occupier = LocalCallbackServer()
        defer { occupier.stop() }
        let busyPort = try await occupier.start { _, _ in }

        let server = LocalCallbackServer()
        defer { server.stop() }
        let startedAt = Date()
        do {
            _ = try await server.start(preferredPort: busyPort) { _, _ in }
            XCTFail("Expected the busy port to be rejected")
        } catch let error as NWError {
            XCTAssertEqual(error, .posix(.EADDRINUSE))
        }
        // The fallback ports are tried next, so this must not wait out the 3s startup timeout.
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.0)
    }
}
