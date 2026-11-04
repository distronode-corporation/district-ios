@testable import DistrictAI
import DistrictL10n
import XCTest

/// The line under the dialler's field: where the call rings and the number that is sent.
///
/// ⚠️ THE READING IS ``DialPlan``'S AND `DialPlanTests` PINS IT. What is pinned here is the
/// WORDING, the sentence that lets an operator notice `+41` is Switzerland before Call.
/// ⚠️ `@MainActor` BECAUSE THE COPY HANGS OFF ``DialerModel``, WHICH IS. These are
/// pure functions, but they are `static` members of a MainActor-isolated type, so
/// reaching them from a nonisolated test is a concurrency error rather than a
/// lookup failure — and the compiler words it as neither.
@MainActor
final class DialerDestinationLineTests: XCTestCase {
    /// ⚠️ nil RATHER THAN AN EMPTY STRING while the number is incomplete: the flag already
    /// names the country, and an empty string would reserve space for nothing.
    func testAnIncompleteNumberSaysNothing() {
        XCTAssertNil(DialerModel.destinationLine(DialPlan.read("416555", country: "CA")))
        XCTAssertNil(DialerModel.destinationLine(DialPlan.read("", country: "CA")))
    }

    /// ⛔ AN UNKNOWN CODE SAYS SO PLAINLY RATHER THAN GUESSING. Naming the wrong
    /// country is worse than naming none, because a wrong name is read as
    /// confirmation of a number that is about to be dialled.
    func testUnrecognisedCodeIsAdmittedRatherThanGuessed() {
        XCTAssertEqual(
            DialerModel.destinationLine(DialPlan.read("+999 1234 5678", country: nil)),
            "Unrecognised country code. Check the number before calling."
        )
        XCTAssertEqual(
            DialerModel.destinationLine(DialPlan.read("+9991", country: nil)),
            "Unrecognised country code. Check the number before calling.",
            "said as soon as three digits name no country"
        )
    }

    /// ⛔ THE SENTENCE THAT WOULD HAVE CAUGHT THE BILLED CALL: the country and the whole
    /// number, which is exactly what is sent.
    func testACompleteNumberSaysWhereItRingsAndTheWholeNumber() {
        XCTAssertEqual(
            DialerModel.destinationLine(DialPlan.read("4165550199", country: "CA")),
            "Rings Canada · +1 416 555 0199"
        )
        XCTAssertEqual(
            DialerModel.destinationLine(DialPlan.read("+41 65 550 12 34", country: "CA")),
            "Rings Switzerland · +41 65 550 12 34"
        )
    }

    func testTheFrenchLineNamesTheCountryInFrench() {
        L10nRuntime.withLocale(.frCA) {
            XCTAssertEqual(
                DialerModel.destinationLine(DialPlan.read("+44 20 7946 0958", country: nil)),
                "Pays de destination\u{00A0}: Royaume-Uni · +44 20 7946 0958"
            )
        }
    }

    /// ⛔ A +1 TOLL-FREE NUMBER NAMES NO COUNTRY (Sean, 2026-11-04, GitLab #2): the web's
    /// `ringsNoCountry`, word for word, for every one of the seven codes, typed locally or
    /// with `+1`, whatever +1 country is on the button.
    func testATollFreeNumberSaysItBelongsToNoOneCountry() {
        for area in ["800", "833", "844", "855", "866", "877", "888"] {
            let expected =
                "Rings +1 \(area) 555 0100. This number does not belong to one country. Check it before you call."
            XCTAssertEqual(DialerModel.destinationLine(DialPlan.read("\(area)5550100", country: "CA")), expected)
            XCTAssertEqual(DialerModel.destinationLine(DialPlan.read("1 \(area) 555 0100", country: "US")), expected)
            XCTAssertEqual(DialerModel.destinationLine(DialPlan.read("+1 \(area) 555 0100", country: nil)), expected)
            XCTAssertEqual(DialerModel.destinationLine(DialPlan.read("+1\(area)5550100", country: "JM")), expected)
        }
    }

