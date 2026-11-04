/// The data ``DialPlan`` reads by: every country the picker lists, with its calling code,
/// and the few facts about numbering plans the formatter needs.
///
/// ⚠️ ITS OWN FILE BECAUSE IT IS A TABLE, and `swiftlint --strict` counts its lines against
/// `file_length` like any other code.
///
/// ⚠️ ONE COUNTRY PER CODE OUTSIDE +1 AND +7. Territories that share a code with a larger
/// country (Guernsey and Jersey on +44, the Vatican on +39, Mayotte on +262) are left out
/// rather than listed second, so a pasted number never names a place it cannot tell apart.
extension DialPlan {
    struct Country: Equatable {
        let iso: String
        let code: String
    }

    static let countries: [Country] = {
        let table = """
        CA 1|US 1|AF 93|AL 355|DZ 213|AS 1|AD 376|AO 244|AI 1|AG 1|AR 54|AM 374|AW 297|AU 61|AT 43|\
        AZ 994|BS 1|BH 973|BD 880|BB 1|BY 375|BE 32|BZ 501|BJ 229|BM 1|BT 975|BO 591|BA 387|BW 267|\
        BR 55|VG 1|BN 673|BG 359|BF 226|BI 257|KH 855|CM 237|CV 238|KY 1|CF 236|TD 235|CL 56|CN 86|\
        CO 57|KM 269|CG 242|CD 243|CK 682|CR 506|CI 225|HR 385|CU 53|CW 599|CY 357|CZ 420|DK 45|\
        DJ 253|DM 1|DO 1|EC 593|EG 20|SV 503|GQ 240|ER 291|EE 372|SZ 268|ET 251|FK 500|FO 298|FJ 679|\
        FI 358|FR 33|GF 594|PF 689|GA 241|GM 220|GE 995|DE 49|GH 233|GI 350|GR 30|GL 299|GD 1|GP 590|\
        GU 1|GT 502|GN 224|GW 245|GY 592|HT 509|HN 504|HK 852|HU 36|IS 354|IN 91|ID 62|IR 98|IQ 964|\
        IE 353|IL 972|IT 39|JM 1|JP 81|JO 962|KZ 7|KE 254|KI 686|XK 383|KW 965|KG 996|LA 856|LV 371|\
        LB 961|LS 266|LR 231|LY 218|LI 423|LT 370|LU 352|MO 853|MG 261|MW 265|MY 60|MV 960|ML 223|\
        MT 356|MH 692|MQ 596|MR 222|MU 230|MX 52|FM 691|MD 373|MC 377|MN 976|ME 382|MS 1|MA 212|\
        MZ 258|MM 95|NA 264|NR 674|NP 977|NL 31|NC 687|NZ 64|NI 505|NE 227|NG 234|NU 683|KP 850|\
        MK 389|MP 1|NO 47|OM 968|PK 92|PW 680|PS 970|PA 507|PG 675|PY 595|PE 51|PH 63|PL 48|PT 351|\
        PR 1|QA 974|RE 262|RO 40|RU 7|RW 250|KN 1|LC 1|PM 508|VC 1|WS 685|SM 378|ST 239|SA 966|\
        SN 221|RS 381|SC 248|SL 232|SG 65|SX 1|SK 421|SI 386|SB 677|SO 252|ZA 27|KR 82|SS 211|ES 34|\
        LK 94|SD 249|SR 597|SE 46|CH 41|SY 963|TW 886|TJ 992|TZ 255|TH 66|TL 670|TG 228|TO 676|TT 1|\
        TN 216|TR 90|TM 993|TC 1|TV 688|VI 1|UG 256|UA 380|AE 971|GB 44|UY 598|UZ 998|VU 678|VE 58|\
        VN 84|WF 681|YE 967|ZM 260|ZW 263
        """
        return table.split(separator: "|").map { pair in
            let parts = pair.split(separator: " ")
            return Country(iso: String(parts[0]), code: String(parts[1]))
        }
    }()

