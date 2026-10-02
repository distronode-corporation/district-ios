/// The place a number's leading digits name, for DISCLOSURE only.
///
/// ⛔ NOTHING HERE EVER CHANGES WHAT IS DIALLED, AND THAT IS THE WHOLE DESIGN.
/// `POST /api/district/calls/dial` runs its own `normalizePhoneNumber` and then
/// checks Do-Not-Call, resolves the Contact and instructs the carrier against
/// THAT form, so a client that rewrote the operator's text would ship a second
/// opinion about numbers whose disagreements are invisible until a call reaches
/// a number the compliance screen never saw. The Kotlin `DialFormat.kt` makes
/// the identical argument about its display grouping. This type reads the
/// string and says something about it; it never hands one back to be sent.
public enum DialRegion: Sendable, Equatable {
    /// Nothing to name: no country code has been typed yet.
    case none

    /// A country code is present and matches no entry in ``DialEntry/callingCodes``.
    ///
    /// ⛔ SAID PLAINLY RATHER THAN GUESSED AT. An unknown code is still dialable
    /// (see ``DialEntry/assess(_:)``), because refusing every code this table has
    /// not heard of would make the client the authority on which countries exist.
    /// What it must never do is name the wrong one.
    case unrecognised

    /// The place the leading digits name.
    case named(String)
}

/// Why an entry may not be dialled.
///
/// ⛔ EVERY CASE IS SHOWN TO THE OPERATOR. A disabled Call button with no reason
/// is how the eight-digit floor already confused people; the refusal exists so
/// the screen can say what is missing rather than simply going grey.
public enum DialRefusal: Sendable, Equatable {
    /// Nothing typed. ⚠️ The keypad's own hint covers this one, so the screen
    /// says nothing extra.
    case empty

    /// No leading `+`, so the string names no country at all.
    ///
    /// ⛔ THE WRONG-COUNTRY DIAL'S SIBLING AND THE ONE UNAMBIGUOUS
    /// REFUSAL. A bare `4165550123` is dialled by the carrier as whatever its
    /// own default interprets it to be, and the server adds no country code
    /// either: `normalizePhoneNumber` strips punctuation and nothing else.
    case missingCountryCode

    /// Fewer than ``DialEntry/minimumDigits`` digits after the `+`.
    case tooShort

    /// More than ``DialEntry/maximumDigits`` digits after the `+`. E.164 stops
    /// at fifteen.
    case tooLong

    /// A `+` somewhere other than the front. ⚠️ Reachable from a paste, and from
    /// the `.phonePad` keyboard, which offers `+` on every keypress.
    case strayPlus

    /// An emergency number. ⛔ NOT AN ERROR THE OPERATOR SHOULD FIX — a hand-off.
    ///
    /// ⛔ IT IS TESTED FIRST, BEFORE ``missingCountryCode``, AND THE ORDER IS THE
    /// WHOLE FIX. Until this case existed, `911` fell through to
    /// `missingCountryCode`, whose copy reads "Start with a country code, for
    /// example +1" — and following that instruction produces `+1911`, which was
    /// then refused as ``tooShort``. The app walked somebody trying to call for
    /// help into a second dead end. A flat refusal would have been better; the
    /// remediation copy made it worse.
    ///
    /// ⛔ THE REMEDY IS NEVER TO DIAL IT. Emergency calling over VoIP is a
    /// regulatory problem (E911 location, callback, PSAP routing) rather than a
    /// feature gap, so this app must not carry one. What it owes the user is to
    /// say so and name the Phone app, which can.
    case emergencyNumber
}

/// What one keypad entry discloses, and whether it may be dialled.
public struct DialEntryAssessment: Sendable, Equatable {
    /// Where the call will ring, as far as the leading digits say.
    public let region: DialRegion

    /// Why it may not be dialled, or nil when it may.
    public let refusal: DialRefusal?

    public init(region: DialRegion, refusal: DialRefusal?) {
        self.region = region
        self.refusal = refusal
    }

    public var isDialable: Bool {
        refusal == nil
    }
}

