@testable import DistrictAI
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// ``SetupCallersModel`` past SetupLaterStepModelTests: the hours editor's period arithmetic and
/// its ceilings, the hand-added items that start on, the website lookup's empty, refused and
/// repeated answers, an edit that confirms the website's hours, and a refused save.
@MainActor
final class SetupCallersModelMarginTests: SetupStepTestCase {
    private static let lookupHours = #","weeklyHours":{"mon":[{"open":"09:00","close":"17:00"}]}"#

    private func model(
        _ transport: SetupTransport = SetupTransport([:]),
        facts: String = "null"
    ) async -> SetupCallersModel {
        await SetupCallersModel(wizard: wizard(transport, facts: facts))
    }

    private func sentFacts(_ transport: SetupTransport) throws -> [String: Any] {
        try XCTUnwrap(transport.bodies(SetupFixture.patchRoute).last?["businessFacts"] as? [String: Any])
    }

    // MARK: - Hours

    /// Opening an unset day gives it the standard 9 to 5; opening a day that has periods keeps them.
    func testOpeningADayGivesItStandardHoursOnlyWhenItHasNone() async {
        let model = await model()
        XCTAssertEqual(model.hours[.wed]?.state, .notSet)
        model.setState(.open, for: .wed)
        XCTAssertEqual(model.hours[.wed]?.intervals, [SetupInterval.standard])

        model.addPeriod(to: .wed)
        model.setState(.closed, for: .wed)
        model.setState(.open, for: .wed)
        XCTAssertEqual(model.hours[.wed]?.intervals.count, 2, "re-opening keeps the periods it had")
        XCTAssertTrue(model.isValid)
    }

