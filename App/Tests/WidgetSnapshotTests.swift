@testable import DistrictAI
import Security
import XCTest

/// The Home Screen widget's snapshot: what it holds, where it is stored, and when the app
/// writes and clears it. The widget drawing it is proved on a signed device only.
@MainActor
final class WidgetSnapshotTests: XCTestCase {
    private var store: MemoryStore!
    private let ticks = Box(0)
    private let time = Box(Date(timeIntervalSince1970: 1_800_000_000))

    private var reloads: Int {
        ticks.value
    }

    private var clock: Date {
        get { time.value }
        set { time.value = newValue }
    }

    override func setUp() {
        super.setUp()
        store = MemoryStore()
        ticks.value = 0
        WidgetSnapshotPublisher.store = store
        WidgetSnapshotPublisher.now = { [time] in time.value }
        WidgetSnapshotPublisher.reload = { [ticks] in ticks.value += 1 }
    }

    override func tearDown() {
        // A failed delete a test left pending is settled here, against the test's store.
        store.clearFails = false
        WidgetSnapshotPublisher.signedOut()
        WidgetSnapshotPublisher.store = WidgetSnapshotKeychain()
        WidgetSnapshotPublisher.now = { Date() }
        WidgetSnapshotPublisher.reload = {}
        super.tearDown()
    }

    func test_WID_01_theCountsFollowTheirReadsAndAWorkspaceSwitchDropsThem() {
        let session = WidgetSnapshotPublisher.session
        WidgetSnapshotPublisher.selected(workspaceId: "ws-north", name: "Northside Roofing", session: session)
        WidgetSnapshotPublisher.unread(4, workspaceId: "ws-north")
        clock += 60
        WidgetSnapshotPublisher.callsThisWeek(19, workspaceId: "ws-north")
        XCTAssertEqual(
            store.saved,
            WidgetSnapshot(
                workspaceId: "ws-north",
                workspaceName: "Northside Roofing",
                unreadMessages: 4,
                callsThisWeek: 19,
                callsReadAt: clock,
                updatedAt: clock
            )
        )
        // The same workspace again changes nothing and redraws nothing.
        let before = reloads
        WidgetSnapshotPublisher.selected(workspaceId: "ws-north", name: "Northside Roofing", session: session)
        XCTAssertEqual(reloads, before)
        // A rename keeps the counts: they are the same workspace's.
        WidgetSnapshotPublisher.selected(workspaceId: "ws-north", name: "Northside Roofing Ltd", session: session)
        XCTAssertEqual(store.saved?.workspaceName, "Northside Roofing Ltd")
        XCTAssertEqual(store.saved?.unreadMessages, 4)
        // ⛔ ANOTHER WORKSPACE'S COUNTS ARE NEVER SHOWN UNDER THE NEW NAME.
        WidgetSnapshotPublisher.selected(workspaceId: "ws-harbour", name: "Harbour Dental", session: session)
        XCTAssertEqual(store.saved?.workspaceName, "Harbour Dental")
        XCTAssertNil(store.saved?.unreadMessages)
        XCTAssertNil(store.saved?.callsThisWeek)
        // A negative count from a bad read is shown as zero, never below.
        WidgetSnapshotPublisher.unread(-3, workspaceId: "ws-harbour")
        XCTAssertEqual(store.saved?.unreadMessages, 0)
    }

    /// ⛔ TWO WORKSPACES WITH ONE NAME ARE STILL TWO (cubic, #112): the id decides.
    func test_WID_06_aSwitchToASameNamedWorkspaceDropsTheCounts() {
        let session = WidgetSnapshotPublisher.session
        WidgetSnapshotPublisher.selected(workspaceId: "ws-a", name: "Main Office", session: session)
        WidgetSnapshotPublisher.unread(7, workspaceId: "ws-a")
        WidgetSnapshotPublisher.callsThisWeek(12, workspaceId: "ws-a")
        WidgetSnapshotPublisher.selected(workspaceId: "ws-b", name: "Main Office", session: session)
        XCTAssertEqual(store.saved?.workspaceId, "ws-b")
        XCTAssertNil(store.saved?.unreadMessages)
        XCTAssertNil(store.saved?.callsThisWeek)
    }

    /// ⛔ A COUNT READ FOR ONE WORKSPACE THAT ANSWERS AFTER A SWITCH IS DROPPED (cubic, #112):
    /// a silent push's read, or an Overview still on the wire.
    func test_WID_07_aLateCountForTheLastWorkspaceIsDropped() {
        let session = WidgetSnapshotPublisher.session
        WidgetSnapshotPublisher.selected(workspaceId: "ws-a", name: "Northside Roofing", session: session)
        WidgetSnapshotPublisher.selected(workspaceId: "ws-b", name: "Harbour Dental", session: session)
        let before = reloads
        WidgetSnapshotPublisher.unread(9, workspaceId: "ws-a")
        WidgetSnapshotPublisher.callsThisWeek(30, workspaceId: "ws-a")
        XCTAssertEqual(
            store.saved,
            WidgetSnapshot(workspaceId: "ws-b", workspaceName: "Harbour Dental", updatedAt: clock)
        )
        XCTAssertEqual(reloads, before)
    }

