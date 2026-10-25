@testable import DistrictAIWatch
import Foundation
import XCTest

/// The unread complication's freshness (3.2): the watch app's background refresh asks the
/// phone for a snapshot with the EXISTING `.refresh` request, and only when it is worth a wake.
@MainActor
final class WatchBackgroundRefreshTests: XCTestCase {
    /// ⛔ STARTING SCHEDULES NOTHING: `start()` runs in the app's `init`, before the delegate
    /// that must handle the refresh is installed. The delegate starts the chain.
    func testStartingSchedulesNothingAndTheDelegatesCallDoes() {
        let rig = RefreshRig(reachable: false, unreadOnAFace: true)

        rig.store.start()
        XCTAssertEqual(rig.refresh.scheduled, 0)

        rig.store.scheduleBackgroundRefresh()
        XCTAssertEqual(rig.refresh.scheduled, 1)
    }

    /// The unread complication on a face and the phone in reach: the existing `.refresh`.
    func testABackgroundRefreshAsksThePhoneForASnapshot() async {
        let rig = RefreshRig(reachable: true, unreadOnAFace: true)

        await rig.store.refreshInBackground()

        XCTAssertEqual(rig.link.sent, [.refresh])
        XCTAssertEqual(rig.refresh.scheduled, 1)
    }

    /// ⛔ NO UNREAD COMPLICATION, NO PHONE WAKE: nothing else on the wrist needs one. The next
    /// refresh is still scheduled, so adding the complication later starts it.
    func testABackgroundRefreshWithoutTheUnreadComplicationSendsNothing() async {
        let rig = RefreshRig(reachable: true, unreadOnAFace: false)

        await rig.store.refreshInBackground()

        XCTAssertTrue(rig.link.sent.isEmpty)
        XCTAssertEqual(rig.refresh.scheduled, 1)
    }

    /// ⚠️ A PHONE OUT OF REACH IS NOT ASKED, AND THE CHAIN GOES ON.
    func testABackgroundRefreshWithThePhoneOutOfReachSendsNothing() async {
        let rig = RefreshRig(reachable: false, unreadOnAFace: true)

        await rig.store.refreshInBackground()

        XCTAssertTrue(rig.link.sent.isEmpty)
        XCTAssertEqual(rig.refresh.scheduled, 1)
    }

    /// ⛔ NO PROTOCOL BUMP: the request is the one every phone already answers.
    func testTheRefreshRequestKeepsTheProtocolVersion() {
        XCTAssertEqual(WatchRequest(action: .refresh).protocolVersion, WatchSnapshot.currentProtocolVersion)
        XCTAssertEqual(WatchSnapshot.currentProtocolVersion, 1)
    }

    func testTheIntervalIsFifteenMinutes() {
        XCTAssertEqual(WatchBackgroundRefresh.interval, 15 * 60)
    }
}

@MainActor
private final class RecordingLink: PhoneLinking {
    let isReachable: Bool
    private(set) var sent: [WatchAction] = []

    init(reachable: Bool) {
        isReachable = reachable
    }

    func activate(
        onReading _: @escaping @MainActor @Sendable (WatchSnapshotReading) -> Void,
        onReachable _: @escaping @MainActor @Sendable () -> Void
    ) {}

    func send(_ request: WatchRequest) async -> PhoneAnswer {
        sent.append(request.action)
        return .reply(.success)
    }
}

@MainActor
private final class CountingRefresh: BackgroundRefreshScheduling {
    let unreadOnAFace: Bool
    private(set) var scheduled = 0

    init(unreadOnAFace: Bool) {
        self.unreadOnAFace = unreadOnAFace
    }

    func scheduleNext() {
        scheduled += 1
    }

    func unreadComplicationIsOnAFace() async -> Bool {
        unreadOnAFace
    }
}

@MainActor
private final class NoPersistence: SnapshotPersisting {
    func load() -> Data? {
        nil
    }

    func save(_: Data) {}
}

@MainActor
private final class NoComplication: ComplicationPublishing {
    func publish(_: ComplicationState) {}
}

@MainActor
private struct RefreshRig {
    let link: RecordingLink
    let refresh: CountingRefresh
    let store: WatchStore

    init(reachable: Bool, unreadOnAFace: Bool) {
        link = RecordingLink(reachable: reachable)
        refresh = CountingRefresh(unreadOnAFace: unreadOnAFace)
        store = WatchStore(
            link: link,
            persistence: NoPersistence(),
            complication: NoComplication(),
            backgroundRefresh: refresh
        )
    }
}
