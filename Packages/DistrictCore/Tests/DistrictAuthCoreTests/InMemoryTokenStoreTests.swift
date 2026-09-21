@testable import DistrictAuthCore
import Foundation
import XCTest

/// ``InMemoryTokenStore`` ships in `Sources/` so DistrictNetwork and
/// DistrictData can build a coordinator in their own suites, which makes it
/// production-visible code and therefore code the floors measure. It is also
/// the reference the Keychain implementation in `App/` has to behave like, so
/// its contract is pinned here rather than left implied.
final class InMemoryTokenStoreTests: XCTestCase {
    func testStartsEmptyAndRoundTripsASession() async throws {
        let store = InMemoryTokenStore()
        let read = try await store.read()
        XCTAssertNil(read)

        let session = AuthFixtures.session()
        try await store.write(session)
        let stored = try await store.read()
        XCTAssertEqual(stored, session)
    }

    func testAcceptsASeededSession() async throws {
        let session = AuthFixtures.session(refreshToken: "seeded")
        let store = InMemoryTokenStore(session: session)
        let stored = try await store.read()
        XCTAssertEqual(stored?.refreshToken, "seeded")
    }

    func testWriteReplacesRatherThanAccumulates() async throws {
        let store = InMemoryTokenStore(session: AuthFixtures.session(refreshToken: "old"))
        try await store.write(AuthFixtures.session(refreshToken: "new"))
        let stored = try await store.read()
        XCTAssertEqual(stored?.refreshToken, "new")
    }

    func testMarkerRoundTripsIndependentlyOfTheSession() async throws {
        let store = InMemoryTokenStore(session: AuthFixtures.session())
        let empty = try await store.pendingRefreshToken()
        XCTAssertNil(empty)

        try await store.markRefreshPending("refresh-1")
        let marked = try await store.pendingRefreshToken()
        XCTAssertEqual(marked, "refresh-1")

        try await store.clearRefreshPending()
        let cleared = try await store.pendingRefreshToken()
        XCTAssertNil(cleared)
        let survived = try await store.read()
        XCTAssertNotNil(survived, "clearing the marker must not touch the session")
    }

    func testClearForgetsBothTheSessionAndTheMarker() async throws {
        let store = InMemoryTokenStore(session: AuthFixtures.session())
        try await store.markRefreshPending("refresh-1")
        try await store.clear()

        let session = try await store.read()
        let marker = try await store.pendingRefreshToken()
        XCTAssertNil(session)
        XCTAssertNil(marker)
    }
}
