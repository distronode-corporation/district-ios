@testable import DistrictAI
import DistrictModel
import Foundation
import XCTest

/// What step 1 and step 4 read out of the stored business facts and write back: each reader
/// against missing, malformed and partial blobs, each writer's omissions, and the validators at
/// their limits.
final class SetupFactsReadWriteTests: XCTestCase {
    // MARK: - Reading services and FAQs

    func testNoFactsReadAsNothing() {
        XCTAssertEqual(SetupFacts.services(nil), [])
        XCTAssertEqual(SetupFacts.faqs(nil), [])
        XCTAssertEqual(SetupFacts.address(nil), SetupAddressDraft())
        XCTAssertEqual(SetupFacts.what(nil), "")
    }

    /// A key holding the wrong shape reads as absent, never as a crash or a guessed row.
    func testWrongShapesReadAsAbsent() {
        let facts = WireJSON.object([
            "services": .string("Cleaning"),
            "faqs": .object(["question": .string("Q")]),
            "address": .array([]),
        ])
        XCTAssertEqual(SetupFacts.services(facts), [])
        XCTAssertEqual(SetupFacts.faqs(facts), [])
        XCTAssertEqual(SetupFacts.address(facts), SetupAddressDraft())
    }

    /// ⚠️ ONLY AN EXPLICIT `true` IS ENABLED: a missing flag, a string "true" or a 1 is not.
    func testARowIsEnabledOnlyByTrue() {
        let facts = WireJSON.object([
            "services": .array([
                .object(["name": .string("A"), "enabled": .bool(true)]),
                .object(["name": .string("B")]),
                .object(["name": .string("C"), "enabled": .string("true")]),
                .object(["name": .string("D"), "enabled": .integer(1)]),
                .object(["price": .string("$5")]),
            ]),
        ])
        XCTAssertEqual(SetupFacts.services(facts), [
            SetupServiceDraft(name: "A", price: "", enabled: true),
            SetupServiceDraft(name: "B", price: "", enabled: false),
            SetupServiceDraft(name: "C", price: "", enabled: false),
            SetupServiceDraft(name: "D", price: "", enabled: false),
            SetupServiceDraft(name: "", price: "$5", enabled: false),
        ])
    }

    func testFaqsReadEveryField() {
        let facts = WireJSON.object([
            "faqs": .array([
                .object(["question": .string("Parking?"), "answer": .string("Out back."), "enabled": .bool(true)]),
                .object(["answer": .integer(3)]),
            ]),
        ])
        XCTAssertEqual(SetupFacts.faqs(facts), [
            SetupFaqDraft(question: "Parking?", answer: "Out back.", enabled: true),
            SetupFaqDraft(question: "", answer: "", enabled: false),
        ])
    }

    func testAPartialAddressKeepsWhatIsThere() {
        let facts = WireJSON.object([
            "address": .object(["city": .string("Montréal"), "country": .string("CA")]),
        ])
        XCTAssertEqual(SetupFacts.address(facts), SetupAddressDraft(city: "Montréal", country: "CA"))
    }

    // MARK: - What the business does

    /// Found by the web's question in either language; any other question is not it.
    func testWhatIsFoundByEitherLanguagesQuestion() {
        let english = WireJSON.object([
            "faqs": .array([
                .object(["question": .string("Parking?"), "answer": .string("Out back.")]),
                .object(["question": .string("What does the business do?"), "answer": .string("Dental care.")]),
            ]),
        ])
        XCTAssertEqual(SetupFacts.what(english), "Dental care.")
        let french = WireJSON.object([
            "faqs": .array([
                .object(["question": .string("Que fait l'entreprise?"), "answer": .string("Soins dentaires.")]),
            ]),
        ])
        XCTAssertEqual(SetupFacts.what(french), "Soins dentaires.")
        let near = WireJSON.object([
            "faqs": .array([
                .object(["question": .string("what does the business do?"), "answer": .string("x")]),
            ]),
        ])
        XCTAssertEqual(SetupFacts.what(near), "", "matched byte for byte, as the web reads it back")
    }

