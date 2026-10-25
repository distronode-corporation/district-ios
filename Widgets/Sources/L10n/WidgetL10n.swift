import Foundation

/// Every sentence the widget extension says. Generated from `l10n/widgets.toml` into
/// `Generated/Copy.swift`; this enum is empty and exists for that file to extend.
enum WidgetCopy {}

/// The language the Live Activity writes in.
///
/// ⚠️ THE BUNDLE'S OWN RESOLUTION, the rule the app and the watch keep: the extension ships
/// `en.lproj` and `fr-CA.lproj` only, so iOS resolves any French (and the per-app language
/// the person set for District AI) to `fr-CA`, and everything else to English.
enum WidgetL10n {
    enum CopyLocale: Equatable, Sendable {
        case en
        case frCA
    }

    static var copyLocale: CopyLocale {
        resolve(Bundle.main.preferredLocalizations + Locale.preferredLanguages)
    }

    static func resolve(_ preferred: [String]) -> CopyLocale {
        guard let first = preferred.first else { return .en }
        return first.lowercased().hasPrefix("fr") ? .frCA : .en
    }

    /// The locale for system-formatted text (a time of day).
    static var locale: Locale {
        copyLocale == .frCA ? Locale(identifier: "fr_CA") : Locale(identifier: "en_CA")
    }
}
