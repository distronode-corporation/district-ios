@testable import DistrictAI
import DistrictL10n
import XCTest

/// The working-hours time fields: « 9 h » on a French screen, `HH:MM` in the draft.
///
/// ⛔ THE BUG: Edit working hours showed the stored « 09:00 » in French.
final class SchedulingTimeFieldTests: XCTestCase {
    private typealias Field = SchedulingTimeFieldText

    func testFrenchFieldsShowTheHouseStyle() {
        L10nRuntime.withLocale(.frCA) {
            XCTAssertEqual(Field.text(forStored: "09:00"), "9 h")
            XCTAssertEqual(Field.text(forStored: "09:30"), "9 h 30")
            XCTAssertEqual(Field.text(forStored: "17:00"), "17 h")
            // The placeholders the two editors pass.
            XCTAssertEqual(Field.text(forStored: SchedulingWorkingHours.defaultStart), "9 h")
            XCTAssertEqual(Field.text(forStored: SchedulingWorkingHours.defaultEnd), "17 h")
        }
    }

    /// ⚠️ ENGLISH IS UNCHANGED: the stored value, zero-padded.
    func testEnglishFieldsShowTheStoredValue() {
        L10nRuntime.withLocale(.en) {
            XCTAssertEqual(Field.text(forStored: "09:00"), "09:00")
            XCTAssertEqual(Field.text(forStored: "09:30"), "09:30")
            XCTAssertEqual(Field.text(forStored: "17:00"), "17:00")
        }
    }

    func testATypedTimeIsStoredAsHHMM() {
        for (typed, stored) in [
            ("9 h", "09:00"), ("9 h 30", "09:30"), ("9h30", "09:30"),
            ("9:30", "09:30"), ("09:30", "09:30"), ("17 h", "17:00"),
        ] {
            XCTAssertEqual(Field.stored(fromTyped: typed), stored, typed)
        }
    }

    /// ⛔ ANYTHING ELSE IS KEPT AS TYPED AND REFUSED WITH THE CATALOG'S ERROR, so the row
    /// says what is wrong with what is on screen and Save stays off.
    func testSomethingThatIsNotATimeIsRefusedWithTheCatalogError() {
        for typed in ["25:00", "9 h 75", "9 h 5", "neuf", "9"] {
            let stored = Field.stored(fromTyped: typed)
            XCTAssertEqual(stored, typed)
            let range = SchedulingHoursDraftRange(ruleId: nil, start: stored, end: "17:00")
            L10nRuntime.withLocale(.frCA) {
                XCTAssertEqual(
                    SchedulingWorkingHours.errors(in: [range]),
                    // Non-breaking spaces, so « 13 h 30 » never splits across lines.
                    ["Entrez une heure, par exemple 9\u{00A0}h ou 13\u{00A0}h\u{00A0}30."],
                    typed
                )
            }
            L10nRuntime.withLocale(.en) {
                XCTAssertEqual(SchedulingWorkingHours.errors(in: [range]), ["Enter a time as HH:MM."], typed)
            }
        }
    }

    /// The custom-hours override takes the same rule.
    func testTheOverrideFormRefusesAClockThatDoesNotExist() {
        var form = SchedulingOverrideForm()
        form.reason = "custom_hours"
        form.date = "2026-11-02"
        form.start = Field.stored(fromTyped: "9 h 30")
        XCTAssertNil(form.error)
        form.end = Field.stored(fromTyped: "24 h")
        L10nRuntime.withLocale(.en) {
            XCTAssertEqual(form.error, "Enter a time as HH:MM.")
        }
    }
}