    // MARK: - Reading hours

    func testHoursReadEachDaysThreeStates() {
        let hours = SetupFacts.hours(.object([
            "mon": .array([
                .object(["open": .string("09:00"), "close": .string("17:00")]),
            ]),
            "tue": .string("closed"),
            "wed": .array([]),
            "thu": .string("open"),
        ]))
        XCTAssertEqual(hours[.mon], SetupDayDraft(state: .open, intervals: [SetupInterval(open: 540, close: 1020)]))
        XCTAssertEqual(hours[.tue], SetupDayDraft(state: .closed, intervals: []))
        XCTAssertEqual(hours[.wed], SetupDayDraft(state: .notSet, intervals: []), "an empty list says nothing")
        XCTAssertEqual(hours[.thu], SetupDayDraft(state: .notSet, intervals: []), "an unknown word says nothing")
        XCTAssertEqual(hours[.sun], SetupDayDraft(state: .notSet, intervals: []))
        XCTAssertEqual(hours.count, SetupWeekday.allCases.count, "every day has a draft")
    }

    /// An interval with an unreadable time is dropped; the day stays open with the rest.
    func testAnUnreadableIntervalIsDropped() {
        let hours = SetupFacts.hours(.object([
            "fri": .array([
                .object(["open": .string("9:00"), "close": .string("12:00")]),
                .object(["open": .string("13:00"), "close": .string("24:00")]),
                .object(["open": .string("13:00")]),
            ]),
        ]))
        XCTAssertEqual(hours[.fri], SetupDayDraft(state: .open, intervals: [SetupInterval(open: 780, close: 1440)]))
    }

    func testIntervalTimesAtTheirEdges() {
        XCTAssertEqual(SetupInterval.minutes("00:00"), 0)
        XCTAssertEqual(SetupInterval.minutes("23:59"), 1439)
        XCTAssertEqual(SetupInterval.minutes("24:00"), 1440, "midnight at the end of the day")
        for bad in [nil, "", "24:01", "25:00", "9:00", "09:60", "0900", "09:00 ", "ab:cd", "-1:00"] {
            XCTAssertNil(SetupInterval.minutes(bad), "\(bad ?? "nil")")
        }
        XCTAssertEqual(SetupInterval.text(0), "00:00")
        XCTAssertEqual(SetupInterval.text(545), "09:05")
        XCTAssertEqual(SetupInterval.text(1440), "24:00")
    }

    // MARK: - Writing

    func testEmptyListsWriteNull() {
        XCTAssertEqual(SetupFacts.json(services: []), .null)
        XCTAssertEqual(SetupFacts.json(faqs: []), .null)
        XCTAssertEqual(SetupFacts.json(address: SetupAddressDraft(line1: "  ", city: "\n")), .null)
        XCTAssertEqual(SetupFacts.json(hours: [:]), .null)
        XCTAssertEqual(
            SetupFacts.json(hours: [
                .mon: SetupDayDraft(state: .notSet, intervals: [SetupInterval.standard]),
            ]),
            .null,
            "a day not set is not written, even with intervals left in its draft"
        )
    }

    /// Trimmed, and a blank price left out rather than written as "".
    func testServicesAreTrimmedAndABlankPriceOmitted() {
        let json = SetupFacts.json(services: [
            SetupServiceDraft(name: "  Cleaning ", price: " $120 ", enabled: true),
            SetupServiceDraft(name: "Whitening", price: "   ", enabled: false),
        ])
        XCTAssertEqual(json, .array([
            .object(["name": .string("Cleaning"), "price": .string("$120"), "enabled": .bool(true)]),
            .object(["name": .string("Whitening"), "enabled": .bool(false)]),
        ]))
    }

