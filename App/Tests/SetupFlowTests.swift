@testable import DistrictAI
import DistrictModel
import Foundation
import XCTest

/// The setup wizard's pure rules: where a stored progress opens it, which failures are
/// refusals, the facts it writes, the numbers it accepts and the pages it hands to the web.
@MainActor
final class SetupFlowTests: XCTestCase {
    private func progress(_ states: [String?]) throws -> SetupProgress {
        let keys = ["business", "number", "receptionist", "callers", "calls", "golive"]
        let pairs = zip(keys, states).compactMap { key, state in state.map { "\"\(key)\":\"\($0)\"" } }
        let json = "{\"steps\":{\(pairs.joined(separator: ","))}}"
        return try JSONDecoder().decode(SetupProgress.self, from: Data(json.utf8))
    }

    // MARK: - The step machine

    func testTheWizardOpensOnTheFirstStepStillToDo() throws {
        XCTAssertEqual(try SetupFlow.firstOpen(progress(["todo", "todo", "todo", "todo", "todo", "todo"])), .business)
        XCTAssertEqual(
            try SetupFlow.firstOpen(progress(["done", "done", "todo", "todo", "todo", "todo"])),
            .receptionist
        )
        XCTAssertEqual(
            try SetupFlow.firstOpen(progress(["done", "skipped", "done", "todo", "todo", "todo"])),
            .callers,
            "a skipped step is not open"
        )
    }

    /// ⛔ THE WEB'S `=== "todo"`: nothing open opens on the first step, and an unknown state
    /// is not open.
    func testWithNothingOpenItOpensOnTheFirstStepAndAnUnknownStateIsNotOpen() throws {
        XCTAssertEqual(
            try SetupFlow.firstOpen(progress(["done", "done", "done", "done", "done", "skipped"])),
            .business
        )
        XCTAssertEqual(try SetupFlow.firstOpen(progress(["done", "paused", "todo", nil, nil, nil])), .receptionist)
        XCTAssertEqual(SetupFlow.firstOpen(nil), .business)
    }

    func testTheOrderIsTheWebsSixSteps() {
        XCTAssertEqual(
            SetupFlow.steps.map(\.rawValue),
            ["business", "number", "receptionist", "callers", "calls", "golive"]
        )
        XCTAssertEqual(SetupFlow.next(after: .business), .number)
        XCTAssertNil(SetupFlow.next(after: .golive))
        XCTAssertNil(SetupFlow.previous(before: .business))
        XCTAssertEqual(SetupFlow.previous(before: .golive), .calls)
    }

    // MARK: - Refusals

    func testANonOwnerAndAPreWizardWorkspaceAreRefusalsAndNothingElseIs() {
        XCTAssertEqual(SetupRefusal.from(.http(status: 403, message: "x", code: "workspace_owner_only")), .notOwner)
        XCTAssertEqual(SetupRefusal.from(.http(status: 409, message: "x", code: "setup_not_available")), .notAvailable)
        XCTAssertNil(SetupRefusal.from(.http(status: 409, message: "x", code: "conflict")))
        XCTAssertNil(SetupRefusal.from(.http(status: 500, message: nil)))
        XCTAssertNil(SetupRefusal.from(.transport("offline")))
    }

    // MARK: - Language

    /// ⛔ A STORED LANGUAGE IS KEPT unless the owner chose the other family.
    func testAStoredLanguageIsKeptUnlessTheOtherFamilyIsChosen() {
        XCTAssertEqual(SetupLanguage.toSave(stored: "en-GB", chosen: .en), "en-GB")
        XCTAssertEqual(SetupLanguage.toSave(stored: "en-GB", chosen: .fr), "fr-CA")
        XCTAssertEqual(SetupLanguage.toSave(stored: nil, chosen: .en), "en-US")
        XCTAssertEqual(SetupLanguage.toSave(stored: "de-DE", chosen: .en), "de-DE", "tests run in English")
        XCTAssertEqual(SetupLanguage.toSave(stored: "de-DE", chosen: .fr), "fr-CA")
    }

