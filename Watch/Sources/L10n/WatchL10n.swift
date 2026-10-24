import Foundation

/// Every sentence the watch app and its complication say. Generated from `l10n/watch.toml`
/// into `Generated/Copy.swift`; this enum is empty and exists for that file to extend.
enum WatchCopy {}

/// The language the watch writes in.
///
/// ⛔ THE PHONE'S CHOICE FIRST, THE WATCH'S LOCALE SECOND, AND NO DistrictCore AT ALL. The
/// iPhone's language can be set per app (Settings, District AI, Language), which the watch
/// cannot see; the snapshot names it (``WatchSnapshot/language``) and every row in it is
/// already written in it, so the watch's own words follow it too. Before the first snapshot,
/// or from a phone that did not say, the watch's own preferred localizations decide, the way
/// `AppL10n.resolve` does it on the phone: any French is Canadian French.
///
/// ⚠️ THE GENERATED ACCESSORS READ ``copyLocale`` ON EVERY CALL, so a snapshot that changes
/// the language changes the next render, with no relaunch.
enum WatchL10n {
    enum CopyLocale: Equatable, Sendable {
        case en
        case frCA
    }

    /// The phone's language from the latest snapshot, `en` or `fr-CA`.
    ///
    /// ⚠️ `nonisolated(unsafe)` LIKE THE CORE'S `L10nRuntime.locale`: written on the main
    /// actor when a snapshot lands, read by the widget's timeline provider too. A torn read
    /// of a two-case value is not possible, and a stale one only delays a language change.
    nonisolated(unsafe) static var phoneLanguage: String?

    static var copyLocale: CopyLocale {
        resolve(
            phoneLanguage: phoneLanguage,
            preferred: Bundle.main.preferredLocalizations + Locale.preferredLanguages
        )
    }

    static func resolve(phoneLanguage: String?, preferred: [String]) -> CopyLocale {
        if let phoneLanguage {
            return isFrench(phoneLanguage) ? .frCA : .en
        }
        // ⚠️ THE FIRST TAG DECIDES, NOT THE FIRST FRENCH ONE: a watch set to English with
        // French second is an English watch.
        guard let first = preferred.first else { return .en }
        return isFrench(first) ? .frCA : .en
    }

    /// The locale for system-formatted text (a relative time).
    static var locale: Locale {
        copyLocale == .frCA ? Locale(identifier: "fr_CA") : Locale(identifier: "en_CA")
    }

    /// "5 min ago", in the watch's language.
    static func relative(_ date: Date, to now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = locale
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private static func isFrench(_ tag: String) -> Bool {
        tag.lowercased().hasPrefix("fr")
    }
}