    /// ⛔ A READ BEGUN BEFORE A SIGN-OUT PUTS NOTHING BACK (cubic, #112): neither the workspace
    /// list (which carries the session it began in) nor a count (which finds no snapshot).
    func test_WID_08_aReadThatAnswersAfterSignOutWritesNothing() {
        let began = WidgetSnapshotPublisher.session
        WidgetSnapshotPublisher.selected(workspaceId: "ws-a", name: "Northside Roofing", session: began)
        WidgetSnapshotPublisher.signedOut()
        WidgetSnapshotPublisher.selected(workspaceId: "ws-a", name: "Northside Roofing", session: began)
        WidgetSnapshotPublisher.unread(3, workspaceId: "ws-a")
        WidgetSnapshotPublisher.callsThisWeek(5, workspaceId: "ws-a")
        XCTAssertNil(store.saved)
        // The next account's list, begun after the sign-out, is published.
        WidgetSnapshotPublisher.selected(
            workspaceId: "ws-b", name: "Harbour Dental", session: WidgetSnapshotPublisher.session
        )
        XCTAssertEqual(store.saved?.workspaceId, "ws-b")
        // ⛔ And the same holds for a list that found nothing to select.
        WidgetSnapshotPublisher.noWorkspace(session: began)
        XCTAssertEqual(store.saved?.workspaceId, "ws-b")
    }

    /// ⛔ A COMPLETE LIST WITH NOTHING TO SELECT CLEARS IT (Seer and cubic, #112); the wiring is
    /// in ``test_WID_05_theWiring()``.
    func test_WID_09_noWorkspaceToSelectClearsTheSnapshot() {
        let session = WidgetSnapshotPublisher.session
        WidgetSnapshotPublisher.selected(workspaceId: "ws-a", name: "Northside Roofing", session: session)
        let before = reloads
        WidgetSnapshotPublisher.noWorkspace(session: session)
        XCTAssertNil(store.saved)
        XCTAssertEqual(reloads, before + 1)
    }

    /// ⛔ A FAILED DELETE IS RETRIED, AND NOTHING LANDS ON THE LEFT-BEHIND SNAPSHOT (cubic, #112).
    func test_WID_10_aFailedSignOutDeleteIsRetried() {
        let session = WidgetSnapshotPublisher.session
        WidgetSnapshotPublisher.selected(workspaceId: "ws-a", name: "Northside Roofing", session: session)
        store.clearFails = true
        WidgetSnapshotPublisher.signedOut()
        XCTAssertEqual(store.saved?.workspaceId, "ws-a", "the delete failed")
        // A late count for that workspace must not refresh the snapshot the sign-out meant to delete.
        WidgetSnapshotPublisher.unread(3, workspaceId: "ws-a")
        XCTAssertNil(store.saved?.unreadMessages)
        // The next publication retries the delete first.
        store.clearFails = false
        WidgetSnapshotPublisher.selected(
            workspaceId: "ws-b", name: "Harbour Dental", session: WidgetSnapshotPublisher.session
        )
        // The sign-out, the retry the refused count made, and the one that succeeded.
        XCTAssertEqual(store.clears, 3)
        XCTAssertEqual(
            store.saved,
            WidgetSnapshot(workspaceId: "ws-b", workspaceName: "Harbour Dental", updatedAt: clock)
        )
        // An unsigned build has nothing to delete, and that is not a failure.
        XCTAssertNoThrow(try WidgetSnapshotKeychain(accessGroup: nil).clear())
    }

    /// ⛔ THE SEVEN-DAY CALL COUNT TURNS INTO A DASH A DAY AFTER IT WAS READ (cubic, #112), and the
    /// widget's timeline carries that moment; the unread count and the name stay.
    func test_WID_11_theCallCountExpiresOnTheTimeline() throws {
        let read = clock
        let snapshot = WidgetSnapshot(
            workspaceId: "ws-a",
            workspaceName: "Northside Roofing",
            unreadMessages: 2,
            callsThisWeek: 19,
            callsReadAt: read,
            updatedAt: read
        )
        let expiry = read.addingTimeInterval(24 * 60 * 60)
        XCTAssertEqual(WidgetSnapshot.callsMaxAge, 24 * 60 * 60)
        let fresh = snapshot.timeline(from: read.addingTimeInterval(60))
        XCTAssertEqual(fresh.map(\.date), [read.addingTimeInterval(60), expiry])
        XCTAssertEqual(fresh.map(\.snapshot.callsThisWeek), [19, nil])
        XCTAssertEqual(fresh.last?.snapshot.unreadMessages, 2)
        XCTAssertEqual(fresh.last?.snapshot.workspaceName, "Northside Roofing")
        // Asked after it expired (a reboot, a relaunch): one entry, with a dash.
        let stale = snapshot.timeline(from: expiry)
        XCTAssertEqual(stale.count, 1)
        XCTAssertNil(try XCTUnwrap(stale.first).snapshot.callsThisWeek)
        // Never read: one entry, nothing to expire.
        let unread = WidgetSnapshot(workspaceId: "ws-a", workspaceName: "Northside Roofing", updatedAt: read)
        XCTAssertEqual(unread.timeline(from: read).count, 1)
    }

