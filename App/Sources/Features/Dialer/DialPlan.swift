import DistrictCall
import DistrictL10n
import Foundation

/// Reading what the operator types into the dialler, in a country: dialler design A.
///
/// ⛔ THE COUNTRY IS ALWAYS ON SCREEN BEFORE THE CALL, AND THAT IS WHAT MAKES IT SAFE TO
/// BUILD THE NUMBER HERE. The billed call this screen exists to prevent was a Canadian
/// mobile typed as `+4165550123`, which is `+41`, SWITZERLAND. Until this type the app
/// sent the text exactly as typed and only named the country beside it. Now the number is
/// typed the local way under a flag and calling code the operator can see, and the line
/// under the field says "Rings Canada · +1 416 555 0199" before Call: the whole
/// international number is disclosed, so nothing is sent that was not shown.
///
/// ⚠️ THE SERVER STILL NORMALISES ITS OWN COPY. What leaves here is E.164 (`+`, the
/// calling code, the national number), which `normalizePhoneNumber` passes through
/// unchanged, so the Do-Not-Call check and the dial run against the number that was shown.
///
/// ⛔ PURE. A function of the text and a country, with no I/O and no clock, so every rule
/// is pinned by `DialPlanTests` without a simulator session.
///
/// ⚠️ IN THE APP TARGET RATHER THAN DistrictCore, FOR NOW. CONTRIBUTING.md puts testable
/// logic in the package; moving it is a core release plus a pin bump, and this is the
/// first cut of the design. `DialEntry` (the core) still owns the emergency list and the
/// E.164 digit floor and ceiling, and this file reads them from there.
enum DialPlan {
    /// What one entry is, in the order the screen acts on it.
    enum Status: Equatable {
        /// Nothing typed.
        case empty
        /// A number on its way: too few digits yet, or a `+` code not finished.
        case typing
        /// Dialable: ``Reading/e164`` is set.
        case ready
        /// An emergency short code. ⛔ Refused as before: the Phone app is the remedy.
        case emergency
        /// More digits than the country's numbers have, or than E.164 allows.
        case tooLong
        /// Digits with no country to read them in and no `+`.
        case needsCountry
    }

    /// One entry, read.
    struct Reading: Equatable {
        var status: Status
        /// The country the number rings, or nil: none chosen, or a `+` code no country
        /// in ``countries`` uses.
        var iso: String?
        /// The calling code, without `+`, or empty.
        var callingCode = ""
        /// The national significant number: no trunk `0` or `1`, no calling code.
        var nationalNumber = ""
        /// What the field shows: the local form, as it would be dialled in ``iso``.
        var national = ""
        /// The number as the world dials it, grouped: `+1 416 555 0199`.
        var international = ""
        /// True when the entry named its own country (`+`, `011`, `00`).
        var namedItsCountry = false
        /// What is sent to the dial API. Set exactly when ``status`` is `.ready`.
        var e164: String?
    }

    // MARK: - Reading

    /// Read `raw` in `country` (an ISO 3166 code, nil when none is chosen).
    ///
    /// ⚠️ THE EMERGENCY TEST COMES FIRST, BEFORE ANY COUNTRY, which is the order the core's
    /// ``DialRefusal/emergencyNumber`` documents: `911` must reach the hand-off sentence,
    /// never "pick a country".
    static func read(_ raw: String, country: String?) -> Reading {
        let compact = raw.filter { $0 == "+" || DialEntry.isDigit($0) }
        var plus = compact.hasPrefix("+")
        var digits = compact.filter(DialEntry.isDigit)
        if DialEntry.assess(compact).refusal == .emergencyNumber {
            return Reading(status: .emergency, iso: country, national: digits, international: digits)
        }
        if !plus, let rest = dropExitCode(digits, country: country) {
            digits = rest
            plus = true
        }
        if digits.isEmpty {
            let shown = plus ? "+" : ""
            return Reading(
                status: plus ? .typing : .empty, iso: plus ? nil : country,
                national: shown, international: shown, namedItsCountry: plus
            )
        }
        return plus ? readInternational(digits) : readNational(digits, country: country)
    }

    /// `011` from a North American country, `00` from anywhere else, is the exit code
    /// that stands for `+`. ⚠️ With no country chosen either one is taken, because there
    /// is no national number to confuse it with.
    private static func dropExitCode(_ digits: String, country: String?) -> String? {
        let nanp = country.map(isNANP) ?? false
        if nanp || country == nil, digits.hasPrefix("011") {
            return String(digits.dropFirst(3))
        }
        if !nanp, digits.hasPrefix("00") {
            return String(digits.dropFirst(2))
        }
        return nil
    }

