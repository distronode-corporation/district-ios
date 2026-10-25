@testable import DistrictAI
import DistrictModel
import Foundation
import XCTest

/// When the app mints the notification service extension's token, and what it keeps (3.2, W4).
@MainActor
final class NotifyTokenRenewalTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let day: TimeInterval = 24 * 60 * 60

    func testAMissingTokenIsMintedAndStoredWithTheServersExpiry() async {
        let store = MemoryTokens(nil)
        let mint = MintRoute(.success(Self.minted("2026-11-23T00:00:00.000Z")))
        let renewal = NotifyTokenRenewal(mint: mint.mint, store: store, now: { self.now })

        await renewal.renewIfNeeded()?.value

        XCTAssertEqual(mint.count, 1)
        XCTAssertEqual(store.stored?.token, "contract-notify-read-jwt")
        XCTAssertEqual(store.stored?.expiresAt, WireInstant.parse("2026-11-23T00:00:00.000Z"))
    }

    /// The contract's rule: missing, expired or within seven days of expiry mints; anything
    /// further out does not.
    func testOnlyATokenNearItsExpiryIsRenewed() async {
        // Time left before expiry, and how many mints it takes.
        let cases: [(left: TimeInterval, mints: Int)] = [
            (30 * Self.day, 0),
            (8 * Self.day, 0),
            (7 * Self.day, 1),
            (3600, 1),
            (-3600, 1),
        ]
        for (left, mints) in cases {
            let store = MemoryTokens(NotifyToken(token: "old-jws", expiresAt: now.addingTimeInterval(left)))
            let mint = MintRoute(.success(Self.minted("2026-11-23T00:00:00.000Z")))
            let renewal = NotifyTokenRenewal(mint: mint.mint, store: store, now: { self.now })
            await renewal.renewIfNeeded()?.value
            XCTAssertEqual(mint.count, mints, "\(left) s left")
        }
    }

    /// ⚠️ NOTHING IS MINTED WHERE NOTHING CAN BE KEPT: an unsigned build, or a Keychain that
    /// cannot answer before the first unlock.
    func testNothingIsMintedWhenTheTokenCannotBeKept() {
        for store in [MemoryTokens(nil, canStore: false), MemoryTokens(nil, readFails: true)] {
            let mint = MintRoute(.success(Self.minted("2026-11-23T00:00:00.000Z")))
            let renewal = NotifyTokenRenewal(mint: mint.mint, store: store, now: { self.now })
            XCTAssertNil(renewal.renewIfNeeded())
            XCTAssertEqual(mint.count, 0)
        }
    }

    /// A refused mint or an expiry this build cannot read keeps what was stored, and the next
    /// ask mints again.
    func testAFailedMintStoresNothingAndTheNextAskTriesAgain() async {
        let answers: [Result<NotifyTokenResponse, ApiError>] = [
            .failure(.http(status: 401, message: nil)),
            .failure(.transport("offline")),
            .success(Self.minted("next tuesday")),
        ]
        for answer in answers {
            let store = MemoryTokens(nil)
            let mint = MintRoute(answer)
            let renewal = NotifyTokenRenewal(mint: mint.mint, store: store, now: { self.now })
            await renewal.renewIfNeeded()?.value
            XCTAssertNil(store.stored, "\(answer)")
            XCTAssertEqual(store.writes, 0, "\(answer)")
            await renewal.renewIfNeeded()?.value
            XCTAssertEqual(mint.count, 2, "\(answer)")
        }
    }

    /// ⛔ ONE MINT AT A TIME: the signed-in appearance can recur while one is on the wire.
    func testASecondAskJoinsTheMintInFlight() async {
        let store = MemoryTokens(nil)
        let mint = MintRoute(.success(Self.minted("2026-11-23T00:00:00.000Z")), held: true)
        let renewal = NotifyTokenRenewal(mint: mint.mint, store: store, now: { self.now })

        let first = renewal.renewIfNeeded()
        let second = renewal.renewIfNeeded()
        XCTAssertNotNil(first)
        await mint.waitUntilAsked()
        mint.release()
        await first?.value
        await second?.value

        XCTAssertEqual(mint.count, 1)
        XCTAssertEqual(store.writes, 1)
    }

    /// ⛔ A SIGN-OUT CLEARS THE TOKEN, AND A MINT STILL ON THE WIRE WRITES NOTHING BACK: it names
    /// the family that just ended.
    func testASignOutClearsTheTokenAndDropsTheMintInFlight() async {
        let store = MemoryTokens(nil)
        let mint = MintRoute(.success(Self.minted("2026-11-23T00:00:00.000Z")), held: true)
        let renewal = NotifyTokenRenewal(mint: mint.mint, store: store, now: { self.now })

        let inFlight = renewal.renewIfNeeded()
        await mint.waitUntilAsked()
        renewal.forget()
        mint.release()
        await inFlight?.value

        XCTAssertNil(store.stored)
        XCTAssertEqual(store.writes, 0)
        XCTAssertEqual(store.clears, 1)
    }

    private static func minted(_ expiresAt: String) -> NotifyTokenResponse {
        NotifyTokenResponse(success: true, token: "contract-notify-read-jwt", expiresAt: expiresAt)
    }
}

/// Counts mints and answers one canned result, optionally held until released.
private final class MintRoute: @unchecked Sendable {
    private let lock = NSLock()
    private let answer: Result<NotifyTokenResponse, ApiError>
    private let held: Bool
    private var asked = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false

    init(_ answer: Result<NotifyTokenResponse, ApiError>, held: Bool = false) {
        self.answer = answer
        self.held = held
    }

    var count: Int {
        lock.withLock { asked }
    }

    var mint: NotifyTokenRenewal.Mint {
        { [self] in
            lock.withLock { asked += 1 }
            if held {
                await withCheckedContinuation { continuation in
                    let open = lock.withLock { () -> Bool in
                        if released {
                            return true
                        }
                        gate = continuation
                        return false
                    }
                    if open {
                        continuation.resume()
                    }
                }
            }
            return answer
        }
    }

    func waitUntilAsked() async {
        while count == 0 {
            await Task.yield()
        }
    }

    func release() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { gate = nil }
            return gate
        }
        waiting?.resume()
    }
}
