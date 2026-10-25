@testable import DistrictAIWatch
import Foundation
import XCTest

/// The opt-in unread complication (iOS 3.2): what it says, what it reloads, and that a state
/// an older watch app wrote still reads.
@MainActor
final class UnreadComplicationTests: XCTestCase {
    override func tearDown() {
        WatchL10n.phoneLanguage = nil
        super.tearDown()
    }

    /// ⛔ A 3.1.0 WATCH APP WROTE NO `unreadCount`: the state still decodes, as unknown.
    func testAStateWrittenBeforeTheUnreadCountStillDecodes() throws {
        let suite = "UnreadComplicationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = #"{"signedIn":true,"workspaceName":"Plomberie Desrosiers","available":true,"language":"en"}"#
        defaults.set(Data(old.utf8), forKey: ComplicationState.defaultsKey)

        let state = ComplicationState.load(from: defaults)

        XCTAssertEqual(
            state,
            ComplicationState(signedIn: true, workspaceName: "Plomberie Desrosiers", available: true, language: "en")
        )
        XCTAssertNil(state.unreadCount)
    }

    func testTheUnreadCountSurvivesTheAppGroup() throws {
        let suite = "UnreadComplicationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = Self.state(unread: 4)

        state.save(to: defaults)

        XCTAssertEqual(ComplicationState.load(from: defaults), state)
    }

    // MARK: - Reloads

    /// ⚠️ A NEW COUNT SPENDS ONLY THE UNREAD COMPLICATION'S RELOAD.
    func testANewCountReloadsOnlyTheUnreadComplication() {
        XCTAssertEqual(
            ComplicationState.kindsToReload(from: Self.state(unread: 1), to: Self.state(unread: 2)),
            [ComplicationState.unreadWidgetKind]
        )
    }

    func testAvailabilityAndTheWorkspaceReloadOnlyTheAvailabilityComplication() {
        var away = Self.state(unread: 1)
        away.available = false
        XCTAssertEqual(
            ComplicationState.kindsToReload(from: Self.state(unread: 1), to: away),
            [ComplicationState.widgetKind]
        )
        var renamed = Self.state(unread: 1)
        renamed.workspaceName = "Toitures Gagnon"
        XCTAssertEqual(
            ComplicationState.kindsToReload(from: Self.state(unread: 1), to: renamed),
            [ComplicationState.widgetKind]
        )
    }

    /// ⛔ A SIGN-OUT AND A LANGUAGE CHANGE ARE DRAWN BY BOTH, so both reload.
    func testSignInAndLanguageReloadBoth() {
        let both = [ComplicationState.widgetKind, ComplicationState.unreadWidgetKind]
        XCTAssertEqual(ComplicationState.kindsToReload(from: Self.state(unread: 1), to: .unknown), both)
        var french = Self.state(unread: 1)
        french.language = "fr-CA"
        XCTAssertEqual(ComplicationState.kindsToReload(from: Self.state(unread: 1), to: french), both)
    }

    func testAnUnchangedStateReloadsNothing() {
        XCTAssertEqual(ComplicationState.kindsToReload(from: Self.state(unread: 3), to: Self.state(unread: 3)), [])
    }

    func testTheTwoKindsDiffer() {
        XCTAssertNotEqual(ComplicationState.widgetKind, ComplicationState.unreadWidgetKind)
        XCTAssertEqual(ComplicationState.unreadWidgetKind, "com.distronode.district.complication.unread")
    }

    // MARK: - Wording

    /// ⛔ A COUNT AND NOTHING ELSE: no workspace name in any family's words.
    func testTheInlineLineIsACountWithNoName() {
        let line = UnreadComplicationView.inline(for: Self.state(unread: 3))

        XCTAssertEqual(line, "3 unread messages")
        XCTAssertFalse(line.contains("Plomberie"))
        XCTAssertEqual(UnreadComplicationView.inline(for: Self.state(unread: 1)), "1 unread message")
    }

    func testTheInlineLineFollowsThePhonesFrench() {
        WatchL10n.phoneLanguage = "fr-CA"

        XCTAssertEqual(UnreadComplicationView.inline(for: Self.state(unread: 1)), "1 message non lu")
        XCTAssertEqual(UnreadComplicationView.inline(for: Self.state(unread: 5)), "5 messages non lus")
    }

    /// ⛔ UNKNOWN IS NOT ZERO, AND SIGNED OUT SHOWS NO NUMBER AT ALL.
    func testNoCountIsShownWhenUnknownOrSignedOut() {
        var unknown = Self.state(unread: 0)
        unknown.unreadCount = nil
        XCTAssertNil(UnreadComplicationView.count(for: unknown))
        XCTAssertEqual(UnreadComplicationView.inline(for: unknown), WatchCopy.openIphoneShort)

        var signedOut = Self.state(unread: 7)
        signedOut.signedIn = false
        XCTAssertNil(UnreadComplicationView.count(for: signedOut))
        XCTAssertEqual(UnreadComplicationView.inline(for: signedOut), WatchCopy.signedOut)

        XCTAssertEqual(UnreadComplicationView.count(for: Self.state(unread: 0)), 0)
    }

    func testTheBadgeStopsAtTwoDigits() {
        XCTAssertEqual(UnreadComplicationView.badge(0), "0")
        XCTAssertEqual(UnreadComplicationView.badge(99), "99")
        XCTAssertEqual(UnreadComplicationView.badge(100), "99+")
    }

    static func state(unread: Int?) -> ComplicationState {
        ComplicationState(
            signedIn: true, workspaceName: "Plomberie Desrosiers", available: true, language: "en", unreadCount: unread
        )
    }
}