    func testFaqsAreTrimmed() {
        XCTAssertEqual(
            SetupFacts.json(faqs: [SetupFaqDraft(question: " Parking? ", answer: "\tOut back.\n", enabled: false)]),
            .array([
                .object([
                    "question": .string("Parking?"), "answer": .string("Out back."), "enabled": .bool(false),
                ]),
            ])
        )
    }

    /// City and country always written (the country upper-cased); the optional parts only when filled.
    func testAnAddressWritesItsOptionalPartsOnlyWhenFilled() {
        XCTAssertEqual(
            SetupFacts.json(address: SetupAddressDraft(line1: " ", city: " Toronto ", region: "ON", country: "ca")),
            .object(["city": .string("Toronto"), "country": .string("CA"), "region": .string("ON")])
        )
    }

    /// An open day's intervals are written in time order; a closed day as the word.
    func testHoursAreWrittenInTimeOrder() {
        let json = SetupFacts.json(hours: [
            .mon: SetupDayDraft(state: .open, intervals: [
                SetupInterval(open: 780, close: 1020), SetupInterval(open: 540, close: 720),
            ]),
            .sun: SetupDayDraft(state: .closed, intervals: [SetupInterval.standard]),
        ])
        XCTAssertEqual(json, .object([
            "mon": .array([
                .object(["open": .string("09:00"), "close": .string("12:00")]),
                .object(["open": .string("13:00"), "close": .string("17:00")]),
            ]),
            "sun": .string("closed"),
        ]))
    }

    /// Hours read back as they were written.
    func testHoursRoundTrip() {
        let drafts: [SetupWeekday: SetupDayDraft] = [
            .mon: SetupDayDraft(state: .open, intervals: [SetupInterval(open: 0, close: 1440)]),
            .tue: SetupDayDraft(state: .closed, intervals: []),
        ]
        let back = SetupFacts.hours(SetupFacts.json(hours: drafts))
        XCTAssertEqual(back[.mon], drafts[.mon])
        XCTAssertEqual(back[.tue], drafts[.tue])
        XCTAssertEqual(back[.wed]?.state, .notSet)
    }

    // MARK: - Validating

    func testAServiceAtItsLimits() {
        let name = String(repeating: "a", count: SetupFacts.Limit.serviceName)
        let price = String(repeating: "9", count: SetupFacts.Limit.servicePrice)
        XCTAssertTrue(SetupFacts.isValid(SetupServiceDraft(name: name, price: price, enabled: true)))
        XCTAssertFalse(SetupFacts.isValid(SetupServiceDraft(name: name + "a", price: "", enabled: true)))
        XCTAssertFalse(SetupFacts.isValid(SetupServiceDraft(name: "A", price: price + "9", enabled: true)))
        XCTAssertFalse(SetupFacts.isValid(SetupServiceDraft(name: "   ", price: "", enabled: true)))
    }

    func testAFaqNeedsBothHalvesWithinTheirLimits() {
        let question = String(repeating: "q", count: SetupFacts.Limit.faqQuestion)
        let answer = String(repeating: "a", count: SetupFacts.Limit.faqAnswer)
        XCTAssertTrue(SetupFacts.isValid(SetupFaqDraft(question: question, answer: answer, enabled: true)))
        XCTAssertFalse(SetupFacts.isValid(SetupFaqDraft(question: question + "q", answer: "a", enabled: true)))
        XCTAssertFalse(SetupFacts.isValid(SetupFaqDraft(question: "q", answer: answer + "a", enabled: true)))
        XCTAssertFalse(SetupFacts.isValid(SetupFaqDraft(question: "q", answer: " ", enabled: true)))
        XCTAssertFalse(SetupFacts.isValid(SetupFaqDraft(question: "", answer: "a", enabled: true)))
    }

