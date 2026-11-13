import DistrictModel
import Foundation

/// The business facts the receptionist answers from, read out of ``WireJSON`` into the forms
/// step 1 and step 4 edit, and written back.
///
/// ⛔ THE LIMITS ARE THE SERVICE'S (`BUSINESS_FACTS_LIMITS` in `business-facts.ts`), so a
/// save this refuses is one the route would refuse too. The route validates again.
///
/// ⚠️ A SECTION PRESENT IN A PATCH REPLACES THE STORED ONE WHOLE, a list is sent in full, and
/// an explicit null clears it; an absent section is left alone
/// (``DistrictNetwork/DistrictEndpoints/districtSetupPatch(workspaceId:steps:businessFacts:)``).
enum SetupFacts {
    enum Limit {
        static let addressLine = 200
        static let addressPart = 100
        static let postalCode = 20
        static let intervalsPerDay = 4
        static let services = 50
        static let serviceName = 120
        static let servicePrice = 40
        static let faqs = 50
        static let faqQuestion = 300
        static let faqAnswer = 1000
    }

    // MARK: - Reading

    static func services(_ facts: WireJSON?) -> [SetupServiceDraft] {
        (facts?["services"]?.arrayValue ?? []).map { row in
            SetupServiceDraft(
                name: row["name"]?.stringValue ?? "",
                price: row["price"]?.stringValue ?? "",
                enabled: row["enabled"] == .bool(true)
            )
        }
    }

    static func faqs(_ facts: WireJSON?) -> [SetupFaqDraft] {
        (facts?["faqs"]?.arrayValue ?? []).map { row in
            SetupFaqDraft(
                question: row["question"]?.stringValue ?? "",
                answer: row["answer"]?.stringValue ?? "",
                enabled: row["enabled"] == .bool(true)
            )
        }
    }

    static func address(_ facts: WireJSON?) -> SetupAddressDraft {
        let address = facts?["address"]
        return SetupAddressDraft(
            line1: address?["line1"]?.stringValue ?? "",
            city: address?["city"]?.stringValue ?? "",
            region: address?["region"]?.stringValue ?? "",
            postalCode: address?["postalCode"]?.stringValue ?? "",
            country: address?["country"]?.stringValue ?? ""
        )
    }

    /// Every weekday, `notSet` where the stored hours say nothing.
    static func hours(_ weeklyHours: WireJSON?) -> [SetupWeekday: SetupDayDraft] {
        var out: [SetupWeekday: SetupDayDraft] = [:]
        for day in SetupWeekday.allCases {
            let stored = weeklyHours?[day.rawValue]
            if stored?.stringValue == "closed" {
                out[day] = SetupDayDraft(state: .closed, intervals: [])
            } else if let rows = stored?.arrayValue, !rows.isEmpty {
                let intervals = rows.compactMap { row -> SetupInterval? in
                    guard let open = SetupInterval.minutes(row["open"]?.stringValue),
                          let close = SetupInterval.minutes(row["close"]?.stringValue) else { return nil }
                    return SetupInterval(open: open, close: close)
                }
                out[day] = SetupDayDraft(state: .open, intervals: intervals)
            } else {
                out[day] = SetupDayDraft(state: .notSet, intervals: [])
            }
        }
        return out
    }

    /// The web's "what you do" line: the answer to the question step 1 writes, in either language.
    static func what(_ facts: WireJSON?) -> String {
        let rows = facts?["faqs"]?.arrayValue ?? []
        let match = rows.first { SetupWire.whatQuestions.contains($0["question"]?.stringValue ?? "") }
        return match?["answer"]?.stringValue ?? ""
    }

    // MARK: - Writing

    static func json(services: [SetupServiceDraft]) -> WireJSON {
        guard !services.isEmpty else { return .null }
        return .array(services.map { service in
            var row: [String: WireJSON] = [
                "name": .string(service.name.trimmed),
                "enabled": .bool(service.enabled),
            ]
            if !service.price.trimmed.isEmpty {
                row["price"] = .string(service.price.trimmed)
            }
            return .object(row)
        })
    }

    static func json(faqs: [SetupFaqDraft]) -> WireJSON {
        guard !faqs.isEmpty else { return .null }
        return .array(faqs.map { faq in
            .object([
                "question": .string(faq.question.trimmed),
                "answer": .string(faq.answer.trimmed),
                "enabled": .bool(faq.enabled),
            ])
        })
    }

    /// ⚠️ AN EMPTY ADDRESS IS A CLEAR (`null`), and a blank optional part is left out, never
    /// sent as "".
    static func json(address: SetupAddressDraft) -> WireJSON {
        guard !address.isEmpty else { return .null }
        var row: [String: WireJSON] = [
            "city": .string(address.city.trimmed),
            "country": .string(address.country.trimmed.uppercased()),
        ]
        let optional = [("line1", address.line1), ("region", address.region), ("postalCode", address.postalCode)]
        for (key, value) in optional where !value.trimmed.isEmpty {
            row[key] = .string(value.trimmed)
        }
        return .object(row)
    }

    /// ⚠️ A DAY LEFT "NOT SET" IS ABSENT, WHICH IS NOT "CLOSED": the receptionist says nothing
    /// about an absent day. No day set at all clears the section.
    static func json(hours: [SetupWeekday: SetupDayDraft]) -> WireJSON {
        var out: [String: WireJSON] = [:]
        for day in SetupWeekday.allCases {
            guard let draft = hours[day] else { continue }
            switch draft.state {
            case .notSet:
                continue
            case .closed:
                out[day.rawValue] = .string("closed")
            case .open:
                out[day.rawValue] = .array(draft.intervals.sorted { $0.open < $1.open }.map { interval in
                    .object([
                        "open": .string(SetupInterval.text(interval.open)),
                        "close": .string(SetupInterval.text(interval.close)),
                    ])
                })
            }
        }
        return out.isEmpty ? .null : .object(out)
    }