/// Reading a dial entry: which country it names, and whether it can be E.164.
///
/// ⛔ IT EXISTS BECAUSE A CALL REACHED THE WRONG COUNTRY AND WAS BILLED FOR IT.
/// An operator typed a Canadian mobile and the app dialled
/// `+4165550123`: Canada is `+1`, so the number should have been
/// `+14165550123`, and as sent the leading `+41` is SWITZERLAND. The only gate
/// on the button was a digit COUNT, which ten digits passes, and nothing on
/// either side of the wire had an opinion about the country code. The fix is
/// disclosure plus one unambiguous refusal, never a rewrite.
///
/// ⛔ PURE, AND ON PURPOSE. Every function here is a total function of a
/// `String`, with no clock, no locale and no I/O, which is what lets the whole
/// of it be tested on Linux where the screen that uses it cannot even compile.
public enum DialEntry {
    /// The E.164 floor, and the server's own: `POST /api/district/calls/dial`
    /// rejects anything shorter than 8 characters after normalising.
    public static let minimumDigits = 8

    /// The E.164 ceiling. ⚠️ Stricter than the route's `.max(32)` on the raw
    /// string, and deliberately: 32 characters is a length guard on a request
    /// body, not a statement about phone numbers.
    public static let maximumDigits = 15

    /// The longest calling code in ``callingCodes``.
    public static let maximumCallingCodeDigits = 3

    /// Short codes that must never be treated as a number to validate.
    ///
    /// ⚠️ SOURCE, SO THE LIST IS ARGUABLE RATHER THAN FOLKLORE: `112` and `911`
    /// are the two every handset must recognise under **3GPP TS 22.101 §10.1**,
    /// independent of SIM or network. The rest are the widely deployed national
    /// codes — `000` (AU), `111` (NZ), `999` (UK, IE, HK), `110`/`118`/`119`
    /// (JP, CN, and much of Europe), `113`/`115`/`117` (various EU).
    ///
    /// ⛔ IT IS DELIBERATELY INCOMPLETE AND THAT IS SAFE HERE, because the
    /// fallback is not a wrong call: no number under ``minimumDigits`` is
    /// dialable at all, so an emergency code this set misses is still REFUSED —
    /// it just gets the country-code sentence instead of the hand-off. Adding a
    /// code improves the message; omitting one never places a call.
    ///
    /// ⚠️ MATCHED WHOLE, NEVER AS A PREFIX. `+1 911 555 0100` is an ordinary
    /// North American number that begins with 911, and a prefix test would
    /// refuse it. It would also fire while somebody was still typing.
    public static let emergencyNumbers: Set<String> = [
        "000", "110", "111", "112", "113", "115", "117", "118", "119", "911", "999",
    ]

    /// Whether this entry is an emergency short code, in either shape it reaches.
    ///
    /// ⚠️ THE `+1` SHAPE IS CHECKED BECAUSE THE OLD COPY CREATED IT. "Start with
    /// a country code" plus `911` is `+1911`, and a user who followed the app's
    /// own instruction must land on the hand-off rather than on "too short".
    static func isEmergency(_ compacted: String) -> Bool {
        let digits = compacted.hasPrefix("+") ? String(compacted.dropFirst()) : compacted
        if emergencyNumbers.contains(digits) {
            return true
        }
        guard digits.hasPrefix("1") else { return false }
        return emergencyNumbers.contains(String(digits.dropFirst()))
    }

    /// Read one entry as the screen must present it.
    ///
    /// ⚠️ THE ORDER OF THE REFUSALS IS THE ORDER THE OPERATOR CAN ACT ON THEM.
    /// A missing country code is reported before a length, because "add +1" is
    /// the instruction either way and "too short" would send someone hunting
    /// for digits they already have.
    public static func assess(_ raw: String) -> DialEntryAssessment {
        let compact = compacted(raw)
        return DialEntryAssessment(
            region: disclosedRegion(forCompacted: compact),
            refusal: refusal(raw, compact)
        )
    }