    /// An empty address is valid (nothing to say); a started one needs a city and a two-letter country.
    func testAnAddressIsEmptyOrComplete() {
        XCTAssertTrue(SetupFacts.isValid(SetupAddressDraft()))
        XCTAssertTrue(SetupFacts.isValid(SetupAddressDraft(city: "Toronto", country: " ca ")))
        XCTAssertFalse(SetupFacts.isValid(SetupAddressDraft(line1: "100 Example Street")))
        XCTAssertFalse(SetupFacts.isValid(SetupAddressDraft(city: "Toronto", country: "CAN")))
        XCTAssertFalse(SetupFacts.isValid(SetupAddressDraft(city: "Toronto", country: "C1")))
        XCTAssertFalse(SetupFacts.isValid(SetupAddressDraft(city: "", country: "CA")))
        let long = String(repeating: "x", count: SetupFacts.Limit.addressPart + 1)
        XCTAssertFalse(SetupFacts.isValid(SetupAddressDraft(city: long, country: "CA")))
        XCTAssertFalse(SetupFacts.isValid(SetupAddressDraft(city: "T", region: long, country: "CA")))
        XCTAssertFalse(SetupFacts.isValid(SetupAddressDraft(
            line1: String(repeating: "x", count: SetupFacts.Limit.addressLine + 1), city: "T", country: "CA"
        )))
        XCTAssertFalse(SetupFacts.isValid(SetupAddressDraft(
            city: "T", postalCode: String(repeating: "1", count: SetupFacts.Limit.postalCode + 1), country: "CA"
        )))
    }

    func testADaysIntervals() {
        func open(_ intervals: [(Int, Int)]) -> SetupDayDraft {
            SetupDayDraft(state: .open, intervals: intervals.map { SetupInterval(open: $0.0, close: $0.1) })
        }
        XCTAssertTrue(SetupFacts.isValid(SetupDayDraft(state: .closed, intervals: [])))
        XCTAssertTrue(SetupFacts.isValid(SetupDayDraft(state: .notSet, intervals: [])))
        XCTAssertFalse(SetupFacts.isValid(open([])), "open with no hours")
        XCTAssertTrue(SetupFacts.isValid(open([(780, 1020), (540, 720)])), "out of order is sorted first")
        XCTAssertTrue(SetupFacts.isValid(open([(540, 720), (720, 1020)])), "touching is not overlapping")
        XCTAssertFalse(SetupFacts.isValid(open([(540, 780), (720, 1020)])), "overlapping")
        XCTAssertFalse(SetupFacts.isValid(open([(540, 540)])), "closes as it opens")
        XCTAssertFalse(SetupFacts.isValid(open([(600, 540)])), "closes before it opens")
        XCTAssertTrue(SetupFacts.isValid(open([(0, 60), (60, 120), (120, 180), (180, 240)])))
        XCTAssertFalse(SetupFacts.isValid(open([(0, 60), (60, 120), (120, 180), (180, 240), (240, 300)])), "five")
    }

    // MARK: - Appending a lookup's rows

    /// Duplicates are matched trimmed and case-blind, and the cap holds.
    func testAppendingSkipsDuplicatesAndStopsAtTheCap() {
        let current: [WireJSON] = [.object(["name": .string("Cleaning")])]
        let incoming: [WireJSON] = [
            .object(["name": .string(" cleaning ")]),
            .object(["name": .string("Whitening")]),
            .object(["name": .string("WHITENING")]),
            .object(["name": .string("Braces")]),
        ]
        XCTAssertEqual(
            SetupFacts.appending(incoming, to: current, key: "name", max: 10),
            current + [.object(["name": .string("Whitening")]), .object(["name": .string("Braces")])]
        )
        XCTAssertEqual(SetupFacts.appending(incoming, to: current, key: "name", max: 2).count, 2)
        XCTAssertEqual(SetupFacts.appending(incoming, to: current, key: "name", max: 1), current)
    }

    func testTheWeekdaysAreNamedInTheAppsLanguage() {
        XCTAssertEqual(SetupWeekday.allCases.map(\.id), ["mon", "tue", "wed", "thu", "fri", "sat", "sun"])
        XCTAssertEqual(Set(SetupWeekday.allCases.map(\.name)).count, 7, "seven different names")
    }
}
