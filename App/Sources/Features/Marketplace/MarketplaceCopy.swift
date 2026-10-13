import DistrictL10n
import Foundation

/// Every sentence the phone-number marketplace says, and the three filter values the
/// route accepts.
///
/// ⛔ NO URL, NO LINK AND NO CALL TO ACTION POINTING AT A PURCHASE, and the absence is
/// the point. See the ⛔ on ``MarketplaceView`` for why; ``readOnly`` states the boundary
/// and names nowhere, exactly as ``BillingCopy/readOnly`` does. `StoreCopyTests` holds
/// that line.
///
/// ⚠️ ITS OWN FILE RATHER THAN AN EXTENSION AT THE BOTTOM OF THE SCREEN, the same
/// call ``DialerCopy`` and ``WorkflowsCopy`` make: `swiftlint --strict` promotes the
/// `file_length` WARNING at 500 lines to an error, and the view already carries two
/// tabs' worth of states.
///
/// ⛔ THE COPY IS ANDROID'S, and the Android client's string resources carry the same
/// wording. Four of them are load bearing rather than decorative:
/// "No matches" rather than an error, "No carrier connected" rather than a failure,
/// "Managed by Distronode" rather than a row that looks like the tenant's own, and the
/// read-only caption stating the boundary rather than linking or naming one.
///
/// ⚠️ ONE STRING IS DELIBERATELY NOT BYTE-IDENTICAL TO ANDROID'S. Its
/// `marketplace_read_only` joins the two halves of the sentence with an em-dash;
/// this client's copy uses commas, periods or parentheses instead, so the dash is a
/// comma here. Nothing else about the wording differs.
enum MarketplaceCopy {
    // MARK: - The search form

    /// ⛔ THE THREE VALUES THE ROUTE ACCEPTS. Anything else is silently ignored
    /// server-side, so a fourth chip here would be a control that changes nothing.
    static let numberTypeLocal = "local"

    static let numberTypeTollFree = "tollFree"

    static let numberTypeMobile = "mobile"

    // MARK: - Results

    /// ⛔ NAMES THE CARRIER SO "the list may be short" IS ACTIONABLE RATHER THAN
    /// OMINOUS. Shown ABOVE the rows, never instead of them.
    ///
    /// ⚠️ THE UNNAMED FALLBACK IS NOT DEAD CODE. ``OwnedNumbersResponse`` documents
    /// `failedProviders` as non-empty exactly when `partial` is true, which is a
    /// claim about the server rather than a guarantee of the wire; if the flag ever
    /// arrives without the names, saying a carrier did not answer is still a truer
    /// answer than drawing a short list as a complete one.
    static func partialBanner(_ failedProviders: [String]) -> String {
        guard !failedProviders.isEmpty else {
            return partialBannerUnnamed
        }
        let named = failedProviders.joined(separator: ", ")
        return partialBannerNamed(named)
    }

    // MARK: - Derived values

    /// A monthly price, ready to show.
    ///
    /// ⛔ NIL IN, NIL OUT. A missing price is not zero and must not be rendered as
    /// one: the carrier's pricing lookup fails independently of the search that
    /// returned the number, and the key is then absent from the wire entirely. A
    /// rendered "0" would quote a price nobody was given.
    ///
    /// ⚠️ AND NO SYMBOL WITHOUT A CURRENCY. `monthlyPrice` and `currency` are
    /// separate optional fields, so a price whose currency the server did not send is
    /// shown bare rather than guessed at. ⚠️ The amount is the raw value rather than
    /// a locale-formatted one, matching Android: a currency-aware formatter needs a
    /// currency, which is exactly the thing that may be missing here.
    ///
    /// ⚠️ ENGLISH KEEPS THE RAW VALUE IT HAS ALWAYS SHOWN. In French a price with its
    /// currency goes through the core's money table (`L10nFormat.isoAmount`, « 1,50 $ US »),
    /// and one without stays a bare number in French digits.
    static func priceLabel(monthlyPrice: Double?, currency: String?) -> String? {
        guard let monthlyPrice else { return nil }
        guard L10nRuntime.locale == .en else {
            let code = currency?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return code.isEmpty
                ? L10nFormat.number(monthlyPrice)
                : L10nFormat.isoAmount(monthlyPrice, isoCode: code)
        }
        let amount = String(monthlyPrice)
        guard let currency else { return amount }
        let trimmed = currency.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? amount : "\(amount) \(trimmed)"
    }
}