    /// ⚠️ THE REGION IS COMPUTED WHATEVER THE REFUSAL SAYS, so a half-typed
    /// `+41…` already reads "Switzerland" while the button is still off. The
    /// disclosure is the part that catches a wrong country code, and it is
    /// worth least at the moment the number is finally long enough to dial.
    private static func refusal(_ raw: String, _ compact: String) -> DialRefusal? {
        guard !raw.allSatisfy(\.isWhitespace) else { return .empty }
        // ⛔ BEFORE THE COUNTRY-CODE CHECK. See the ⛔ on ``DialRefusal/emergencyNumber``:
        // this ordering IS the fix, and a test that only asserts "911 is refused" would
        // pass against the broken behaviour it replaces.
        guard !isEmergency(compact) else { return .emergencyNumber }
        guard compact.hasPrefix("+") else { return .missingCountryCode }
        let digits = compact.dropFirst()
        guard !digits.contains("+") else { return .strayPlus }
        guard digits.count >= minimumDigits else { return .tooShort }
        guard digits.count <= maximumDigits else { return .tooLong }
        return nil
    }

    /// The place an entry's calling code names, or nil when it names none.
    ///
    /// ⚠️ LONGEST PREFIX WINS, THREE DIGITS DOWN TO ONE, which is the only
    /// correct way to read a calling code: `+372` is Estonia while `+37` is
    /// unassigned, and a left-to-right reader would answer `+41…` with nothing
    /// at all. No entry in the table is a prefix of another, so the match is
    /// unambiguous rather than merely first.
    public static func callingCodeRegion(for raw: String) -> String? {
        let digits = leadingDigits(ofCompacted: compacted(raw))
        guard !digits.isEmpty else { return nil }
        let longest = min(maximumCallingCodeDigits, digits.count)
        for length in stride(from: longest, through: 1, by: -1) {
            if let name = callingCodes[String(digits.prefix(length))] {
                return name
            }
        }
        return nil
    }

    /// ⛔ MIRRORS THE SERVER'S `normalizePhoneNumber` EXACTLY: keep ASCII
    /// digits and `+`, drop everything else. It keeps a `+` wherever it appears
    /// rather than only at the front, because the server does, which is what
    /// makes ``DialRefusal/strayPlus`` a real state and not a theoretical one.
    private static func compacted(_ raw: String) -> String {
        String(raw.filter { $0 == "+" || isDigit($0) })
    }

    /// The digits of the calling code, i.e. everything between the leading `+`
    /// and the first character that is not a digit. Empty when there is no `+`.
    private static func leadingDigits(ofCompacted compact: String) -> Substring {
        guard compact.hasPrefix("+") else { return "" }
        return compact.dropFirst().prefix(while: isDigit)
    }

    private static func disclosedRegion(forCompacted compact: String) -> DialRegion {
        let digits = leadingDigits(ofCompacted: compact)
        guard !digits.isEmpty else { return .none }
        guard let name = callingCodeRegion(for: compact) else { return .unrecognised }
        return .named(name)
    }