    func testTheDraftOpensOnTheStoredPlaceAndDropsADefaultWorkspaceName() throws {
        let json = SetupFixture
            .setup(facts: "{\"address\":{\"city\":\"Toronto\",\"region\":\"on\",\"country\":\"CA\"}}")
        let data = try JSONDecoder().decode(DistrictSetupResponse.self, from: Data(json.utf8))
        let draft = SetupBusinessDraft.initial(
            data: data,
            personaLanguage: "fr-CA",
            workspaceName: "sean's Communications Workspace"
        )
        XCTAssertEqual(draft, SetupBusinessDraft(
            businessName: "",
            country: "CA",
            subdivision: "ON",
            city: "Toronto",
            language: .fr
        ))
    }

    func testTheDraftIsKeptPerWorkspace() {
        let store = SetupDraftStore(defaults: SetupDefaults.fresh())
        let draft = SetupBusinessDraft(businessName: "A", country: "US", subdivision: "NY", city: "B", language: .en)
        store.save(draft, workspaceId: "ws_a")
        XCTAssertEqual(store.load(workspaceId: "ws_a"), draft)
        XCTAssertNil(store.load(workspaceId: "ws_b"))
        store.clear(workspaceId: "ws_a")
        XCTAssertNil(store.load(workspaceId: "ws_a"))
    }

    // MARK: - Numbers

    func testANumberIsE164OrANorthAmericanNumberInANorthAmericanWorkspace() {
        XCTAssertEqual(SetupWire.e164("+44 20 7946 0958", region: "eu"), "+442079460958")
        XCTAssertEqual(SetupWire.e164("(416) 555-0123", region: "ca"), "+14165550123")
        XCTAssertEqual(SetupWire.e164("1 416 555 0123", region: "us"), "+14165550123")
        XCTAssertNil(SetupWire.e164("416 555 0123", region: "eu"), "no country code outside North America")
        XCTAssertNil(SetupWire.e164("call me", region: "ca"))
        XCTAssertNil(SetupWire.e164("+1234", region: "ca"))
    }

    // MARK: - The facts

    /// ⚠️ A DAY LEFT NOT SET IS ABSENT, NOT CLOSED; no day set at all is a clear.
    func testHoursWriteClosedAndSortedPeriodsAndLeaveAnUnsetDayOut() {
        var hours = SetupFacts.hours(nil)
        XCTAssertEqual(SetupFacts.json(hours: hours), .null)
        hours[.mon] = SetupDayDraft(state: .open, intervals: [
            SetupInterval(open: 13 * 60, close: 24 * 60),
            SetupInterval(open: 9 * 60, close: 12 * 60),
        ])
        hours[.sun] = SetupDayDraft(state: .closed, intervals: [])
        XCTAssertEqual(SetupFacts.json(hours: hours), .object([
            "mon": .array([
                .object(["open": .string("09:00"), "close": .string("12:00")]),
                .object(["open": .string("13:00"), "close": .string("24:00")]),
            ]),
            "sun": .string("closed"),
        ]))
        hours[.mon]?.intervals.sort { $0.open < $1.open }
        XCTAssertEqual(SetupFacts.hours(SetupFacts.json(hours: hours)), hours, "it reads back what it wrote, sorted")
    }

    func testADayRefusesOverlapsBackwardsPeriodsAndAFifthPeriod() {
        let open = { (intervals: [SetupInterval]) in SetupDayDraft(state: .open, intervals: intervals) }
        XCTAssertTrue(SetupFacts.isValid(open([
            SetupInterval(open: 540, close: 720),
            SetupInterval(open: 720, close: 1020),
        ])))
        XCTAssertFalse(SetupFacts.isValid(open([
            SetupInterval(open: 540, close: 800),
            SetupInterval(open: 720, close: 1020),
        ])))
        XCTAssertFalse(SetupFacts.isValid(open([SetupInterval(open: 600, close: 540)])))
        XCTAssertFalse(SetupFacts.isValid(open(Array(repeating: SetupInterval(open: 0, close: 1), count: 5))))
        XCTAssertFalse(SetupFacts.isValid(open([])))
    }

