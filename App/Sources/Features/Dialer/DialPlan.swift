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
    ///
    /// ⛔ WHAT THE FIELD SHOWS (``Reading/national``) IS READ AGAIN ON THE NEXT EDIT, SO IT MUST READ
    /// BACK TO THE SAME NUMBER (Seer on district-core-rust #63). `+1 1 416 555 0199` pasted was shown
    /// as `(141) 655-50199`, and reading that took its leading `1` as the trunk prefix: `416 555 0199`,
    /// a whole Canadian number with Call on. A local form that would not read back is shown in its
    /// international form, `+114165550199`, which does.
    static func read(_ raw: String, country: String?) -> Reading {
        var reading = readEntry(raw, country: country)
        // ⚠️ NOT WHILE THE NATIONAL NUMBER IS EMPTY: `+44` alone shows an empty field under the flag,
        // and there is no number yet to read back.
        guard reading.status != .emergency, !reading.callingCode.isEmpty, !reading.nationalNumber.isEmpty,
              !reading.national.hasPrefix("+") else { return reading }
        let again = readEntry(reading.national, country: reading.iso)
        if again.callingCode != reading.callingCode || again.nationalNumber != reading.nationalNumber {
            reading.national = "+" + reading.callingCode + reading.nationalNumber
        }
        return reading
    }

    private static func readEntry(_ raw: String, country: String?) -> Reading {
        let compact = raw.filter { $0 == "+" || DialEntry.isDigit($0) }
        var plus = compact.hasPrefix("+")
        var digits = compact.filter(DialEntry.isDigit)
        // ⚠️ AN EMERGENCY CODE IS SHOWN AS TYPED, ITS `+` KEPT: `+911` is refused, but it is also
        // the start of every Indian number beginning +91 1, and the next digit must still be read
        // after the code rather than as a local number (Seer on district-core-rust #63).
        if DialEntry.assess(compact).refusal == .emergencyNumber {
            let shown = plus ? "+" + digits : digits
            return Reading(status: .emergency, iso: country, national: shown, international: shown)
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
        return plus ? readInternational(digits, country: country) : readNational(digits, country: country)
    }

    /// What the field keeps when a country is picked over it, read in `country`, the one on the
    /// button before the pick.
    ///
    /// ⚠️ A `+` ENTRY GIVES UP THE PLUS AND ITS CODE and keeps the digits after a known one, so
    /// picking a country means "this number is in that country"; a `+` with no known code
    /// (`+7` alone, `+999…`) is cleared, or it would ring nowhere beside the country picked.
    /// Anything else keeps its digits.
    static func entryForPick(_ entry: String, country: String?) -> String {
        guard entry.filter({ $0 == "+" || DialEntry.isDigit($0) }).hasPrefix("+") else {
            return entry.filter(DialEntry.isDigit)
        }
        let reading = read(entry, country: country)
        return reading.iso == nil ? "" : reading.nationalNumber
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
        } else if let trunk = trunkPrefix(country) {
            // ⚠️ HALF OF A TWO-DIGIT TRUNK (Hungary's `06`) IS SHOWN AS TYPED, not read as a number.
            if nsn.count < trunk.count, trunk.hasPrefix(nsn) {
                return Reading(
                    status: .typing,
                    iso: country,
                    callingCode: code,
                    national: nsn,
                    international: "+" + code
                )
            }
            // ⚠️ AND THE OTHER PREFIXES libphonenumber STRIPS, longest first (``nationalPrefixes(_:)``):
            // Lithuania's old `8`, Belarus's `80`.
            if let typed = nationalPrefixes(country).first(where: { nsn.hasPrefix($0) }) {
                nsn.removeFirst(typed.count)
                typedTrunk = true
            }
        }
        // ⚠️ A CODE SHARED BY SEVERAL COUNTRIES IS READ AGAIN AS EACH DIGIT ARRIVES, exactly as a
        // pasted `+` number is: +1 by its area code (416 is Canada, 206 the US, 876 Jamaica), +7 by
        // its first digit. Typed one key at a time, `+7` moves the flag to Russia and the rest
        // arrives here as a national number; read only in the country on the button, `701…`
        // would stay "Rings Russia" for a Kazakh number (Seer on district-macos #91).
        let iso = countryForCode(code, nsn: nsn, first: country, current: country)
        return finish(iso: iso, code: code, nsn: nsn, typedTrunk: typedTrunk, plus: false)
    }

    private static func readInternational(_ digits: String, country: String?) -> Reading {
        let longest = min(DialEntry.maximumCallingCodeDigits, digits.count)
        for length in stride(from: longest, through: 1, by: -1) {
            let code = String(digits.prefix(length))
            guard let first = countriesByCode[code] else { continue }
            var nsn = String(digits.dropFirst(length))
            let iso = countryForCode(code, nsn: nsn, first: first, current: country)
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

    /// Which country a calling code rings for `nsn`: the code's `first` country, except for a
    /// code several countries share, which is decided by the digits after it.
    private static func countryForCode(_ code: String, nsn: String, first: String, current: String?) -> String {
        switch code {
        case "1":
            nanpCountry(nsn, fallback: current)
        // ⚠️ +7 IS RUSSIA AND KAZAKHSTAN; Kazakh numbers start 6 or 7. Before that digit the
        // +7 country on screen stays, as a +1 one does before its area code.
        case "7":
            nsn.isEmpty ? (current == "KZ" ? "KZ" : "RU") : nsn.hasPrefix("6") || nsn.hasPrefix("7") ? "KZ" : "RU"
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

    /// ⚠️ A `+` AND A CALLING CODE WITH NO DIGIT AFTER IT YET STAY AS THEY ARE, so the next
    /// digit is still read after the code. Shown as an empty national number instead, the next
    /// digit was read as a local one and a trunk prefix swallowed it: Saint Petersburg's 812
    /// typed after `+7` lost its 8 to Russia's trunk 8 (Seer on district-core-rust #63). A
    /// national number is otherwise empty only after a trunk prefix, which is shown as typed.
    private static func formatNational(iso: String, code: String, nsn: String, typedTrunk: Bool) -> String {
        if nsn.isEmpty {
            guard typedTrunk else { return "+" + code }
            return code == "1" ? "1" : trunkPrefix(iso) ?? "0"
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
        // ⚠️ AN AUSTRALIAN 13, 1300 OR 1800 NUMBER IS DIALLED AS IT STANDS, WITH NO TRUNK 0.
        if iso == "AU", isAustralianNonGeographic(nsn) {
            return parts.joined(separator: " ")
        }
        // ⚠️ THE PARENTHESES CLOSE ONLY ONCE A DIGIT FOLLOWS THE AREA CODE. A `)` written after
        // `(02` alone would be the last character, and deleting it would put it straight back,
        // so backspace could never get past the area code.
        if iso == "AU", !nsn.hasPrefix("4"), parts.count > 1 {
            return "(0" + parts[0] + ") " + parts.dropFirst().joined(separator: " ")
        }
        if let trunk = trunkPrefix(iso) {
            parts[0] = trunk + parts[0]
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
            isAustralianNonGeographic(nsn) ? [4, 3, 3] : nsn.hasPrefix("4") ? [3, 3, 3] : [1, 4, 4]
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
        // ⛔ RUSSIA AND KAZAKHSTAN: TEN DIGITS AFTER +7, ALWAYS. Without this an eleven-digit
        // Russian number typed with its 7 and no `+` read as an eleven-digit Kazakh number and
        // was offered for dialling (Seer on district-core-rust #63).
        if code == "7" {
            return 10 ... 10
        }
        switch iso {
        // ⚠️ WIDE ENOUGH FOR EVERY NUMBER THE COUNTRY ISSUES, not just the common shape: a
        // range that misses one blocks a real call. Australia's 13 xx xx is 6 digits and its
        // 1300/1800 numbers 10; Singapore's 1800 toll-free numbers are 11; a UK 0800 number
        // can be 7. Switzerland and France issue nothing but 9.
        case "GB": return 7 ... 10
        case "FR", "CH": return 9 ... 9
        case "AU": return 6 ... 10
        case "DE": return 6 ... 13
        case "SG": return 8 ... 11
        default: return 4 ... (DialEntry.maximumDigits - code.count)
        }
    }

    /// Australia's 13, 1300 and 1800 numbers: no area code and no trunk 0. ⚠️ THE WHOLE `1`
    /// RANGE, so a lone typed `1` is not shown as `01` (geographic area codes are 2, 3, 7 and
    /// 8, mobiles 4).
    private static func isAustralianNonGeographic(_ nsn: String) -> Bool {
        nsn.hasPrefix("1")
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
        let plusOne = fallback.flatMap { isNANP($0) ? $0 : nil } ?? "US"
        // ⚠️ A TOLL-FREE CODE (800, 888 …) BELONGS TO NO ONE COUNTRY, so it keeps the +1 country
        // already on screen rather than claiming the United States.
        guard nsn.count >= 3, !isNANPTollFree(nsn) else { return plusOne }
        let area = String(nsn.prefix(3))
        if canadianAreaCodes.contains(area) {
            return "CA"
        }
        return nanpAreaCountries[area] ?? "US"
    }

    /// Whether a +1 national number is toll-free, shared by every country of the plan.
    static func isNANPTollFree(_ nsn: String) -> Bool {
        nanpTollFree.contains(String(nsn.prefix(3)))
    }

    /// Whether a +1 national number belongs to no one country, as the web's table has it
    /// (``nanpNoCountry``).
    static func isNANPNoCountry(_ nsn: String) -> Bool {
        nanpNoCountry.contains(String(nsn.prefix(3)))
    }

    /// The trunk prefix dialled before a national number inside the country, or nil: `0` for
    /// most, `8` in Russia, Kazakhstan, Belarus and Turkmenistan, `06` in Hungary, `1` in the
    /// Marshall Islands.
    static func trunkPrefix(_ iso: String) -> String? {
        if let other = otherTrunkPrefixes[iso] {
            return other
        }
        return trunkZero.contains(iso) ? "0" : nil
    }

    /// Every prefix a national number typed in `iso` may start with that is not part of the number:
    /// the trunk prefix and ``parsingTrunkPrefixes``, longest first, so Belarus's `80` is tried
    /// before its `8`.
    static func nationalPrefixes(_ iso: String) -> [String] {
        guard let trunk = trunkPrefix(iso) else { return [] }
        return ([trunk] + (parsingTrunkPrefixes[iso] ?? [])).sorted { $0.count > $1.count }
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
    ///
    /// ⚠️ RANKED, THEN ALPHABETICAL WITHIN A RANK: the ISO code exactly, a name that starts
    /// with the query, a calling code, then a name that merely contains it. Return picks the
    /// first row, so alphabetical alone made `us` pick Australia, ahead of Austria and the
    /// United States (Seer on district-macos #91).
    static func search(_ query: String, locale: L10nLocale = L10nRuntime.locale) -> [String] {
        let all = sortedCountries(locale: locale)
        let needle = fold(query.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty else { return all }
        let digits = needle.hasPrefix("+") ? String(needle.dropFirst()) : needle
        let byCode = !digits.isEmpty && digits.allSatisfy(DialEntry.isDigit)
        var ranks: [[String]] = Array(repeating: [], count: 4)
        for iso in all {
            let folded = fold(name(iso, locale: locale))
            if iso.lowercased() == needle {
                ranks[0].append(iso)
            } else if folded.hasPrefix(needle) {
                ranks[1].append(iso)
            } else if byCode, codesByCountry[iso]?.hasPrefix(digits) == true {
                ranks[2].append(iso)
            } else if folded.contains(needle) {
                ranks[3].append(iso)
            }
        }
        return ranks.flatMap(\.self)
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
