import Foundation

/// The countries, provinces and states step 1 offers, and the time zone each one implies:
/// the web's `setup-places.ts`, entry for entry.
///
/// ⚠️ PLACE NAMES, NOT COPY, SO NOT IN THE CATALOG. A province's French name is its name in
/// French ("Colombie-Britannique"), not a translation anyone reviews, and the web keeps the
/// two side by side in the same table for the same reason. A country's name comes from the
/// system (`Locale.localizedString(forRegionCode:)`), as the web's comes from `Intl`.
///
/// ⛔ `multiZone` IS THE WEB'S FLAG FOR "THIS PLACE SPANS MORE THAN ONE ZONE", and the step
/// then says to check the zone in step 4 rather than claiming it.
enum SetupPlaces {
    struct Zone: Equatable {
        let timezone: String
        var multiZone = false
    }

    struct Subdivision: Equatable, Identifiable {
        let code: String
        let en: String
        let fr: String
        let zone: Zone

        var id: String {
            code
        }

        var name: String {
            AppL10n.copyLocale == .frCA ? fr : en
        }
    }

    private static func sub(
        _ code: String,
        _ en: String,
        _ fr: String,
        _ zone: String,
        multi: Bool = false
    ) -> Subdivision {
        Subdivision(code: code, en: en, fr: fr, zone: Zone(timezone: zone, multiZone: multi))
    }

    static let provinces: [Subdivision] = [
        sub("AB", "Alberta", "Alberta", "America/Edmonton"),
        sub("BC", "British Columbia", "Colombie-Britannique", "America/Vancouver", multi: true),
        sub("MB", "Manitoba", "Manitoba", "America/Winnipeg"),
        sub("NB", "New Brunswick", "Nouveau-Brunswick", "America/Moncton"),
        sub("NL", "Newfoundland and Labrador", "Terre-Neuve-et-Labrador", "America/St_Johns", multi: true),
        sub("NS", "Nova Scotia", "Nouvelle-Écosse", "America/Halifax"),
        sub("NT", "Northwest Territories", "Territoires du Nord-Ouest", "America/Yellowknife"),
        sub("NU", "Nunavut", "Nunavut", "America/Iqaluit", multi: true),
        sub("ON", "Ontario", "Ontario", "America/Toronto", multi: true),
        sub("PE", "Prince Edward Island", "Île-du-Prince-Édouard", "America/Halifax"),
        sub("QC", "Quebec", "Québec", "America/Toronto", multi: true),
        sub("SK", "Saskatchewan", "Saskatchewan", "America/Regina", multi: true),
        sub("YT", "Yukon", "Yukon", "America/Whitehorse"),
    ]

    static let states: [Subdivision] = [
        sub("AL", "Alabama", "Alabama", "America/Chicago"),
        sub("AK", "Alaska", "Alaska", "America/Anchorage", multi: true),
        sub("AZ", "Arizona", "Arizona", "America/Phoenix"),
        sub("AR", "Arkansas", "Arkansas", "America/Chicago"),
        sub("CA", "California", "Californie", "America/Los_Angeles"),
        sub("CO", "Colorado", "Colorado", "America/Denver"),
        sub("CT", "Connecticut", "Connecticut", "America/New_York"),
        sub("DE", "Delaware", "Delaware", "America/New_York"),
        sub("DC", "District of Columbia", "District de Columbia", "America/New_York"),
        sub("FL", "Florida", "Floride", "America/New_York", multi: true),
        sub("GA", "Georgia", "Géorgie", "America/New_York"),
        sub("HI", "Hawaii", "Hawaï", "Pacific/Honolulu"),
        sub("ID", "Idaho", "Idaho", "America/Boise", multi: true),
        sub("IL", "Illinois", "Illinois", "America/Chicago"),
        sub("IN", "Indiana", "Indiana", "America/Indiana/Indianapolis", multi: true),
        sub("IA", "Iowa", "Iowa", "America/Chicago"),
        sub("KS", "Kansas", "Kansas", "America/Chicago", multi: true),
        sub("KY", "Kentucky", "Kentucky", "America/New_York", multi: true),
        sub("LA", "Louisiana", "Louisiane", "America/Chicago"),
        sub("ME", "Maine", "Maine", "America/New_York"),
        sub("MD", "Maryland", "Maryland", "America/New_York"),
        sub("MA", "Massachusetts", "Massachusetts", "America/New_York"),
        sub("MI", "Michigan", "Michigan", "America/Detroit", multi: true),
        sub("MN", "Minnesota", "Minnesota", "America/Chicago"),
        sub("MS", "Mississippi", "Mississippi", "America/Chicago"),
        sub("MO", "Missouri", "Missouri", "America/Chicago"),
        sub("MT", "Montana", "Montana", "America/Denver"),
        sub("NE", "Nebraska", "Nebraska", "America/Chicago", multi: true),
        sub("NV", "Nevada", "Nevada", "America/Los_Angeles"),
        sub("NH", "New Hampshire", "New Hampshire", "America/New_York"),
        sub("NJ", "New Jersey", "New Jersey", "America/New_York"),
        sub("NM", "New Mexico", "Nouveau-Mexique", "America/Denver"),
        sub("NY", "New York", "New York", "America/New_York"),
        sub("NC", "North Carolina", "Caroline du Nord", "America/New_York"),
        sub("ND", "North Dakota", "Dakota du Nord", "America/Chicago", multi: true),
        sub("OH", "Ohio", "Ohio", "America/New_York"),
        sub("OK", "Oklahoma", "Oklahoma", "America/Chicago"),
        sub("OR", "Oregon", "Oregon", "America/Los_Angeles", multi: true),
        sub("PA", "Pennsylvania", "Pennsylvanie", "America/New_York"),
        sub("RI", "Rhode Island", "Rhode Island", "America/New_York"),
        sub("SC", "South Carolina", "Caroline du Sud", "America/New_York"),
        sub("SD", "South Dakota", "Dakota du Sud", "America/Chicago", multi: true),
        sub("TN", "Tennessee", "Tennessee", "America/Chicago", multi: true),
        sub("TX", "Texas", "Texas", "America/Chicago", multi: true),
        sub("UT", "Utah", "Utah", "America/Denver"),
        sub("VT", "Vermont", "Vermont", "America/New_York"),
        sub("VA", "Virginia", "Virginie", "America/New_York"),
        sub("WA", "Washington", "Washington", "America/Los_Angeles"),
        sub("WV", "West Virginia", "Virginie-Occidentale", "America/New_York"),
        sub("WI", "Wisconsin", "Wisconsin", "America/Chicago"),
        sub("WY", "Wyoming", "Wyoming", "America/Denver"),
    ]

