import DistrictL10n
import Foundation

/// The language the app writes in: its own screens (the `*Copy` enums, generated from
/// `l10n/ios.toml` into `Generated/Copy.swift`) and the core's sentences and formats.
///
/// ⛔ ONE VALUE FOR BOTH, AND IT IS THE CORE'S. ``L10nRuntime/locale`` is what
/// district-core-swift writes in, and the generated accessors read the same value
/// through ``copyLocale``, so a screen's own words and the core's error sentence or
/// date under them can never disagree about the language.
///
/// ⛔ FRENCH ONLY WHEN THIS BUILD SHIPS IT. Until the 3.0 build that includes
/// `project.fr.yml`, the bundle holds no French localization, and ``resolve`` answers
/// English whatever the device is set to. The catalog's French is incomplete until
/// then and the generated French branch carries the English, but the core's
/// formatters are already French (« 249,00 $ »), so a French device must not reach
/// them early.
enum AppL10n {
    /// The two languages the generated accessors know.
    ///
    /// ⚠️ THE APP'S OWN TYPE RATHER THAN ``L10nLocale``. The generated file imports
    /// nothing, so whatever it compares against has to be declared in this module.
    enum CopyLocale: Equatable {
        case en
        case frCA
    }

    /// What every generated accessor branches on.
    static var copyLocale: CopyLocale {
        L10nRuntime.locale == .frCA ? .frCA : .en
    }

    /// Sets the language at launch, and again whenever the device's language changes.
    ///
    /// ⚠️ iOS RELAUNCHES THE APP ON A LANGUAGE CHANGE IN SETTINGS, so the launch
    /// reading is the one that usually counts; the observer covers a locale change the
    /// process survives.
    static func bootstrap() {
        apply(bundle: .main)
        _ = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            apply(bundle: .main)
        }
    }

    /// The language for a bundle and a device's preferred languages.
    ///
    /// ⚠️ THE BUNDLE'S OWN ANSWER COMES FIRST. `preferredLocalizations` is the
    /// language iOS chose among the ones this build ships (the per-app language in
    /// Settings included), and the first tag the core speaks decides
    /// (``DistrictL10n/locale(fromPreferred:)``: any French is Canadian French). The
    /// device list after it only matters when the bundle answered nothing.
    static func resolve(
        preferredLocalizations: [String],
        preferredLanguages: [String],
        bundleLocalizations: [String]
    ) -> L10nLocale {
        guard bundleLocalizations.contains(where: { $0.lowercased().hasPrefix("fr") }) else {
            return .en
        }
        return DistrictL10n.locale(fromPreferred: preferredLocalizations + preferredLanguages)
    }

    private static func apply(bundle: Bundle) {
        L10nRuntime.locale = resolve(
            preferredLocalizations: bundle.preferredLocalizations,
            preferredLanguages: Locale.preferredLanguages,
            bundleLocalizations: bundle.localizations
        )
    }
}