    /// Countries whose national numbers carry a trunk `0` that is dropped after the
    /// calling code: `020 7946 0958` in London is `+44 20 7946 0958`.
    ///
    /// ⚠️ EVERY COUNTRY HERE WHOSE NATIONAL PREFIX IS `0` IN libphonenumber (libphonenumber-js
    /// 1.13.14; Seer on district-core-rust #63 found Venezuela, Ecuador and Uruguay missing). One
    /// missing would keep a typed leading `0` in the number: `0412 123 4567` in Venezuela sent
    /// `+58 0412…`. The same list is in district-macos, district-android and district-core-rust.
    static let trunkZero: Set<String> = [
        "AE", "AF", "AL", "AM", "AR", "AT", "AU", "AZ", "BA", "BD", "BE", "BG", "BO", "BR", "CD", "CH", "CN",
        "CO", "CU", "DE", "DZ", "EC", "EG", "ER", "ET", "FI", "FR", "GB", "GE", "GF", "GH", "GP", "HR", "ID",
        "IE", "IL", "IN", "IQ", "IR", "JO", "JP", "KE", "KG", "KH", "KI", "KP", "KR", "LA", "LB", "LI", "LK",
        "LR", "LT", "LY", "MA", "MC", "MD", "ME", "MG", "MK", "MM", "MN", "MQ", "MW", "MY", "NA", "NG", "NL",
        "NP", "NZ", "PE", "PH", "PK", "PM", "PS", "PY", "RE", "RO", "RS", "RW", "SA", "SD", "SE", "SI", "SK",
        "SL", "SO", "SS", "SY", "TH", "TR", "TW", "TZ", "UA", "UG", "UY", "VE", "VN", "XK", "YE", "ZA", "ZM",
        "ZW",
    ]

    /// Trunk prefixes that are not a single `0`: libphonenumber's national prefix for every country
    /// outside +1 that has one and it is not `0` (libphonenumber-js 1.13.14). Without them
    /// `8 495 123 4567` typed in Russia would keep its `8` and send `+7 849…`, a wrong number that
    /// still dials (Seer on PR #95). Belarus is `8`, not `80`: `80` is one of the prefixes below.
    static let otherTrunkPrefixes: [String: String] = [
        "BY": "8", "HU": "06", "KZ": "8", "MH": "1", "RU": "8", "TM": "8",
    ]

    /// The other prefixes libphonenumber strips when it reads a national number, where its
    /// `national_prefix_for_parsing` is a plain list of them: Belarus `0|80?`, Lithuania `[08]` (its
    /// trunk prefix became `0` in 2025, and the old `8` is still dialled) and the UK's `180020`. They
    /// are read, never shown: the local form keeps ``trunkPrefix(_:)``. ⚠️ The rules that are not a
    /// plain list (carrier codes and area-code rewrites: AR, AU, BO, BR, CN, CO, JP, KR, LI, MG) are
    /// not modelled. The same table is in the other app repos and district-core-rust.
    static let parsingTrunkPrefixes: [String: [String]] = ["BY": ["80", "0"], "GB": ["180020"], "LT": ["8"]]

    /// The +1 toll-free area codes. ⚠️ They belong to the whole plan, so they never name a
    /// country and never vote for a workspace's home country.
    static let nanpTollFree: Set<String> = ["800", "833", "844", "855", "866", "877", "888"]

    /// The +1 area codes the web's table gives no country (`nanp-area-codes.ts`, `country: null`):
    /// the toll-free ones and the non-geographic 500, 600, 700, 710 and 900. The line under the
    /// field names no country for them (``DialerModel/noCountryNumber(_:)``).
    static let nanpNoCountry: Set<String> = nanpTollFree.union(["500", "600", "700", "710", "900"])

    /// Canadian area codes, so a +1 number reads Canada or the US by its first three digits.
    static let canadianAreaCodes: Set<String> = Set(
        """
        204 226 236 249 250 257 263 289 306 343 354 365 367 368 382 387 403 416 418 428 431 437 438 450 \
        460 468 474 506 514 519 548 579 581 584 587 604 613 639 647 672 683 705 709 742 753 778 780 \
        782 807 819 825 867 873 879 902 905 942
        """.split(separator: " ").map(String.init)
    )