    /// A new period starts an hour after the latest close, and never runs past midnight.
    func testANewPeriodFollowsTheLatestCloseAndStopsAtMidnight() async {
        let model = await model(facts: #"{"weeklyHours":{"fri":[{"open":"09:00","close":"23:30"}]}}"#)
        model.addPeriod(to: .fri)
        XCTAssertEqual(model.hours[.fri]?.intervals.last, SetupInterval(open: 23 * 60, close: 24 * 60))
        XCTAssertFalse(model.isValid, "23:00 starts inside the 09:00 to 23:30 period, which is an overlap")

        model.setState(.open, for: .mon)
        model.addPeriod(to: .mon)
        XCTAssertEqual(model.hours[.mon]?.intervals.last, SetupInterval(open: 18 * 60, close: 19 * 60))
    }

    func testADayHoldsAtMostFourPeriods() async {
        let model = await model()
        model.setState(.open, for: .tue)
        for _ in 0 ..< 6 {
            model.addPeriod(to: .tue)
        }
        XCTAssertEqual(model.hours[.tue]?.intervals.count, SetupFacts.Limit.intervalsPerDay)
        XCTAssertEqual(model.hours[.tue]?.intervals.map(\.open), [540, 1080, 1200, 1320])
    }

    /// Removing a day's last period makes it unset again, and an unknown id changes nothing.
    func testRemovingTheLastPeriodUnsetsTheDay() async throws {
        let model = await model()
        model.setState(.open, for: .thu)
        model.removePeriod(UUID(), from: .thu)
        XCTAssertEqual(model.hours[.thu]?.intervals.count, 1)

        let only = try XCTUnwrap(model.hours[.thu]?.intervals.first)
        model.removePeriod(only.id, from: .thu)
        XCTAssertEqual(model.hours[.thu]?.state, .notSet)
        XCTAssertEqual(model.hours[.thu]?.intervals, [])
    }

    // MARK: - Services and questions

    /// A hand-added item starts on (typing it is the confirmation), and each list stops at 50.
    func testHandAddedItemsStartOnAndStopAtTheCeiling() async {
        let model = await model()
        for _ in 0 ..< 55 {
            model.addService()
            model.addFaq()
        }
        XCTAssertEqual(model.services.count, SetupFacts.Limit.services)
        XCTAssertEqual(model.faqs.count, SetupFacts.Limit.faqs)
        XCTAssertFalse(model.hasDrafts)
        XCTAssertFalse(model.isValid, "blank entries are invalid")

        model.faqs[3].enabled = false
        XCTAssertTrue(model.hasDrafts)
    }

    // MARK: - Hours from the website

    /// A blank or whitespace address is not looked up.
    func testABlankWebsiteIsNotLookedUp() async {
        let transport = SetupTransport([:])
        let model = await model(transport)
        model.websiteUrl = "   \n"
        await model.fillHoursFromWebsite()
        XCTAssertTrue(transport.sent(SetupFixture.lookupRoute).isEmpty)
        XCTAssertNil(model.hoursNotice)
        XCTAssertFalse(model.isReading)
    }

    /// A site with no hours, or an empty hours object, says so and leaves the hours alone.
    func testASiteWithNoHoursSaysSo() async {
        let absent = SetupFixture.lookup.replacingOccurrences(of: Self.lookupHours, with: "")
        let empty = SetupFixture.lookup.replacingOccurrences(of: Self.lookupHours, with: #","weeklyHours":{}"#)
        XCTAssertNotEqual(absent, SetupFixture.lookup, "the fixture's hours must be found to be removed")
        for body in [absent, empty] {
            let transport = SetupTransport([SetupFixture.lookupRoute: [(200, body)]])
            let model = await model(transport)
            model.websiteUrl = "example.com"
            await model.fillHoursFromWebsite()
            XCTAssertEqual(model.hoursNotice, SetupCopy.callersNoHoursFound)
            XCTAssertFalse(model.hoursDraftPending)
            XCTAssertEqual(model.hours[.mon]?.state, .notSet)
        }
    }

    /// An unreadable site is a sentence, not a draft.
    func testAnUnreadableSiteIsANoticeNotADraft() async {
        let transport = SetupTransport([SetupFixture.lookupRoute: [(422, SetupFixture.unreadable)]])
        let model = await model(transport)
        model.websiteUrl = "https://nowhere.invalid"
        await model.fillHoursFromWebsite()
        XCTAssertNotNil(model.hoursNotice)
        XCTAssertFalse(model.hoursDraftPending)
        XCTAssertEqual(model.hours[.mon]?.state, .notSet)
    }

    /// A second lookup while the first draft is pending still discards back to what was stored.
    func testDiscardAfterTwoLookupsRestoresTheStoredHours() async {
        let transport = SetupTransport([SetupFixture.lookupRoute: [(200, SetupFixture.lookup)]])
        let model = await model(transport, facts: #"{"weeklyHours":{"mon":"closed"}}"#)
        model.websiteUrl = "example.com"
        await model.fillHoursFromWebsite()
        await model.fillHoursFromWebsite()
        XCTAssertEqual(transport.sent(SetupFixture.lookupRoute).count, 2)
        XCTAssertEqual(model.hours[.mon]?.state, .open)
        model.discardDraftHours()
        XCTAssertEqual(model.hours[.mon]?.state, .closed)
    }

    /// Discard with no draft pending changes nothing.
    func testDiscardWithNoDraftIsANoOp() async {
        let model = await model(facts: #"{"weeklyHours":{"sat":"closed"}}"#)
        model.setState(.open, for: .sun)
        model.discardDraftHours()
        XCTAssertEqual(model.hours[.sun]?.state, .open)
        XCTAssertEqual(model.hours[.sat]?.state, .closed)
    }

    /// Editing any day confirms the website's hours, so the next save carries them.
    func testEditingADayConfirmsTheWebsitesHours() async throws {
        let transport = SetupTransport([SetupFixture.lookupRoute: [(200, SetupFixture.lookup)]])
        let model = await model(transport)
        transport.add(SetupFixture.patchRoute, SetupFixture.setup())
        model.websiteUrl = "example.com"
        await model.fillHoursFromWebsite()
        XCTAssertTrue(model.hoursDraftPending)

        model.setState(.closed, for: .sun)
        XCTAssertFalse(model.hoursDraftPending)
        let saved = await model.save()
        XCTAssertTrue(saved)
        let hours = try XCTUnwrap(sentFacts(transport)["weeklyHours"] as? [String: Any])
        XCTAssertEqual(hours["sun"] as? String, "closed")
        XCTAssertEqual((hours["mon"] as? [[String: String]])?.first, ["open": "09:00", "close": "17:00"])
    }

    // MARK: - Saving

    /// No zone chosen means no `timezone` key, rather than an empty one.
    func testAnUnsetZoneIsLeftOutOfThePatch() async {
        let model = await model()
        guard case let .object(patch) = model.patch() else { return XCTFail("the patch is an object") }
        XCTAssertNil(patch["timezone"])
        XCTAssertNotNil(patch["weeklyHours"])
        model.timezone = "America/Toronto"
        guard case let .object(withZone) = model.patch() else { return XCTFail("the patch is an object") }
        XCTAssertEqual(withZone["timezone"], .string("America/Toronto"))
    }

    /// A lower-case country still offers its own zones, with the stored zone among them.
    func testZonesFollowTheAddressCountryAndKeepTheStoredOne() async {
        let model = await model()
        model.address.country = "ca"
        model.timezone = "Europe/Paris"
        XCTAssertTrue(model.zones.contains("America/Toronto"), "\(model.zones)")
        XCTAssertTrue(model.zones.contains("Europe/Paris"))
        XCTAssertEqual(model.zones, model.zones.sorted())
    }

    /// A refused save says why, keeps the edits and does not count as saved.
    func testARefusedSaveKeepsTheEditsAndSaysWhy() async {
        let transport = SetupTransport([:])
        let model = await model(transport)
        transport.add(SetupFixture.patchRoute, status: 500, #"{"error":"Internal error"}"#)
        model.address.city = "Toronto"
        model.address.country = "CA"
        let saved = await model.save()
        XCTAssertFalse(saved)
        XCTAssertFalse(model.saved)
        XCTAssertNotNil(model.saveError)
        XCTAssertNotEqual(model.saveError, SetupCopy.callersFixErrors)
        XCTAssertEqual(model.address.city, "Toronto")
        XCTAssertFalse(model.isSaving)
    }

    /// An address with a city but no two-letter country is invalid and never sent.
    func testAnAddressWithoutACountryIsNeverSent() async {
        let transport = SetupTransport([:])
        let model = await model(transport)
        model.address.city = "Toronto"
        model.address.country = "Canada"
        XCTAssertFalse(model.isValid)
        await model.saveAndContinue()
        XCTAssertEqual(model.saveError, SetupCopy.callersFixErrors)
        XCTAssertTrue(model.showErrors)
        XCTAssertTrue(transport.sent(SetupFixture.patchRoute).isEmpty)
    }
}
