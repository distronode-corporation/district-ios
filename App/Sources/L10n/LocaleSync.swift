import DistrictL10n
import Foundation

/// Keeps the account's stored language (`User.locale`, which the server writes its emails
/// and pushes in) on the language the app resolved.
///
/// ⛔ ON SIGN-IN AND ON A LANGUAGE CHANGE, AND ONCE PER VALUE. The write is
/// `POST /api/settings` with `{profile:{locale:"en"|"fr"}}` (the core's
/// `AccountSettingsRepository.saveLocale`), sent when the session becomes signed in and
/// again when the device's language changes the resolved one (``AppL10n/didChange``). A
/// value already written in this process is not sent again; a failed write is retried at
/// the next of those moments rather than on a timer. Signing out forgets what was written,
/// so the next account gets its own write.
///
/// ⚠️ EVERY REQUEST ALREADY CARRIES THE LANGUAGE: the core's `ApiClient` sends
/// `Accept-Language` from `L10nRuntime.locale` (`fr-CA` or `en`). This is the stored half.
@MainActor
final class LocaleSync {
    private let save: (L10nLocale) async -> Bool
    private var written: L10nLocale?

    /// `save` answers whether the server took the value.
    init(save: @escaping (L10nLocale) async -> Bool) {
        self.save = save
    }

    /// The moment to check: the session's phase settled, or the language changed.
    func sync(signedIn: Bool, locale: L10nLocale = L10nRuntime.locale) async {
        guard signedIn else {
            written = nil
            return
        }
        guard written != locale else { return }
        if await save(locale) {
            written = locale
        }
    }
}