    /// The +1 area codes that belong to neither Canada nor the United States.
    ///
    /// ⛔ WITHOUT THIS A JAMAICAN NUMBER WOULD SAY "RINGS UNITED STATES", which is the
    /// wrong-country disclosure this screen exists to prevent.
    static let nanpAreaCountries: [String: String] = [
        "242": "BS", "246": "BB", "264": "AI", "268": "AG", "284": "VG", "340": "VI", "345": "KY",
        "441": "BM", "473": "GD", "649": "TC", "658": "JM", "664": "MS", "670": "MP", "671": "GU",
        "684": "AS", "721": "SX", "758": "LC", "767": "DM", "784": "VC", "787": "PR", "809": "DO",
        "829": "DO", "849": "DO", "868": "TT", "869": "KN", "876": "JM", "939": "PR",
    ]

    /// libphonenumber's national number pattern (libphonenumber-js 1.13.14) for each country with
    /// ``parsingTrunkPrefixes``, so a prefix is read off only where libphonenumber would read it off:
    /// not when the digits typed already make a whole number there and would not without it
    /// (``stripsPrefix(_:from:in:)``). `800 12345` is a whole Lithuanian toll-free number, not the old
    /// trunk `8` and `0012345` (Seer on district-ios #98). The same table is in the other app repos.
    static let nationalNumberPatterns: [String: String] = [
        "BY": #"(?:[12]\d|33|44|902)\d{7}|8(?:0[0-79]\d{5,7}|[1-7]\d{9})"#
            + #"|8(?:1[0-489]|[5-79]\d)\d{7}|8[1-79]\d{6,7}|8[0-79]\d{5}|8\d{5}"#,
        "GB": #"[1-357-9]\d{9}|[18]\d{8}|8\d{6}"#,
        "LT": #"(?:[3469]\d|52|[78]0)\d{6}"#,
    ]

    // MARK: - Lookups in these tables

    // ⚠️ HERE RATHER THAN IN `DialPlan.swift`, AND THAT IS A LINT CEILING: `type_body_length` caps the
    // enum's body at 300 lines.

    /// Which +1 country an area code belongs to: Canada, a Caribbean or Pacific member of
    /// the plan, or else the United States. Before three digits, `fallback` when it is a
    /// +1 country, else the US.
    static func nanpCountry(_ nsn: String, fallback: String?) -> String {
        let plusOne = fallback.flatMap { isNANP($0) ? $0 : nil } ?? "US"
        // ⚠️ A NO-COUNTRY CODE (toll-free 800, 888 …, and the web's 500, 600, 700, 710, 900) BELONGS
        // TO NO ONE COUNTRY, so it keeps the +1 country already on screen rather than claiming one
        // (Seer on district-ios #98: 600 claimed Canada beside a line saying it had no country).
        guard nsn.count >= 3, !isNANPNoCountry(nsn) else { return plusOne }
        let area = String(nsn.prefix(3))
        if canadianAreaCodes.contains(area) {
            return "CA"
        }
        return nanpAreaCountries[area] ?? "US"
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

    /// Whether `prefix`, which `digits` starts with, is read off as a prefix in `iso`: libphonenumber's
    /// test, for the countries in ``nationalNumberPatterns``. Not when `digits` already match the
    /// country's national number pattern and what is left would not.
    static func stripsPrefix(_ prefix: String, from digits: String, in iso: String) -> Bool {
        guard let pattern = nationalNumberPatterns[iso] else { return true }
        let rest = String(digits.dropFirst(prefix.count))
        return !(matches(digits, pattern) && !matches(rest, pattern))
    }

    private static func matches(_ digits: String, _ pattern: String) -> Bool {
        digits.range(of: "^(?:" + pattern + ")$", options: .regularExpression) != nil
    }
}
