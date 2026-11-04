@testable import DistrictAI
import Foundation
import XCTest

/// The dialler's country button as the keypad drives it: a `+` number moves it, a pick
/// re-reads the digits, a workspace with no home country remembers its pick, and the
/// number Call would send is the E.164 one.
///
/// ⚠️ EVERY CONTAINER POINTS AT `https://calls.invalid`, as `MicrophoneAccessTests` explains,
/// and nothing here presses Call: ``DialerModel/canPlaceCall`` and
/// ``DialerModel/destination`` are what is read.
@MainActor
final class DialerCountryTests: XCTestCase {
    private let unreachable = URL(string: "https://calls.invalid")!

    private func model(home: String? = nil, picked: String? = nil) -> (DialerModel, MemoryCountries) {
        let memory = MemoryCountries(home: home, picked: picked)
        let model = DialerModel(container: AppContainer(baseURL: unreachable), workspaceId: "ws_1", role: .agency)
        model.countries = DialerCountries(workspaceId: "ws_1", numbers: nil, memory: memory)
        return (model, memory)
    }

    func testALocalNumberUnderTheHomeFlagIsSentAsE164() {
        let (model, _) = model(home: "CA")
        model.onEntryChange("4165550199")
        XCTAssertEqual(model.entry, "(416) 555-0199")
        XCTAssertEqual(model.countries.current, "CA")
        XCTAssertTrue(model.canPlaceCall)
        XCTAssertEqual(model.destination.e164, "+14165550199")
    }

    /// ⛔ THE FLAG FOLLOWS A PASTED `+` NUMBER and the field drops to the local form.
    func testAPastedPlusNumberMovesTheFlag() {
        let (model, _) = model(home: "CA")
        model.onEntryChange("+44 20 7946 0958")
        XCTAssertEqual(model.countries.current, "GB")
        XCTAssertEqual(model.entry, "020 7946 0958")
        XCTAssertEqual(model.destination.e164, "+442079460958")
        XCTAssertTrue(model.canPlaceCall)
    }

    func testTheSwitzerlandMisdialShowsTheSwissFlagAndCannotBeCalled() {
        let (model, _) = model(home: "CA")
        model.onEntryChange("+4165550123")
        XCTAssertEqual(model.countries.current, "CH")
        XCTAssertFalse(model.canPlaceCall)
    }

    func testAnExitCodeMovesTheFlagToo() {
        let (model, _) = model(home: "CA")
        model.onEntryChange("011 33 6 39 98 01 23")
        XCTAssertEqual(model.countries.current, "FR")
        XCTAssertEqual(model.entry, "06 39 98 01 23")
    }

    func testAnEmergencyCodeStaysInTheFieldAndCannotBeCalled() {
        let (model, _) = model(home: "CA")
        model.onEntryChange("911")
        XCTAssertEqual(model.entry, "911")
        XCTAssertEqual(model.destination.status, .emergency)
        XCTAssertFalse(model.canPlaceCall)
    }

    // MARK: - No home country

    func testWithNoHomeCountryDigitsAloneCannotBeCalled() {
        let (model, _) = model()
        XCTAssertNil(model.countries.current)
        model.onEntryChange("4165550199")
        XCTAssertEqual(model.destination.status, .needsCountry)
        XCTAssertFalse(model.canPlaceCall)
    }

    /// ⚠️ PICK ONCE: the digits already typed are read in the picked country, and the pick
    /// is remembered for the workspace's next dial.
    func testAPickReadsTheDigitsAgainAndIsRemembered() {
        let (model, memory) = model()
        model.onEntryChange("4165550199")
        model.pickCountry("CA")
        XCTAssertEqual(model.entry, "(416) 555-0199")
        XCTAssertTrue(model.canPlaceCall)
        XCTAssertEqual(memory.picked(workspaceId: "ws_1"), "CA")
        XCTAssertEqual(DialerCountries(workspaceId: "ws_1", numbers: nil, memory: memory).current, "CA")
    }

    /// ⚠️ A PICK ON A WORKSPACE WITH A HOME COUNTRY IS FOR THIS CALL ONLY.
    func testAPickIsNotRememberedWhenTheWorkspaceHasAHomeCountry() {
        let (model, memory) = model(home: "CA")
        model.pickCountry("GB")
        XCTAssertEqual(model.countries.current, "GB")
        XCTAssertNil(memory.picked(workspaceId: "ws_1"))
    }

    func testACallBackRowMovesTheFlagToItsNumbersCountry() {
        let (model, _) = model()
        model.callBack("+14165550100")
        XCTAssertEqual(model.countries.current, "CA")
        XCTAssertEqual(model.entry, "(416) 555-0100")
    }

    func testTheHomeCountryWinsOverAPick() {
        let countries = DialerCountries(
            workspaceId: "ws_1",
            numbers: nil,
            memory: MemoryCountries(home: "FR", picked: "GB")
        )
        XCTAssertEqual(countries.current, "FR")
        XCTAssertEqual(countries.home, "FR")
    }

    // MARK: - UserDefaults

    func testTheDefaultsMemoryIsPerWorkspaceAndRefusesUnknownCodes() throws {
        let suite = "DialerCountryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = UserDefaultsDialerCountryMemory(defaults: defaults)
        memory.rememberHome("CA", workspaceId: "ws_a")
        memory.rememberPicked("GB", workspaceId: "ws_b")
        XCTAssertEqual(memory.home(workspaceId: "ws_a"), "CA")
        XCTAssertNil(memory.home(workspaceId: "ws_b"))
        XCTAssertEqual(memory.picked(workspaceId: "ws_b"), "GB")
        XCTAssertNil(memory.picked(workspaceId: "ws_a"))
        defaults.set("ZZ", forKey: UserDefaultsDialerCountryMemory.homeKeyPrefix + "ws_c")
        XCTAssertNil(memory.home(workspaceId: "ws_c"), "a code the table does not list is no country")
    }
}

/// ``DialerCountryMemory`` in memory, for the tests above.
private final class MemoryCountries: DialerCountryMemory {
    private var homes: [String: String] = [:]
    private var picks: [String: String] = [:]

    init(home: String?, picked: String?) {
        homes["ws_1"] = home
        picks["ws_1"] = picked
    }

    func home(workspaceId: String) -> String? {
        homes[workspaceId]
    }

    func rememberHome(_ iso: String, workspaceId: String) {
        homes[workspaceId] = iso
    }

    func picked(workspaceId: String) -> String? {
        picks[workspaceId]
    }

    func rememberPicked(_ iso: String, workspaceId: String) {
        picks[workspaceId] = iso
    }
}