    /// ⛔ SIGN-OUT CLEARS IT, and asks the widget to redraw its signed-out face.
    func test_WID_02_signOutClearsTheSnapshot() {
        WidgetSnapshotPublisher.selected(
            workspaceId: "ws-north", name: "Northside Roofing", session: WidgetSnapshotPublisher.session
        )
        let before = reloads
        WidgetSnapshotPublisher.signedOut()
        XCTAssertNil(store.saved)
        XCTAssertEqual(reloads, before + 1)
    }

    func test_WID_03_theSnapshotRoundTripsAndHoldsNoCustomerData() throws {
        let snapshot = WidgetSnapshot(
            workspaceId: "ws-north",
            workspaceName: "Northside Roofing",
            unreadMessages: 2,
            callsThisWeek: 7,
            callsReadAt: clock,
            updatedAt: clock
        )
        let data = try WidgetSnapshotKeychain.encoder.encode(snapshot)
        XCTAssertEqual(try WidgetSnapshotKeychain.decoder.decode(WidgetSnapshot.self, from: data), snapshot)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys.sorted()
        XCTAssertEqual(
            keys,
            ["callsReadAt", "callsThisWeek", "unreadMessages", "updatedAt", "workspaceId", "workspaceName"],
            "a field the widget does not need"
        )
    }

    /// ⛔ THE `.widget` GROUP IS NAMED ON EVERY QUERY, and an unsigned build (no group) reads
    /// and writes nothing.
    func test_WID_04_theKeychainItemNamesTheWidgetGroup() throws {
        XCTAssertEqual(
            KeychainAccessGroups.group(KeychainAccessGroups.widgetSuffix, prefix: "R935BA6767."),
            "R935BA6767.com.distronode.district.widget"
        )
        let signed = WidgetSnapshotKeychain(accessGroup: "R935BA6767.com.distronode.district.widget")
        let query = try XCTUnwrap(signed.query())
        XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, "R935BA6767.com.distronode.district.widget")
        XCTAssertEqual(query[kSecAttrService as String] as? String, "com.distronode.district.widget")
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
        let unsigned = WidgetSnapshotKeychain(accessGroup: nil)
        XCTAssertNil(unsigned.query())
        XCTAssertNil(unsigned.read())
        XCTAssertNoThrow(try unsigned.write(WidgetSnapshot(updatedAt: clock)))
    }

    /// ⛔ THE WRITES COME FROM READS THE APP ALREADY DOES, and every sign-out clears it.
    func test_WID_05_theWiring() throws {
        let root = try SourceScan.sourceRoot()
        func code(_ path: String) throws -> String {
            try SourceScan.stripComments(String(contentsOf: root.appendingPathComponent(path), encoding: .utf8))
        }
        XCTAssertTrue(try code("Platform/UnreadBadge.swift")
            .contains("WidgetSnapshotPublisher.unread(count, workspaceId: workspaceId)"))
        let overview = try code("Features/Overview/OverviewModel.swift")
        let guarded = "if case .content = state {\n                "
            + "WidgetSnapshotPublisher.callsThisWeek(response.metrics.callsThisWeek, workspaceId: workspaceId)"
        XCTAssertTrue(overview.contains(guarded), "the week's calls reach the widget from a mismatched answer")
        // ⛔ The list's session is captured BEFORE its await, and a list with nothing to select
        // clears the widget.
        let workspaces = try code("Session/WorkspaceSessionModel.swift")
        let captured = "let widgetSession = WidgetSnapshotPublisher.session\n"
            + "        switch await container.workspaces.list() {"
        XCTAssertTrue(workspaces.contains(captured), "the session is read after the list answers")
        XCTAssertTrue(workspaces.contains("publishToWidget(session: widgetSession)"))
        XCTAssertTrue(workspaces.contains(
            "WidgetSnapshotPublisher.selected(workspaceId: selected.id, name: selected.name, session: session)"
        ))
        XCTAssertTrue(workspaces.contains("case .empty, .lapsed:\n            WidgetSnapshotPublisher.noWorkspace"))
        // ⛔ Every sign-out: the server ending the session, the button, and a deleted account.
        let session = try code("Session/SessionModel.swift")
        XCTAssertEqual(session.components(separatedBy: "WidgetSnapshotPublisher.signedOut()").count, 4)
    }
}

private final class Box<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private final class MemoryStore: WidgetSnapshotStoring, @unchecked Sendable {
    var saved: WidgetSnapshot?
    var clearFails = false
    var clears = 0

    func read() -> WidgetSnapshot? {
        saved
    }

    func write(_ snapshot: WidgetSnapshot) throws {
        saved = snapshot
    }

    func clear() throws {
        clears += 1
        guard !clearFails else { throw WidgetSnapshotError.status(errSecInteractionNotAllowed) }
        saved = nil
    }
}