    /// Appends `incoming` rows to `current` by a case-insensitive key, skipping duplicates, up
    /// to `max` (the web's `appendUnique`).
    ///
    /// ⛔ THE STORED ROWS GO BACK AS THEY CAME, every key they carry, because the section is
    /// replaced whole; and the incoming ones keep the lookup's `enabled: false`.
    static func appending(_ incoming: [WireJSON], to current: [WireJSON], key: String, max: Int) -> [WireJSON] {
        let normalise = { (row: WireJSON) in (row[key]?.stringValue ?? "").trimmed.lowercased() }
        var seen = Set(current.map(normalise))
        var out = current
        for row in incoming {
            guard out.count < max else { break }
            guard seen.insert(normalise(row)).inserted else { continue }
            out.append(row)
        }
        return out
    }

    // MARK: - Checking

    static func isValid(_ service: SetupServiceDraft) -> Bool {
        let name = service.name.trimmed
        return !name.isEmpty && name.count <= Limit.serviceName && service.price.trimmed.count <= Limit.servicePrice
    }

    static func isValid(_ faq: SetupFaqDraft) -> Bool {
        let question = faq.question.trimmed
        let answer = faq.answer.trimmed
        return !question.isEmpty && question.count <= Limit.faqQuestion
            && !answer.isEmpty && answer.count <= Limit.faqAnswer
    }

    /// Empty, or at least a city and a two-letter country code, each within its limit.
    static func isValid(_ address: SetupAddressDraft) -> Bool {
        if address.isEmpty {
            return true
        }
        let country = address.country.trimmed.uppercased()
        return !address.city.trimmed.isEmpty
            && country.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil
            && address.line1.trimmed.count <= Limit.addressLine
            && address.city.trimmed.count <= Limit.addressPart
            && address.region.trimmed.count <= Limit.addressPart
            && address.postalCode.trimmed.count <= Limit.postalCode
    }

    /// One to four periods, each closing after it opens, none overlapping (`DayHoursSchema`).
    static func isValid(_ day: SetupDayDraft) -> Bool {
        guard day.state == .open else { return true }
        guard !day.intervals.isEmpty, day.intervals.count <= Limit.intervalsPerDay else { return false }
        let sorted = day.intervals.sorted { $0.open < $1.open }
        for (index, interval) in sorted.enumerated() {
            guard interval.close > interval.open else { return false }
            if index > 0, interval.open < sorted[index - 1].close {
                return false
            }
        }
        return true
    }
}

struct SetupServiceDraft: Equatable, Identifiable {
    let id = UUID()
    var name: String
    var price: String
    var enabled: Bool

    static func == (lhs: SetupServiceDraft, rhs: SetupServiceDraft) -> Bool {
        lhs.name == rhs.name && lhs.price == rhs.price && lhs.enabled == rhs.enabled
    }
}

struct SetupFaqDraft: Equatable, Identifiable {
    let id = UUID()
    var question: String
    var answer: String
    var enabled: Bool

    static func == (lhs: SetupFaqDraft, rhs: SetupFaqDraft) -> Bool {
        lhs.question == rhs.question && lhs.answer == rhs.answer && lhs.enabled == rhs.enabled
    }
}

struct SetupAddressDraft: Equatable {
    var line1 = ""
    var city = ""
    var region = ""
    var postalCode = ""
    var country = ""

    var isEmpty: Bool {
        [line1, city, region, postalCode, country].allSatisfy(\.trimmed.isEmpty)
    }
}

/// `WEEKDAYS`, Monday first, as the service keys them.
enum SetupWeekday: String, CaseIterable, Identifiable {
    case mon, tue, wed, thu, fri, sat, sun

    var id: String {
        rawValue
    }

    var name: String {
        switch self {
        case .mon: SetupCopy.callersDayMon
        case .tue: SetupCopy.callersDayTue
        case .wed: SetupCopy.callersDayWed
        case .thu: SetupCopy.callersDayThu
        case .fri: SetupCopy.callersDayFri
        case .sat: SetupCopy.callersDaySat
        case .sun: SetupCopy.callersDaySun
        }
    }
}

enum SetupDayState: CaseIterable {
    case notSet
    case closed
    case open
}

struct SetupDayDraft: Equatable {
    var state: SetupDayState
    var intervals: [SetupInterval]
}

/// One opening period, in minutes after midnight. `close` may be 1440 ("24:00").
struct SetupInterval: Equatable, Identifiable {
    let id = UUID()
    var open: Int
    var close: Int

    static let standard = SetupInterval(open: 9 * 60, close: 17 * 60)

    static func == (lhs: SetupInterval, rhs: SetupInterval) -> Bool {
        lhs.open == rhs.open && lhs.close == rhs.close
    }

    /// "09:30" is 570; "24:00" is 1440; anything else nil.
    static func minutes(_ text: String?) -> Int? {
        guard let text else { return nil }
        if text == "24:00" {
            return 24 * 60
        }
        guard text.range(of: "^([01][0-9]|2[0-3]):[0-5][0-9]$", options: .regularExpression) != nil,
              let hours = Int(text.prefix(2)), let minutes = Int(text.suffix(2)) else { return nil }
        return hours * 60 + minutes
    }

    static func text(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

extension String {
    /// Trimmed of spaces and newlines at both ends, as the service's schemas trim.
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
