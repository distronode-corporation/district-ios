import CryptoKit
@testable import DistrictAI
import Intents
import XCTest

/// Keys in memory: the test bundle is unsigned and has no Keychain.
final class MemoryRecentsKeys: ListenInRecentsKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var current: SymmetricKey?
    let available: Bool

    init(available: Bool = true) {
        self.available = available
    }

    func key() -> SymmetricKey? {
        guard available else { return nil }
        return lock.withLock {
            if let current {
                return current
            }
            let made = SymmetricKey(size: .bits256)
            current = made
            return made
        }
    }

    func rotate() {
        lock.withLock { current = nil }
    }
}

/// A listen-in tapped in the system's Recents reopens its call (Sean, 2026-11-05): the Live
/// screen while the call is live, its call log entry once it has ended; nothing for a handle this
/// device never listened under; and no number stored on the device.
@MainActor
final class ListenInRecentsTests: XCTestCase {
    private var suite = ""
    private var defaults = UserDefaults.standard
    private let keys = MemoryRecentsKeys()

    private func makeRecents(now: @escaping () -> Date = Date.init) -> ListenInRecents {
        ListenInRecents(defaults: defaults, keys: keys, now: now)
    }

    override func setUp() {
        super.setUp()
        suite = "test.listen-in-recents.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite) ?? .standard
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testARecordedHandleFindsItsCall() {
        let recents = makeRecents()
        recents.record(handle: "+15555550100", workspaceId: "ws_1", callId: "cmh1live")

        XCTAssertEqual(recents.entry(forHandle: " +15555550100 ")?.callId, "cmh1live", "the handle is trimmed")
        XCTAssertEqual(recents.entry(forHandle: "+15555550100")?.workspaceId, "ws_1")
        XCTAssertNil(recents.entry(forHandle: "+15555550199"), "a keypad call's handle does nothing")
    }

    /// ⛔ NO NUMBER ON THE DEVICE, AND NO PLAIN HASH OF ONE: an HMAC under a per-install key
    /// (xhigh review of PR #101, item 7).
    func testTheMapHoldsAnHMACNeverTheNumberOrItsHash() throws {
        let recents = makeRecents()
        recents.record(handle: "+15555550100", workspaceId: "ws_1", callId: "cmh1live")
        let blob = try XCTUnwrap(defaults.data(forKey: ListenInRecents.defaultsKey))
        let text = try XCTUnwrap(String(bytes: blob, encoding: .utf8))
        let plainHash = SHA256.hash(data: Data("15555550100".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertFalse(text.contains("5555550100"))
        XCTAssertFalse(text.contains(plainHash))
        XCTAssertTrue(try text.contains(XCTUnwrap(recents.key("+15555550100"))))
    }

    /// ⛔ CLEARING ROTATES THE KEY: an old map restored on disk finds nothing.
    func testClearingRotatesTheKey() throws {
        let recents = makeRecents()
        recents.record(handle: "+15555550100", workspaceId: "ws_1", callId: "cmh1live")
        let blob = try XCTUnwrap(defaults.data(forKey: ListenInRecents.defaultsKey))
        recents.clear()
        defaults.set(blob, forKey: ListenInRecents.defaultsKey)
        XCTAssertNil(recents.entry(forHandle: "+15555550100"))
    }

    /// ⚠️ NO KEYCHAIN, NO MEMORY: nothing is recorded and nothing is found.
    func testWithoutAKeyNothingIsKept() {
        let recents = ListenInRecents(defaults: defaults, keys: MemoryRecentsKeys(available: false))
        recents.record(handle: "+15555550100", workspaceId: "ws_1", callId: "cmh1live")
        XCTAssertNil(defaults.data(forKey: ListenInRecents.defaultsKey))
        XCTAssertNil(recents.entry(forHandle: "+15555550100"))
    }

    /// The same number however the system wrote it back (xhigh review, item 8).
    func testTheHandleIsNormalised() {
        XCTAssertEqual(ListenInRecents.normalized("+1 (416) 555-0177"), "14165550177")
        XCTAssertEqual(ListenInRecents.normalized("(416) 555-0177"), "14165550177")
        XCTAssertEqual(ListenInRecents.normalized("+442079460018"), "442079460018")
        XCTAssertEqual(ListenInRecents.normalized("  Maya Chen "), "maya chen")
        let recents = makeRecents()
        recents.record(handle: "+14165550177", workspaceId: "ws_1", callId: "cmh1live")
        XCTAssertEqual(recents.entry(forHandle: "(416) 555-0177")?.callId, "cmh1live")
    }

    /// ⚠️ A TAP CAUGHT BEFORE THE SHELL EXISTS WAITS, AND IS TAKEN ONCE (a cold launch).
    func testAPendingTapIsTakenOnce() {
        let recents = makeRecents()
        recents.pending = "+15555550100"
        XCTAssertEqual(recents.takePending(), "+15555550100")
        XCTAssertNil(recents.takePending())
    }

    func testOnlyTheNewestAreKept() {
        var clock = Date(timeIntervalSince1970: 1_790_000_000)
        let recents = makeRecents { clock }
        for index in 0 ... ListenInRecents.limit {
            clock = clock.addingTimeInterval(1)
            recents.record(handle: "+1555555\(1000 + index)", workspaceId: "ws_1", callId: "cmh\(index)")
        }
        XCTAssertNil(recents.entry(forHandle: "+15555551000"), "the oldest goes")
        XCTAssertEqual(recents.entry(forHandle: "+1555555\(1000 + ListenInRecents.limit)")?.callId, "cmh20")
    }

    /// ⛔ SIGN-OUT FORGETS THEM, and any tap still waiting.
    func testClearForgetsEverything() {
        let recents = makeRecents()
        recents.record(handle: "+15555550100", workspaceId: "ws_1", callId: "cmh1live")
        recents.pending = "+15555550100"
        recents.clear()
        XCTAssertNil(recents.entry(forHandle: "+15555550100"))
        XCTAssertNil(recents.pending)
    }

    func testTheHandleComesFromTheIntentsFirstContact() {
        func intent(_ value: String?) -> INStartCallIntent {
            let person = INPerson(
                personHandle: INPersonHandle(value: value, type: .phoneNumber),
                nameComponents: nil,
                displayName: nil,
                image: nil,
                contactIdentifier: nil,
                customIdentifier: nil
            )
            return INStartCallIntent(
                callRecordFilter: nil,
                callRecordToCallBack: nil,
                audioRoute: .unknown,
                destinationType: .normal,
                contacts: [person],
                callCapability: .audioCall
            )
        }
        XCTAssertEqual(ListenInRecents.handle(of: intent(" +15555550100 ")), "+15555550100")
        XCTAssertNil(ListenInRecents.handle(of: intent("  ")))
        XCTAssertNil(ListenInRecents.handle(of: intent(nil)))
    }

    /// ⛔ LIVE: ITS LIVE SCREEN. ENDED: ITS CALL LOG ENTRY.
    func testALiveCallReopensLiveAndAnEndedOneItsCallLogEntry() throws {
        let live = try LiveFixtures.call(id: "cmh1live", status: "in-progress")
        let ended = try LiveFixtures.call(id: "cmh1live", status: "completed")
        XCTAssertEqual(
            ListenInRecents.route(for: live, workspaceId: "ws_1", role: .agency),
            .superviseCall(workspaceId: "ws_1", role: .agency, callId: "cmh1live")
        )
        XCTAssertEqual(
            ListenInRecents.route(for: ended, workspaceId: "ws_1", role: .agency),
            .callDetail(workspaceId: "ws_1", callId: "cmh1live")
        )
    }
}