    func testTheFrenchTollFreeLineIsTheWebsFrench() {
        L10nRuntime.withLocale(.frCA) {
            XCTAssertEqual(
                DialerModel.destinationLine(DialPlan.read("8005550100", country: "CA")),
                "Numéro composé\u{00A0}: +1 800 555 0100. Ce numéro n'appartient à aucun pays en particulier. "
                    + "Vérifiez-le avant d'appeler."
            )
        }
    }

    /// ⛔ THE WEB'S TIMING: from 8 digits with the `1` (the web's `ready`), so a toll-free number
    /// still short of its ten digits already says it has no country, as the bare `+1800…` the web
    /// shows for a number that is not whole. Call stays off. Up to 15 digits; past E.164, nothing.
    func testAPartialTollFreeNumberSaysItFromEightDigits() {
        let partial = DialPlan.read("800 5555", country: "CA")
        XCTAssertEqual(partial.status, .typing)
        XCTAssertNil(partial.e164, "never callable")
        XCTAssertEqual(
            DialerModel.destinationLine(partial),
            "Rings +18005555. This number does not belong to one country. Check it before you call."
        )
        XCTAssertNil(DialerModel.destinationLine(DialPlan.read("800 555", country: "CA")), "seven digits")
        XCTAssertEqual(
            DialerModel.destinationLine(DialPlan.read("+1 888 555 01001", country: nil)),
            "Rings +188855501001. This number does not belong to one country. Check it before you call."
        )
        XCTAssertNil(DialerModel.destinationLine(DialPlan.read("+1 888 555 0100 12345", country: nil)), "16 digits")
    }

    /// ⚠️ ONLY THE SEVEN TOLL-FREE CODES: a geographic +1 number still names its country, and a
    /// toll-free number below 8 digits says nothing yet.
    func testOnlyATollFreeNumberDropsTheCountry() {
        XCTAssertEqual(
            DialerModel.destinationLine(DialPlan.read("+1 416 555 0100", country: nil)),
            "Rings Canada · +1 416 555 0100"
        )
        XCTAssertEqual(
            DialerModel.destinationLine(DialPlan.read("+1 876 555 0100", country: nil)),
            "Rings Jamaica · +1 876 555 0100"
        )
        XCTAssertNil(DialerModel.destinationLine(DialPlan.read("800555", country: "CA")))
        // Outside +1 an 800 is not toll-free: Switzerland's +41 80… still names Switzerland.
        XCTAssertEqual(
            DialerModel.destinationLine(DialPlan.read("+41 800 555 010", country: nil)),
            "Rings Switzerland · +41 80 055 50 10"
        )
    }

    func testTheEmptyFieldSaysHowToType() {
        XCTAssertEqual(DialerModel.entryHint(country: "CA"), "Type the number as you would dial it in Canada.")
        XCTAssertEqual(DialerModel.entryHint(country: nil), "Start with + and the country code, or pick a country.")
    }

    func testDigitsWithNoCountryAskForOneAtOnce() {
        XCTAssertEqual(
            DialerModel.entryProblem(DialPlan.read("4165550199", country: nil), lengthChecked: false),
            "Pick a country, or start with + and the country code."
        )
        XCTAssertNil(DialerModel.entryProblem(DialPlan.read("", country: "CA"), lengthChecked: true))
        XCTAssertNil(DialerModel.entryProblem(DialPlan.read("4165550199", country: "CA"), lengthChecked: true))
    }

    // MARK: - A wrong length waits until the operator stops

    private let wrongLength =
        "That is the wrong number of digits for a number in the country it rings. Check it before you call."

    /// ⛔ NOTHING WHILE TYPING (the web dialler's rule, MR !102). Every ten-digit number
    /// passes through lengths no number has; Call is simply off until it is whole. The old
    /// "too many digits" sentence flashed mid-typing; nothing does now.
    func test_IOS_DIALER_01_aWrongLengthIsNotSaidWhileTyping() {
        for partial in ["4", "41655", "416555019", "+4165550123", "41655501999"] {
            let reading = DialPlan.read(partial, country: "CA")
            XCTAssertNil(reading.e164, partial)
            XCTAssertNil(DialerModel.entryProblem(reading, lengthChecked: false), partial)
        }
    }