    /// ⚠️ `isASCII` AS WELL AS `isNumber`. `Character.isNumber` is true for
    /// Arabic-Indic digits and for superscripts, none of which `\d` matches in
    /// the server's regex; without the first half the two sides would disagree
    /// about what counts as a digit. Public so the dialer's own digit floor
    /// counts the same characters this file does.
    public static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    /// The calling codes, committed rather than fetched.
    ///
    /// ⚠️ IT IS A DISCLOSURE TABLE AND NOT A ROUTING TABLE, so being incomplete
    /// costs a label and never a call: an unlisted code reads
    /// ``DialRegion/unrecognised`` and stays dialable.
    ///
    /// ⛔ SEVERAL CODES ARE SHARED AND THE VALUE SAYS SO WHERE IT MATTERS. `+1`
    /// is the whole North American Numbering Plan, which is Canada, the United
    /// States and about twenty Caribbean territories; the label names the two
    /// countries this product sells numbers in, because the job here is to
    /// catch a WRONG country code rather than to identify a right one. `+7` is
    /// Russia and Kazakhstan on one code, and is labelled as both.
    ///
    /// ⚠️ NO ENTRY IS A PREFIX OF ANOTHER. `callingCodeRegion(for:)` relies on
    /// that for its longest-prefix walk, and `DialNumberTests` asserts it, so a
    /// future addition that broke the property fails rather than quietly
    /// shadowing a country.
    public static let callingCodes: [String: String] = [
        "1": "Canada and the United States",
        "7": "Russia or Kazakhstan",
        "20": "Egypt",
        "27": "South Africa",
        "30": "Greece",
        "31": "the Netherlands",
        "32": "Belgium",
        "33": "France",
        "34": "Spain",
        "36": "Hungary",
        "39": "Italy",
        "40": "Romania",
        "41": "Switzerland",
        "43": "Austria",
        "44": "the United Kingdom",
        "45": "Denmark",
        "46": "Sweden",
        "47": "Norway",
        "48": "Poland",
        "49": "Germany",
        "51": "Peru",
        "52": "Mexico",
        "53": "Cuba",
        "54": "Argentina",
        "55": "Brazil",
        "56": "Chile",
        "57": "Colombia",
        "58": "Venezuela",
        "60": "Malaysia",
        "61": "Australia",
        "62": "Indonesia",
        "63": "the Philippines",
        "64": "New Zealand",
        "65": "Singapore",
        "66": "Thailand",
        "81": "Japan",
        "82": "South Korea",
        "84": "Vietnam",
        "86": "China",
        "90": "Turkey",
        "91": "India",
        "92": "Pakistan",
        "93": "Afghanistan",
        "94": "Sri Lanka",
        "95": "Myanmar",
        "98": "Iran",
        "211": "South Sudan",
        "212": "Morocco",
        "213": "Algeria",
        "216": "Tunisia",
        "218": "Libya",
        "220": "the Gambia",
        "221": "Senegal",
        "233": "Ghana",
        "234": "Nigeria",
        "251": "Ethiopia",
        "254": "Kenya",
        "255": "Tanzania",
        "256": "Uganda",
        "260": "Zambia",
        "263": "Zimbabwe",
        "264": "Namibia",
        "265": "Malawi",
        "267": "Botswana",
        "268": "Eswatini",
        "299": "Greenland",
        "350": "Gibraltar",
        "351": "Portugal",
        "352": "Luxembourg",
        "353": "Ireland",
        "354": "Iceland",
        "355": "Albania",
        "356": "Malta",
        "357": "Cyprus",
        "358": "Finland",
        "359": "Bulgaria",
        "370": "Lithuania",
        "371": "Latvia",
        "372": "Estonia",
        "373": "Moldova",
        "374": "Armenia",
        "375": "Belarus",
        "376": "Andorra",
        "377": "Monaco",
        "378": "San Marino",
        "380": "Ukraine",
        "381": "Serbia",
        "382": "Montenegro",
        "383": "Kosovo",
        "385": "Croatia",
        "386": "Slovenia",
        "387": "Bosnia and Herzegovina",
        "389": "North Macedonia",
        "420": "Czechia",
        "421": "Slovakia",
        "423": "Liechtenstein",
        "501": "Belize",
        "502": "Guatemala",
        "503": "El Salvador",
        "504": "Honduras",
        "505": "Nicaragua",
        "506": "Costa Rica",
        "507": "Panama",
        "591": "Bolivia",
        "593": "Ecuador",
        "595": "Paraguay",
        "598": "Uruguay",
        "852": "Hong Kong",
        "853": "Macao",
        "855": "Cambodia",
        "856": "Laos",
        "880": "Bangladesh",
        "886": "Taiwan",
        "960": "the Maldives",
        "961": "Lebanon",
        "962": "Jordan",
        "963": "Syria",
        "964": "Iraq",
        "965": "Kuwait",
        "966": "Saudi Arabia",
        "967": "Yemen",
        "968": "Oman",
        "970": "Palestine",
        "971": "the United Arab Emirates",
        "972": "Israel",
        "973": "Bahrain",
        "974": "Qatar",
        "975": "Bhutan",
        "976": "Mongolia",
        "977": "Nepal",
        "992": "Tajikistan",
        "993": "Turkmenistan",
        "994": "Azerbaijan",
        "995": "Georgia",
        "996": "Kyrgyzstan",
        "998": "Uzbekistan",
    ]
}