    /// Every other country step 1 offers, in the web's order, with its zone.
    static let countryZones: [(code: String, zone: Zone)] = [
        ("AT", Zone(timezone: "Europe/Vienna")), ("BE", Zone(timezone: "Europe/Brussels")),
        ("BG", Zone(timezone: "Europe/Sofia")), ("HR", Zone(timezone: "Europe/Zagreb")),
        ("CY", Zone(timezone: "Asia/Nicosia")), ("CZ", Zone(timezone: "Europe/Prague")),
        ("DK", Zone(timezone: "Europe/Copenhagen")), ("EE", Zone(timezone: "Europe/Tallinn")),
        ("FI", Zone(timezone: "Europe/Helsinki")), ("FR", Zone(timezone: "Europe/Paris")),
        ("DE", Zone(timezone: "Europe/Berlin")), ("GR", Zone(timezone: "Europe/Athens")),
        ("HU", Zone(timezone: "Europe/Budapest")), ("IE", Zone(timezone: "Europe/Dublin")),
        ("IT", Zone(timezone: "Europe/Rome")), ("LV", Zone(timezone: "Europe/Riga")),
        ("LT", Zone(timezone: "Europe/Vilnius")), ("LU", Zone(timezone: "Europe/Luxembourg")),
        ("MT", Zone(timezone: "Europe/Malta")), ("NL", Zone(timezone: "Europe/Amsterdam")),
        ("PL", Zone(timezone: "Europe/Warsaw")), ("PT", Zone(timezone: "Europe/Lisbon", multiZone: true)),
        ("RO", Zone(timezone: "Europe/Bucharest")), ("SK", Zone(timezone: "Europe/Bratislava")),
        ("SI", Zone(timezone: "Europe/Ljubljana")), ("ES", Zone(timezone: "Europe/Madrid", multiZone: true)),
        ("SE", Zone(timezone: "Europe/Stockholm")), ("IS", Zone(timezone: "Atlantic/Reykjavik")),
        ("LI", Zone(timezone: "Europe/Vaduz")), ("NO", Zone(timezone: "Europe/Oslo")),
        ("GB", Zone(timezone: "Europe/London")), ("CH", Zone(timezone: "Europe/Zurich")),
        ("AU", Zone(timezone: "Australia/Sydney", multiZone: true)), ("NZ", Zone(timezone: "Pacific/Auckland")),
        ("SG", Zone(timezone: "Asia/Singapore")), ("HK", Zone(timezone: "Asia/Hong_Kong")),
        ("JP", Zone(timezone: "Asia/Tokyo")), ("IN", Zone(timezone: "Asia/Kolkata")),
        ("PH", Zone(timezone: "Asia/Manila")),
    ]

    /// `SETUP_COUNTRIES`: Canada and the United States first, then the rest.
    static let countries: [String] = ["CA", "US"] + countryZones.map(\.code)

    static func subdivisions(_ country: String) -> [Subdivision]? {
        switch country {
        case "CA": provinces
        case "US": states
        default: nil
        }
    }

    /// The zone a place implies, or nil while the province or state is not chosen.
    static func zone(country: String, subdivision: String) -> Zone? {
        if let list = subdivisions(country) {
            return list.first { $0.code == subdivision.uppercased() }?.zone
        }
        return countryZones.first { $0.code == country }?.zone
    }

    static func defaultCountry(region: String?) -> String {
        switch region {
        case "ca": "CA"
        case "us": "US"
        default: ""
        }
    }

    /// The zones step 4 offers for a country: its own, plus the one already stored.
    static func zones(country: String, including stored: String) -> [String] {
        var out: [String] = if let list = subdivisions(country) {
            list.map(\.zone.timezone)
        } else {
            countryZones.filter { $0.code == country }.map(\.zone.timezone)
        }
        if !stored.isEmpty {
            out.append(stored)
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }.sorted()
    }

    static func countryName(_ code: String) -> String {
        Locale(identifier: AppL10n.copyLocale == .frCA ? "fr_CA" : "en_CA").localizedString(forRegionCode: code) ?? code
    }
}