    func testAnEmptyAddressIsAClearAndAPartOneNeedsACityAndACountryCode() {
        XCTAssertEqual(SetupFacts.json(address: SetupAddressDraft()), .null)
        XCTAssertTrue(SetupFacts.isValid(SetupAddressDraft()))
        XCTAssertFalse(SetupFacts.isValid(SetupAddressDraft(line1: "1 Main")))
        XCTAssertFalse(SetupFacts.isValid(SetupAddressDraft(city: "Laval", country: "Canada")))
        let address = SetupAddressDraft(city: " Laval ", country: "ca")
        XCTAssertTrue(SetupFacts.isValid(address))
        XCTAssertEqual(
            SetupFacts.json(address: address),
            .object(["city": .string("Laval"), "country": .string("CA")]),
            "blank optional parts are left out, never sent as empty strings"
        )
    }

    /// ⛔ THE STORED ROWS GO BACK WHOLE and a duplicate is not added twice.
    func testAppendingKeepsStoredRowsWholeSkipsDuplicatesAndStopsAtTheLimit() {
        let stored: [WireJSON] = [.object(["name": .string("Cleaning"), "enabled": .bool(true), "extra": .integer(1)])]
        let incoming: [WireJSON] = [
            .object(["name": .string(" cleaning "), "enabled": .bool(false)]),
            .object(["name": .string("Whitening"), "enabled": .bool(false)]),
            .object(["name": .string("Braces"), "enabled": .bool(false)]),
        ]
        let out = SetupFacts.appending(incoming, to: stored, key: "name", max: 2)
        XCTAssertEqual(out, [stored[0], incoming[1]])
    }

    func testAPlaceNamesItsZoneAndSaysWhenItHasMoreThanOne() {
        XCTAssertEqual(
            SetupPlaces.zone(country: "CA", subdivision: "qc"),
            .init(timezone: "America/Toronto", multiZone: true)
        )
        XCTAssertEqual(SetupPlaces.zone(country: "CA", subdivision: "MB"), .init(timezone: "America/Winnipeg"))
        XCTAssertNil(SetupPlaces.zone(country: "US", subdivision: ""), "no state, no zone")
        XCTAssertEqual(SetupPlaces.zone(country: "FR", subdivision: ""), .init(timezone: "Europe/Paris"))
        XCTAssertEqual(SetupPlaces.countries.prefix(2), ["CA", "US"])
        XCTAssertEqual(SetupPlaces.provinces.count, 13)
        XCTAssertEqual(SetupPlaces.states.count, 51)
    }

    // MARK: - The hand-offs

    func testEachHandOffOpensItsPageOnTheBuildsOwnHost() throws {
        let production = try XCTUnwrap(URL(string: "https://www.distronode.com"))
        XCTAssertEqual(
            SetupHandOff.setup.destination(baseURL: production)?.absoluteString,
            "https://www.distronode.com/dashboard/district"
        )
        XCTAssertEqual(
            SetupHandOff.skills.destination(baseURL: production)?.absoluteString,
            "https://www.distronode.com/dashboard/district/studio/skills"
        )
        let staging = try XCTUnwrap(URL(string: "https://staging.example.com/api?x=1#y"))
        XCTAssertEqual(
            SetupHandOff.integrations.destination(baseURL: staging)?.absoluteString,
            "https://staging.example.com/dashboard/district/studio/integrations"
        )
    }

    /// ⛔ `SFSafariViewController` TRAPS ON A NON-HTTP SCHEME, so no button is better than one.
    func testANonHTTPSBaseOffersNoHandOff() throws {
        let local = try XCTUnwrap(URL(string: "http://127.0.0.1:8783"))
        XCTAssertNil(SetupHandOff.setup.destination(baseURL: local))
    }

    /// ⛔ WHY A SAFARI SHEET: every page is one this app CLAIMS, so the system would route it back.
    func testEveryHandOffIsAClaimedURLWhichIsWhyItIsNeverHandedToTheSystem() throws {
        let production = try XCTUnwrap(URL(string: "https://www.distronode.com"))
        for page in [SetupHandOff.setup, .skills, .integrations] {
            let url = try XCTUnwrap(page.destination(baseURL: production))
            XCTAssertNotNil(AppLinkResolver.resolve(url), "\(url) is no longer claimed; revisit the sheet")
        }
    }
}
