@testable import DistrictAIWatch
import Foundation
import XCTest

/// The Smart Stack relevance of the two complications (3.2): higher with unread messages, and
/// for a while after availability switched; nothing otherwise.
final class ComplicationRelevanceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Unread

    func testUnreadMessagesLiftTheUnreadComplicationMoreForMore() {
        let one = Self.state(unread: 1).relevance(forKind: ComplicationState.unreadWidgetKind, at: now)
        let five = Self.state(unread: 5).relevance(forKind: ComplicationState.unreadWidgetKind, at: now)
        let many = Self.state(unread: 40).relevance(forKind: ComplicationState.unreadWidgetKind, at: now)

        XCTAssertEqual(one, ComplicationRelevance(score: 55, duration: 0))
        XCTAssertGreaterThan(five.score, one.score)
        XCTAssertEqual(many, ComplicationRelevance(score: 100, duration: 0), "capped at 10")
    }

    func testNoUnreadOrAnUnknownCountIsNotRelevant() {
        XCTAssertEqual(Self.state(unread: 0).relevance(forKind: ComplicationState.unreadWidgetKind, at: now), .none)
        XCTAssertEqual(Self.state(unread: nil).relevance(forKind: ComplicationState.unreadWidgetKind, at: now), .none)
    }

    /// ⚠️ EACH COMPLICATION ANSWERS FOR ITSELF: unread messages do not lift availability.
    func testUnreadDoesNotLiftAvailability() {
        XCTAssertEqual(Self.state(unread: 3).relevance(forKind: ComplicationState.widgetKind, at: now), .none)
        XCTAssertEqual(Self.state(unread: 3).relevance(forKind: "another.kind", at: now), .none)
    }

    // MARK: - Availability

    func testASwitchIsStampedAndLiftsAvailabilityForTheWindow() {
        let before = Self.state(available: true)
        let after = Self.state(available: false).stamped(after: before, at: now)

        XCTAssertEqual(after.availabilityChangedAt, now)
        XCTAssertEqual(
            after.relevance(forKind: ComplicationState.widgetKind, at: now),
            ComplicationRelevance(score: 100, duration: ComplicationState.availabilityChangeWindow)
        )
        XCTAssertEqual(
            after.relevance(forKind: ComplicationState.widgetKind, at: now.addingTimeInterval(600)).duration,
            ComplicationState.availabilityChangeWindow - 600,
            "the rest of the window"
        )
        XCTAssertEqual(
            after.relevance(forKind: ComplicationState.widgetKind, at: now.addingTimeInterval(30 * 60)),
            .none,
            "and nothing once it has passed"
        )
        XCTAssertEqual(after.relevance(forKind: ComplicationState.unreadWidgetKind, at: now), .none)
    }

    /// ⚠️ UNKNOWN TO KNOWN IS NOT A SWITCH, and an unchanged value keeps the old stamp.
    func testOnlyASwitchBetweenKnownValuesIsStamped() {
        let first = Self.state(available: true).stamped(after: .unknown, at: now)
        XCTAssertNil(first.availabilityChangedAt)

        var stamped = Self.state(available: false)
        stamped.availabilityChangedAt = now
        let later = Self.state(available: false, unread: 2).stamped(after: stamped, at: now.addingTimeInterval(60))
        XCTAssertEqual(later.availabilityChangedAt, now, "carried over")

        let unknown = Self.state(available: nil).stamped(after: stamped, at: now.addingTimeInterval(60))
        XCTAssertEqual(unknown.relevance(forKind: ComplicationState.widgetKind, at: now), .none)
    }

    /// ⛔ SIGNED OUT LIFTS NOTHING AND KEEPS NO STAMP.
    func testSignedOutIsNeverRelevant() {
        var stamped = Self.state(available: true, unread: 4)
        stamped.availabilityChangedAt = now
        var signedOut = stamped
        signedOut.signedIn = false

        XCTAssertNil(signedOut.stamped(after: stamped, at: now).availabilityChangedAt)
        XCTAssertEqual(signedOut.relevance(forKind: ComplicationState.unreadWidgetKind, at: now), .none)
        XCTAssertEqual(signedOut.relevance(forKind: ComplicationState.widgetKind, at: now), .none)
    }

    /// ⚠️ A STATE AN OLDER WATCH APP WROTE HAS NO STAMP AND STILL DECODES.
    func testTheStampSurvivesTheAppGroupAndAnOldStateDecodes() throws {
        let suite = "ComplicationRelevanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var state = Self.state(available: true)
        state.availabilityChangedAt = now

        state.save(to: defaults)
        XCTAssertEqual(ComplicationState.load(from: defaults), state)

        let old = #"{"signedIn":true,"workspaceName":"Plomberie Desrosiers","available":true,"unreadCount":1}"#
        defaults.set(Data(old.utf8), forKey: ComplicationState.defaultsKey)
        XCTAssertNil(ComplicationState.load(from: defaults).availabilityChangedAt)
    }

    private static func state(available: Bool? = true, unread: Int? = nil) -> ComplicationState {
        ComplicationState(
            signedIn: true,
            workspaceName: "Plomberie Desrosiers",
            available: available,
            language: "en",
            unreadCount: unread
        )
    }
}
