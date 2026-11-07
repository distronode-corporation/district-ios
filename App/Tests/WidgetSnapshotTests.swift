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
        WidgetSnapshotPublisher.store = WidgetSnapshotKeychain()
        WidgetSnapshotPublisher.now = { Date() }
        WidgetSnapshotPublisher.reload = {}
        super.tearDown()
    }

    func test_WID_01_theCountsFollowTheirReadsAndAWorkspaceSwitchDropsThem() {
        WidgetSnapshotPublisher.selected(workspace: "Northside Roofing")
        WidgetSnapshotPublisher.unread(4)
        clock += 60
        WidgetSnapshotPublisher.callsThisWeek(19)
        XCTAssertEqual(
            store.saved,
            WidgetSnapshot(workspaceName: "Northside Roofing", unreadMessages: 4, callsThisWeek: 19, updatedAt: clock)
        )
        // The same workspace again changes nothing and redraws nothing.
        let before = reloads
        WidgetSnapshotPublisher.selected(workspace: "Northside Roofing")
        XCTAssertEqual(reloads, before)
        // ⛔ ANOTHER WORKSPACE'S COUNTS ARE NEVER SHOWN UNDER THE NEW NAME.
        WidgetSnapshotPublisher.selected(workspace: "Harbour Dental")
        XCTAssertEqual(store.saved?.workspaceName, "Harbour Dental")
        XCTAssertNil(store.saved?.unreadMessages)
        XCTAssertNil(store.saved?.callsThisWeek)
        // A negative count from a bad read is shown as zero, never below.
        WidgetSnapshotPublisher.unread(-3)
        XCTAssertEqual(store.saved?.unreadMessages, 0)
    }

    /// ⛔ SIGN-OUT CLEARS IT, and asks the widget to redraw its signed-out face.
    func test_WID_02_signOutClearsTheSnapshot() {
        WidgetSnapshotPublisher.selected(workspace: "Northside Roofing")
        let before = reloads
        WidgetSnapshotPublisher.signedOut()
        XCTAssertNil(store.saved)
        XCTAssertEqual(reloads, before + 1)
    }

    func test_WID_03_theSnapshotRoundTripsAndHoldsNoCustomerData() throws {
        let snapshot = WidgetSnapshot(
            workspaceName: "Northside Roofing",
            unreadMessages: 2,
            callsThisWeek: nil,
            updatedAt: clock
        )
        let data = try WidgetSnapshotKeychain.encoder.encode(snapshot)
        XCTAssertEqual(try WidgetSnapshotKeychain.decoder.decode(WidgetSnapshot.self, from: data), snapshot)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys.sorted()
        XCTAssertEqual(keys, ["unreadMessages", "updatedAt", "workspaceName"], "a field the widget does not need")
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

    /// ⛔ THE WRITES COME FROM READS THE APP ALREADY DOES, and both sign-outs clear it.
    func test_WID_05_theWiring() throws {
        let root = try SourceScan.sourceRoot()
        func code(_ path: String) throws -> String {
            try SourceScan.stripComments(String(contentsOf: root.appendingPathComponent(path), encoding: .utf8))
        }
        XCTAssertTrue(try code("Platform/UnreadBadge.swift").contains("WidgetSnapshotPublisher.unread(count)"))
        let overview = try code("Features/Overview/OverviewModel.swift")
        let guarded = "if case .content = state {\n                "
            + "WidgetSnapshotPublisher.callsThisWeek(response.metrics.callsThisWeek)"
        XCTAssertTrue(overview.contains(guarded), "the week's calls reach the widget from a mismatched answer")
        XCTAssertTrue(try code("Session/WorkspaceSessionModel.swift")
            .contains("WidgetSnapshotPublisher.selected(workspace: name)"))
        let session = try code("Session/SessionModel.swift")
        XCTAssertEqual(session.components(separatedBy: "WidgetSnapshotPublisher.signedOut()").count, 3)
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

    func read() -> WidgetSnapshot? {
        saved
    }

    func write(_ snapshot: WidgetSnapshot) throws {
        saved = snapshot
    }

    func clear() {
        saved = nil
    }
}