    private static func readNational(_ digits: String, country: String?) -> Reading {
        guard let country, let code = callingCode(for: country) else {
            return Reading(status: .needsCountry, iso: nil, national: digits, international: digits)
        }
        var nsn = digits
        var typedTrunk = false
        if code == "1", nsn.hasPrefix("1") {
            nsn.removeFirst()
            typedTrunk = true
        } else if trunkZero.contains(country), nsn.hasPrefix("0") {
            nsn.removeFirst()
            typedTrunk = true
        }
        // ⚠️ A +1 NUMBER IS READ BY ITS AREA CODE: 416 is Canada, 206 the US, 876 Jamaica.
        let iso = code == "1" ? nanpCountry(nsn, fallback: country) : country
        return finish(iso: iso, code: code, nsn: nsn, typedTrunk: typedTrunk, plus: false)
    }

    private static func readInternational(_ digits: String) -> Reading {
        let longest = min(DialEntry.maximumCallingCodeDigits, digits.count)
        for length in stride(from: longest, through: 1, by: -1) {
            let code = String(digits.prefix(length))
            guard let first = countriesByCode[code] else { continue }
            var nsn = String(digits.dropFirst(length))
            let iso = countryForCode(code, nsn: nsn, first: first)
            // ⚠️ "+44 (0)20 …" PASTED FROM A SIGNATURE: the trunk 0 is not dialled after a code.
            if trunkZero.contains(iso), nsn.hasPrefix("0") {
                nsn.removeFirst()
            }
            return finish(iso: iso, code: code, nsn: nsn, typedTrunk: false, plus: true)
        }
        // ⚠️ AN UNKNOWN CODE IS SAID PLAINLY AND STAYS DIALABLE, the core's rule for
        // ``DialRegion/unrecognised``: this client is not the authority on which codes exist.
        let shown = "+" + digits
        var reading = Reading(status: .typing, iso: nil, national: shown, international: shown)
        reading.namedItsCountry = true
        if digits.count > DialEntry.maximumDigits {
            reading.status = .tooLong
        } else if digits.count >= DialEntry.minimumDigits {
            reading.status = .ready
            reading.e164 = shown
        }
        return reading
    }

    private static func countryForCode(_ code: String, nsn: String, first: String) -> String {
        switch code {
        case "1":
            nanpCountry(nsn, fallback: nil)
        // ⚠️ +7 IS RUSSIA AND KAZAKHSTAN; Kazakh numbers start 6 or 7.
        case "7":
            nsn.hasPrefix("6") || nsn.hasPrefix("7") ? "KZ" : "RU"
        default:
            first
        }
    }

    private static func finish(iso: String, code: String, nsn: String, typedTrunk: Bool, plus: Bool) -> Reading {
        var reading = Reading(status: .typing, iso: iso, callingCode: code, nationalNumber: nsn)
        reading.namedItsCountry = plus
        reading.national = formatNational(iso: iso, code: code, nsn: nsn, typedTrunk: typedTrunk)
        reading.international = nsn.isEmpty ? "+" + code : "+" + code + " " + chunk(nsn, groups(iso: iso, nsn: nsn))
            .joined(separator: " ")
        let range = lengths(iso: iso, code: code)
        let total = code.count + nsn.count
        if total > DialEntry.maximumDigits || nsn.count > range.upperBound {
            reading.status = .tooLong
        } else if nsn.count >= range.lowerBound, total >= DialEntry.minimumDigits {
            reading.status = .ready
            reading.e164 = "+" + code + nsn
        }
        return reading
    }

    // MARK: - Formatting

    private static func formatNational(iso: String, code: String, nsn: String, typedTrunk: Bool) -> String {
        if nsn.isEmpty {
            guard typedTrunk else { return "" }
            return code == "1" ? "1" : "0"
        }
        if code == "1" {
            let digits = Array(nsn)
            switch digits.count {
            case ...3:
                return nsn
            case 4 ... 6:
                return "(" + String(digits[0 ..< 3]) + ") " + String(digits[3...])
            default:
                return "(" + String(digits[0 ..< 3]) + ") " + String(digits[3 ..< 6]) + "-" + String(digits[6...])
            }
        }
        var parts = chunk(nsn, groups(iso: iso, nsn: nsn))
        if iso == "AU", !nsn.hasPrefix("4") {
            let rest = parts.dropFirst().joined(separator: " ")
            return "(0" + parts[0] + ")" + (rest.isEmpty ? "" : " " + rest)
        }
        if trunkZero.contains(iso) {
            parts[0] = "0" + parts[0]
        }
        return parts.joined(separator: " ")
    }