    /// ⛔ THE SWITZERLAND CASE, SAID ONCE THE OPERATOR STOPS: eight digits after `+41`, and
    /// every Swiss number has nine. Too many digits reads the same sentence.
    func test_IOS_DIALER_02_aWrongLengthIsSaidOnceChecked() {
        let swiss = DialPlan.read("+4165550123", country: "CA")
        XCTAssertEqual(swiss.iso, "CH")
        XCTAssertNil(swiss.e164, "never callable")
        XCTAssertEqual(DialerModel.entryProblem(swiss, lengthChecked: true), wrongLength)
        XCTAssertEqual(
            DialerModel.entryProblem(DialPlan.read("416555019", country: "CA"), lengthChecked: true),
            wrongLength
        )
        let tooLong = DialPlan.read("41655501999", country: "CA")
        XCTAssertEqual(tooLong.status, .tooLong)
        XCTAssertEqual(DialerModel.entryProblem(tooLong, lengthChecked: true), wrongLength)
    }

    /// ⚠️ NOTHING TO MEASURE IS NOT A WRONG LENGTH: a lone `+`, a lone trunk `0`, or a code no
    /// country uses (which the line above the field already says).
    func test_IOS_DIALER_03_nothingToMeasureIsNotAWrongLength() {
        for entry in ["+", "0", "+99912"] {
            let country: String? = entry == "0" ? "GB" : "CA"
            XCTAssertNil(DialerModel.entryProblem(DialPlan.read(entry, country: country), lengthChecked: true), entry)
        }
    }

    func test_IOS_DIALER_04_theFrenchWrongLength() {
        L10nRuntime.withLocale(.frCA) {
            XCTAssertEqual(
                DialerModel.entryProblem(DialPlan.read("+4165550123", country: "CA"), lengthChecked: true),
                "Ce numéro n'a pas le bon nombre de chiffres pour le pays de destination. Vérifiez-le avant d'appeler."
            )
        }
    }
}

/// The App-target half of the emergency hand-off: the sentence itself.
///
/// ⛔ `DialEntry` (the core) DECIDES, THIS SAYS IT. The detection is pinned on the cheap
/// Linux runner by `EmergencyNumberTests` and its use here by `DialPlanTests`; what is
/// pinned here is whether the copy names the Phone app, which is the half that makes it a
/// hand-off rather than a refusal.
@MainActor
final class EmergencyCopyTests: XCTestCase {
    private func problem(_ entry: String, checked: Bool = false) -> String? {
        DialerModel.entryProblem(DialPlan.read(entry, country: "CA"), lengthChecked: checked)
    }

    func testTheEmergencyLineNamesThePhoneApp() {
        let line = problem("911")
        XCTAssertNotNil(line)
        XCTAssertTrue(line?.contains("Phone app") == true, "a bare refusal strands the caller")
    }

    /// ⛔ IT MUST NOT READ AS A CORRECTABLE MISTAKE. Telling somebody dialling an
    /// emergency number to add a country code is the failure this pins.
    func testTheEmergencyLineNeverAsksForACountryCode() {
        let line = problem("911") ?? ""
        XCTAssertFalse(line.lowercased().contains("country code"))
        XCTAssertFalse(line.lowercased().contains("digits"))
    }

    /// ⚠️ SAID AT ONCE, NOT HELD FOR THE LENGTH CHECK: it is not a length.
    func test_IOS_DIALER_05_itIsSaidWhileTypingAndDistinctFromEveryOtherRefusal() {
        let emergency = problem("911")
        XCTAssertNotNil(emergency)
        XCTAssertEqual(problem("911", checked: true), emergency)
        XCTAssertNotEqual(
            DialerModel.entryProblem(DialPlan.read("4165550199", country: nil), lengthChecked: true),
            emergency
        )
        XCTAssertNotEqual(problem("+4165550123", checked: true), emergency)
    }
}
