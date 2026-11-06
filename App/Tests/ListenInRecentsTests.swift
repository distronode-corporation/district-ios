@testable import DistrictAI
import Intents
import XCTest

/// A listen-in tapped in the system's Recents reopens its call (Sean, 2026-11-05): the Live
/// screen while the call is live, its call log entry once it has ended; nothing for a handle this
/// device never listened under; and no number stored on the device.
@MainActor
final class ListenInRecentsTests: XCTestCase {
    private var suite = ""
    private var defaults = UserDefaults.standard

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
        let recents = ListenInRecents(defaults: defaults)
        recents.record(handle: "+15555550100", workspaceId: "ws_1", callId: "cmh1live")

        XCTAssertEqual(recents.entry(forHandle: " +15555550100 ")?.callId, "cmh1live", "the handle is trimmed")
        XCTAssertEqual(recents.entry(forHandle: "+15555550100")?.workspaceId, "ws_1")
        XCTAssertNil(recents.entry(forHandle: "+15555550199"), "a keypad call's handle does nothing")
    }

    /// ⛔ NO NUMBER ON THE DEVICE: only its SHA-256.
    func testNoNumberIsStored() throws {
        let recents = ListenInRecents(defaults: defaults)
        recents.record(handle: "+15555550100", workspaceId: "ws_1", callId: "cmh1live")
        let blob = try XCTUnwrap(defaults.data(forKey: ListenInRecents.defaultsKey))
        let text = try XCTUnwrap(String(bytes: blob, encoding: .utf8))
        XCTAssertFalse(text.contains("5555550100"))
        XCTAssertTrue(text.contains(ListenInRecents.key("+15555550100")))
    }

    func testOnlyTheNewestAreKept() {
        var clock = Date(timeIntervalSince1970: 1_790_000_000)
        let recents = ListenInRecents(defaults: defaults) { clock }
        for index in 0 ... ListenInRecents.limit {
            clock = clock.addingTimeInterval(1)
            recents.record(handle: "+1555555\(1000 + index)", workspaceId: "ws_1", callId: "cmh\(index)")
        }
        XCTAssertNil(recents.entry(forHandle: "+15555551000"), "the oldest goes")
        XCTAssertEqual(recents.entry(forHandle: "+1555555\(1000 + ListenInRecents.limit)")?.callId, "cmh20")
    }

    /// ⛔ SIGN-OUT FORGETS THEM, and any tap still waiting.
    func testClearForgetsEverything() {
        let recents = ListenInRecents(defaults: defaults)
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
