@testable import DistrictAI
import Foundation
import XCTest

/// The call Live Activity started by the server's push-to-start (3.2, iOS 18): adopted, its
/// update token registered, and never doubled by the app's own start.
@MainActor
final class CallLiveActivityPushStartTests: XCTestCase {
    private var host: FakeActivityHost!
    private var registrar: FakeRegistrar!

    override func setUp() async throws {
        host = FakeActivityHost()
        registrar = FakeRegistrar()
    }

    private func make() -> CallLiveActivities {
        CallLiveActivities(host: host, registrar: registrar, now: { Date(timeIntervalSince1970: 1_793_000_000) })
    }

    /// ⛔ A PUSH-STARTED ACTIVITY IS ADOPTED: its update token goes to the server, and the
    /// app's own ring start then starts nothing.
    func testAPushStartedActivityIsAdoptedAndTheRingStartsNoSecond() async {
        let activities = make()
        activities.adoptRunning()
        let pushed = FakeActivity(workspaceId: "ws_1", callId: "call_1", state: .init(phase: .ringing, startedAt: "x"))
        host.announce(pushed)
        pushed.send(Data([0x5A]))

        activities.rang(workspaceId: "ws_1", callId: "call_1")
        activities.named(callId: "call_1", callerName: "Marie")

        XCTAssertEqual(host.started.count, 0)
        XCTAssertEqual(pushed.state.callerName, "Marie", "the app drives the adopted one")
        await waitUntil { self.registrar.calls.count == 1 }
        XCTAssertEqual(registrar.calls.first, .init(workspaceId: "ws_1", callId: "call_1", token: "5a"))
    }

    /// ⛔ A PUSH-START THAT ActivityKit RUNS BUT HAS NOT ANNOUNCED YET STILL COUNTS: the ring's
    /// start looks at what is running.
    func testARunningPushStartedActivityNotYetAnnouncedStopsALocalStart() {
        let activities = make()
        activities.adoptRunning()
        let pushed = FakeActivity(workspaceId: "ws_1", callId: "call_1", state: .init(phase: .ringing, startedAt: "x"))
        host.alreadyRunning = [pushed]

        activities.rang(workspaceId: "ws_1", callId: "call_1")

        XCTAssertEqual(host.started.count, 0)
        XCTAssertEqual(activities.callIds, ["call_1"])
    }

    /// ⛔ NEVER TWO FOR ONE CALL: a push-start landing after the app's own start is ended at
    /// once, and the app's own start reported back is the same activity.
    func testAPushStartAfterALocalStartIsEndedAtOnce() throws {
        let activities = make()
        activities.rang(workspaceId: "ws_1", callId: "call_1")
        let local = try XCTUnwrap(host.started.first)
        host.announce(local)
        let pushed = FakeActivity(workspaceId: "ws_1", callId: "call_1", state: .init(phase: .ringing, startedAt: "x"))
        host.announce(pushed)

        XCTAssertNil(local.ending)
        XCTAssertEqual(pushed.ending, .immediate)
        activities.named(callId: "call_1", callerName: "Marie")
        XCTAssertEqual(local.state.callerName, "Marie")
    }

    func testAnotherCallsPushStartIsAdoptedBesideIt() {
        let activities = make()
        activities.rang(workspaceId: "ws_1", callId: "call_1")
        host.announce(FakeActivity(
            workspaceId: "ws_1",
            callId: "call_2",
            state: .init(phase: .ringing, startedAt: "x")
        ))
        XCTAssertEqual(activities.callIds, ["call_1", "call_2"])
    }
}
