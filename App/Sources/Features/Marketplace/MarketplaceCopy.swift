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
    static let title = "Phone numbers"

    static let tabOwned = "My numbers"

    static let tabSearch = "Search"

    // MARK: - The search form

    static let areaCodeLabel = "Area code"

    static let countryLabel = "Country"

    static let typeLocalLabel = "Local"

    static let typeTollFreeLabel = "Toll-free"

    static let typeMobileLabel = "Mobile"

    static let searchAction = "Search available numbers"

    /// ⛔ THE THREE VALUES THE ROUTE ACCEPTS. Anything else is silently ignored
    /// server-side, so a fourth chip here would be a control that changes nothing.
    static let numberTypeLocal = "local"

    static let numberTypeTollFree = "tollFree"

    static let numberTypeMobile = "mobile"

    /// ⚠️ THE SERVER'S OWN DEFAULT, so an untouched form sends exactly what an
    /// omitted parameter would.
    static let defaultCountry = "US"

    // MARK: - Results

    /// ⚠️ THE CARRIER THAT ACTUALLY ANSWERED, which need not be the one the operator
    /// expected: the resolved credentials decide, not the request.
    static func carrier(_ provider: String) -> String {
        "Carrier: \(provider)"
    }

    static func numberMeta(provider: String, status: String) -> String {
        "\(provider) · \(status)"
    }

    /// ⛔ NOT COSMETIC. `managed` means the line is held on Distronode's carrier
    /// account rather than the tenant's, so it is theirs to USE and not to
    /// administer, which is why no release control is offered for it.
    static let managed = "Managed by Distronode"

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
            return "A carrier did not answer, so this list may be missing numbers."
        }
        let named = failedProviders.joined(separator: ", ")
        return "Could not reach \(named), so this list may be missing numbers."
    }

    /// ⚠️ REACHABLE ONLY ONCE A SEARCH SUCCEEDED, so it genuinely means the carrier
    /// has nothing matching. Never "we could not look".
    static let searchEmptyTitle = "No matches"

    static let searchEmptyBody = "The carrier has no numbers matching these filters. "
        + "Try a different area code or number type."

    static let ownedEmptyTitle = "No numbers yet"

    static let ownedEmptyBody = "This workspace has no active phone numbers."

    // MARK: - Failures

    /// ⛔ AN ACCOUNT STATE, NOT A FAULT, AND IT OFFERS NO RETRY. The workspace has
    /// not connected a carrier, which no amount of retrying changes. A red failure
    /// here would tell an operator their app is broken when the truth is that their
    /// setup is unfinished.
    static let notConfiguredTitle = "No carrier connected"

    /// ⚠️ WHAT A BLANK SERVER MESSAGE DEGRADES TO. The route's own sentence is shown
    /// whenever there is one, because it distinguishes "no provider configured for
    /// this workspace" from "the provider you named is not connected" and this layer
    /// cannot.
    static let notConfiguredFallback = "This workspace has no carrier connected yet. "
        + "A carrier cannot be connected in this app."

    static let searchFailed = "Could not search for numbers."

    static let ownedFailed = "Could not load this workspace's numbers."

    static let retry = "Try again"

    // MARK: - The read-only boundary

    /// ⛔ ONLY THE PURCHASE IS OUT OF REACH. Releasing and reconfiguring are in the app,
    /// on their own tab, behind confirmations, and ``purchaseElsewhere`` is the line that
    /// says the purchase is not.
    ///
    /// ⛔ WHAT IT STILL DOES IS MAKE A BOUNDARY LEGIBLE WITHOUT LINKING IT OR NAMING ANY
    /// DESTINATION. App Store Review Guideline 3.1.1 covers steering as well as the purchase,
    /// and naming the place in prose IS the steering, so this sentence points inward at the
    /// other tabs — the same call ``BillingCopy/readOnly`` makes for its own guideline.
    static let readOnly = "Everything else about your numbers is on the other tabs."

    /// ⚠️ A VIEWER CANNOT MAKE THE CHANGE ANYWHERE ELSE EITHER, so a signpost would be
    /// useless advice on top of being steering. They are told who can.
    static let readOnlyViewer = "Changing a number needs an agency or client role. Ask someone "
        + "on this workspace who has one."

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
    static func priceLabel(monthlyPrice: Double?, currency: String?) -> String? {
        guard let monthlyPrice else { return nil }
        let amount = String(monthlyPrice)
        guard let currency else { return amount }
        let trimmed = currency.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? amount : "\(amount) \(trimmed)"
    }
}
