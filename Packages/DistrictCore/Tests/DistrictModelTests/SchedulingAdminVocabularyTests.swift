import DistrictModel
import Foundation
import XCTest

/// ⛔ THE SEVEN RAW VALUES ARE EMBEDDED A SECOND TIME RATHER THAN DERIVED FROM
/// `allCases`, for the reason `SchedulingAdminOpTests` states about its own 75: a
/// value renamed on the server is a **400 `invalid_params`** and not a compile
/// error, so a test that read the enum back would assert that the code equals
/// itself and would pass through any rename.
final class SchedulingAdminVocabularyTests: XCTestCase {
    /// The catalog's `LOCATION_TYPES`, copied from the server's op catalog by hand.
    private static let wireValues = [
        "google_meet",
        "teams",
        "custom_video",
        "phone",
        "in_person",
        "link",
        "livekit",
    ]

    func testEveryLocationTypeCarriesTheServersSpelling() {
        XCTAssertEqual(SchedulingLocationType.allCases.map(\.rawValue), Self.wireValues)
    }

    /// ⛔ `zoom` IS ABSENT DELIBERATELY AND THE ABSENCE IS THE ASSERTION. The fork's
    /// own DB CHECK accepts it, so nothing downstream would refuse it; the catalog
    /// is what withholds it, and a case added here would produce a picker whose
    /// eighth entry is a 400 on every save.
    func testZoomIsNotOffered() {
        XCTAssertNil(SchedulingLocationType(rawValue: "zoom"))
        XCTAssertEqual(SchedulingLocationType.allCases.count, 7)
    }

    /// ⛔ THE `URL_LOCATION_TYPES` SUBSET, WHICH IS EXACTLY TWO. The catalog refuses
    /// a non-URL `location_value` only for these, and only when both fields are
    /// sent; a client that validated the other five would refuse every phone
    /// consultation in the product.
    func testExactlyTwoTypesRefuseANonURLValue() {
        let urlKinds = SchedulingLocationType.allCases.filter(\.refusesANonURLValue)
        XCTAssertEqual(urlKinds.map(\.rawValue), ["custom_video", "link"])
    }

    /// ⚠️ THE FULL MAP, ARM BY ARM. `valueKind` is what turns a polymorphic column
    /// into something an editor can draw a field for, and the three `generated`
    /// kinds are the ones where the correct field is NO field.
    func testEveryLocationTypeClassifiesItsValue() {
        let expected: [SchedulingLocationType: SchedulingLocationValueKind] = [
            .googleMeet: .generated,
            .teams: .generated,
            .livekit: .generated,
            .customVideo: .url,
            .link: .url,
            .phone: .phone,
            .inPerson: .address,
        ]
        for type in SchedulingLocationType.allCases {
            XCTAssertEqual(type.valueKind, expected[type], type.rawValue)
        }
    }

    /// ⚠️ nil FOR A VALUE THIS BUILD DOES NOT KNOW, and nil for no value at all. An
    /// event type created before the allowlist narrowed is still the event type the
    /// scheduler serves today; failing the read to report one field would lose the
    /// whole row.
    func testKnownAnswersNilForAnUnknownOrAbsentValue() {
        XCTAssertNil(SchedulingLocationType.known(nil))
        XCTAssertNil(SchedulingLocationType.known("zoom"))
        XCTAssertEqual(SchedulingLocationType.known("in_person"), .inPerson)
    }
}