    /// How a country's national number is grouped. ⚠️ A display convention only: a
    /// country not named here gets threes, which reads well enough and changes no digit.
    private static func groups(iso: String, nsn: String) -> [Int] {
        switch iso {
        case "GB":
            nsn.hasPrefix("2") ? [2, 4, 4] : [4, 6]
        case "FR":
            [1, 2, 2, 2, 2]
        case "DE":
            nsn.hasPrefix("15") || nsn.hasPrefix("16") || nsn.hasPrefix("17") ? [3, 8]
                : ["30", "40", "69", "89"].contains(where: nsn.hasPrefix) ? [2, 9] : [4, 8]
        case "AU":
            nsn.hasPrefix("4") ? [3, 3, 3] : [1, 4, 4]
        case "CH":
            [2, 3, 2, 2]
        case "SG":
            [4, 4]
        default:
            [3, 3, 4]
        }
    }

    /// How many digits a country's national numbers have. ⚠️ Exact only where it is
    /// certain; anywhere else the E.164 floor and ceiling decide.
    private static func lengths(iso: String, code: String) -> ClosedRange<Int> {
        if code == "1" {
            return 10 ... 10
        }
        switch iso {
        case "GB": return 9 ... 10
        case "FR", "AU", "CH": return 9 ... 9
        case "DE": return 6 ... 13
        case "SG": return 8 ... 8
        default: return 4 ... (DialEntry.maximumDigits - code.count)
        }
    }

    /// `sizes`, with the last group taking whatever is left.
    private static func chunk(_ text: String, _ sizes: [Int]) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        for (index, size) in sizes.enumerated() where !rest.isEmpty {
            let take = index == sizes.count - 1 ? rest.count : size
            out.append(String(rest.prefix(take)))
            rest = rest.dropFirst(take)
        }
        return out
    }

    // MARK: - Countries

    static func callingCode(for iso: String) -> String? {
        codesByCountry[iso]
    }

    static func isNANP(_ iso: String) -> Bool {
        codesByCountry[iso] == "1"
    }

    /// Which +1 country an area code belongs to: Canada, a Caribbean or Pacific member of
    /// the plan, or else the United States. Before three digits, `fallback` when it is a
    /// +1 country, else the US.
    static func nanpCountry(_ nsn: String, fallback: String?) -> String {
        guard nsn.count >= 3 else {
            return fallback.flatMap { isNANP($0) ? $0 : nil } ?? "US"
        }
        let area = String(nsn.prefix(3))
        if canadianAreaCodes.contains(area) {
            return "CA"
        }
        return nanpAreaCountries[area] ?? "US"
    }

    /// The flag, as the two regional-indicator letters iOS draws as one emoji.
    static func flag(_ iso: String) -> String {
        let base: UInt32 = 0x1F1E6
        let scalars = iso.uppercased().unicodeScalars.compactMap { letter in
            UnicodeScalar(base + letter.value - 65)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// The country's name in the app's language (Canadian French or English).
    static func name(_ iso: String, locale: L10nLocale = L10nRuntime.locale) -> String {
        let identifier = locale == .frCA ? "fr_CA" : "en_CA"
        return Locale(identifier: identifier).localizedString(forRegionCode: iso) ?? iso
    }

    /// The countries a search matches: by name (accents and case ignored), by ISO code,
    /// or by calling code, with or without the `+`.
    static func search(_ query: String, locale: L10nLocale = L10nRuntime.locale) -> [String] {
        let all = sortedCountries(locale: locale)
        let needle = fold(query.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty else { return all }
        let digits = needle.hasPrefix("+") ? String(needle.dropFirst()) : needle
        return all.filter { iso in
            fold(name(iso, locale: locale)).contains(needle)
                || iso.lowercased() == needle
                ||
                (!digits.isEmpty && digits.allSatisfy(DialEntry.isDigit) && codesByCountry[iso]?
                    .hasPrefix(digits) == true)
        }
    }

    /// Every country, alphabetical in the app's language.
    static func sortedCountries(locale: L10nLocale = L10nRuntime.locale) -> [String] {
        let sortLocale = Locale(identifier: locale == .frCA ? "fr_CA" : "en_CA")
        return countries.map(\.iso).sorted { lhs, rhs in
            name(lhs, locale: locale).compare(name(rhs, locale: locale), locale: sortLocale) == .orderedAscending
        }
    }

    /// The "Suggested" group: the workspace's home country, the one on screen, then
    /// Canada and the United States, each once.
    static func suggested(home: String?, current: String?) -> [String] {
        var out: [String] = []
        for iso in [home, current, "CA", "US"].compactMap(\.self) where !out.contains(iso) {
            out.append(iso)
        }
        return out
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static let codesByCountry: [String: String] = Dictionary(
        uniqueKeysWithValues: countries.map { ($0.iso, $0.code) }
    )

    /// ⚠️ THE FIRST COUNTRY LISTED FOR A CODE IS THE ONE A PASTED `+` NUMBER RESOLVES TO,
    /// except +1 and +7, which ``countryForCode(_:nsn:first:)`` reads by their digits.
    private static let countriesByCode: [String: String] = countries.reduce(into: [:]) { map, entry in
        if map[entry.code] == nil {
            map[entry.code] = entry.iso
        }
    }
}
