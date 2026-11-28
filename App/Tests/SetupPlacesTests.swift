@testable import DistrictAI
import DistrictL10n
import Foundation
import XCTest

/// The places step 4 offers: the country a region opens on, the time zones a country offers (with
/// the stored one kept), each subdivision's name in the app's language, and every zone named here
/// being one the system knows.
final class SetupPlacesTests: XCTestCase {
    override func tearDown() {
        L10nRuntime.locale = .en
        super.tearDown()
    }

    func testARegionOpensOnItsCountry() {
        XCTAssertEqual(SetupPlaces.defaultCountry(region: "ca"), "CA")
        XCTAssertEqual(SetupPlaces.defaultCountry(region: "us"), "US")
        for region in [nil, "", "eu", "apac", "CA", "US"] {
            XCTAssertEqual(SetupPlaces.defaultCountry(region: region), "", region ?? "nil")
        }
    }

    /// Canada and the US list their subdivisions; every other country lists none.
    func testOnlyCanadaAndTheUSHaveSubdivisions() {
        XCTAssertEqual(SetupPlaces.subdivisions("CA")?.count, 13)
        XCTAssertEqual(SetupPlaces.subdivisions("US")?.count, 51, "fifty states and DC")
        XCTAssertNil(SetupPlaces.subdivisions("FR"))
        XCTAssertNil(SetupPlaces.subdivisions("ca"), "the code as the service writes it, upper case")
    }

    /// A country without subdivisions has its one zone; a subdivision code is ignored for it.
    func testAZoneForACountryWithoutSubdivisions() {
        XCTAssertEqual(SetupPlaces.zone(country: "FR", subdivision: "")?.timezone, "Europe/Paris")
        XCTAssertEqual(
            SetupPlaces.zone(country: "ES", subdivision: "XX"),
            .init(timezone: "Europe/Madrid", multiZone: true)
        )
        XCTAssertNil(SetupPlaces.zone(country: "ZZ", subdivision: ""))
        XCTAssertNil(SetupPlaces.zone(country: "CA", subdivision: "XX"), "an unknown province names no zone")
    }

    /// The zones a country offers, the stored one added once, sorted.
    func testTheZonesOfferedKeepTheStoredOne() {
        let canada = SetupPlaces.zones(country: "CA", including: "")
        XCTAssertEqual(canada, canada.sorted())
        XCTAssertEqual(Set(canada).count, canada.count, "Toronto is Ontario's and Quebec's, listed once")
        XCTAssertTrue(canada.contains("America/Toronto"))

        XCTAssertEqual(SetupPlaces.zones(country: "FR", including: ""), ["Europe/Paris"])
        XCTAssertEqual(SetupPlaces.zones(country: "FR", including: "Europe/Paris"), ["Europe/Paris"])
        XCTAssertEqual(
            SetupPlaces.zones(country: "FR", including: "America/Martinique"),
            ["America/Martinique", "Europe/Paris"],
            "a zone stored on the web is kept, never dropped from the choice"
        )
        XCTAssertEqual(SetupPlaces.zones(country: "ZZ", including: ""), [])
        XCTAssertEqual(SetupPlaces.zones(country: "ZZ", including: "Asia/Tokyo"), ["Asia/Tokyo"])
    }

    /// ⛔ EVERY ZONE NAMED HERE IS ONE THE SYSTEM KNOWS: a typo would be saved as the business's zone.
    func testEveryZoneIsARealTimeZone() {
        let all = (SetupPlaces.provinces + SetupPlaces.states).map(\.zone.timezone)
            + SetupPlaces.countryZones.map(\.zone.timezone)
        for identifier in all {
            XCTAssertNotNil(TimeZone(identifier: identifier), identifier)
        }
    }

    /// Codes are unique within each list, and the country list starts with Canada and the US.
    func testTheCodesAreUnique() {
        XCTAssertEqual(Set(SetupPlaces.provinces.map(\.code)).count, SetupPlaces.provinces.count)
        XCTAssertEqual(Set(SetupPlaces.states.map(\.code)).count, SetupPlaces.states.count)
        XCTAssertEqual(Set(SetupPlaces.countries).count, SetupPlaces.countries.count)
        XCTAssertEqual(Array(SetupPlaces.countries.prefix(2)), ["CA", "US"])
    }

    func testASubdivisionIsNamedInTheAppsLanguage() throws {
        let quebec = try XCTUnwrap(SetupPlaces.provinces.first { $0.code == "QC" })
        XCTAssertEqual(quebec.id, "QC")
        L10nRuntime.locale = .en
        XCTAssertEqual(quebec.name, "Quebec")
        L10nRuntime.locale = .frCA
        XCTAssertEqual(quebec.name, "Québec")
    }

    func testACountryIsNamedInTheAppsLanguage() {
        L10nRuntime.locale = .en
        XCTAssertEqual(SetupPlaces.countryName("DE"), "Germany")
        L10nRuntime.locale = .frCA
        XCTAssertEqual(SetupPlaces.countryName("DE"), "Allemagne")
        XCTAssertEqual(SetupPlaces.countryName("not a code"), "not a code", "an unknown code is shown as given")
    }
}
