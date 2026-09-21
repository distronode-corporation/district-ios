import DistrictModel
import Foundation
import SwiftUI

// The marketplace's cards: the search filters, a row of either list, the short-list
// banner and one half's own failure.
//
// ⚠️ SPLIT OUT OF `MarketplaceView.swift` FOR `swiftlint --strict`'s `file_length`
// ceiling, exactly as `AnalyticsCards.swift` was. That file owns the shell and the
// states; this one owns what a row looks like.
//
// ⚠️ A `//` HEADER RATHER THAN A `///` ONE, DELIBERATELY. SwiftFormat's `docComments`
// rule rejects a doc comment that is attached to no declaration, and a file header is
// exactly that.

/// The card shell every marketplace row and panel sits in.
///
/// ⚠️ LOCAL TO THIS FEATURE RATHER THAN PROMOTED INTO `DesignSystem/`, for the reason
/// ``AnalyticsCard``'s own ⚠️ gives: several screens have each written this same
/// background-plus-border inline, and extracting them all into one component is worth
/// doing as a change of its own rather than in passing.
///
/// ⛔ THE GENERIC IS `Inner`, NOT `Content`. `View`'s own associated type is `Body`,
/// but the family of names that become accidental witnesses is wider than that
/// (`Content`, `Label`, `ID`, `Value`, `Configuration`). See the ⛔ in
/// `DistrictButton.swift`.
struct MarketplacePanel<Inner: View>: View {
    private let inner: Inner

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    init(@ViewBuilder content: () -> Inner) {
        inner = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            inner
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DistrictSpacing.card)
        .background(colors.card, in: RoundedRectangle(cornerRadius: DistrictRadius.card))
        .overlay {
            RoundedRectangle(cornerRadius: DistrictRadius.card)
                .strokeBorder(colors.border, lineWidth: 1)
        }
    }
}

// MARK: - The search form

/// The search filters.
///
/// ⛔ THREE FIELDS, AND THE TWO THAT ARE MISSING ARE MISSING ON PURPOSE. The route
/// hardcodes its result limit (10) and its capability filter (sms+voice), so a page
/// size control or an "SMS only" toggle would be a control the server ignores, which
/// is worse than an absence because the operator would believe they had narrowed
/// something.
///
/// ⚠️ IT REUSES ``SettingsField`` RATHER THAN GROWING A FOURTH COPY OF THE SAME
/// LABELLED BOX. That type is the app's one "label above the field" control and it
/// already carries the disabled state; the name is where it was first written, not a
/// claim about where it may be used.
struct NumberSearchFormCard: View {
    let areaCode: Binding<String>
    let country: Binding<String>
    let selectedType: String
    let searching: Bool
    let onSelectType: (String) -> Void
    let onSearch: () -> Void

    var body: some View {
        MarketplacePanel {
            VStack(alignment: .leading, spacing: DistrictSpacing.row) {
                SettingsField(label: MarketplaceCopy.areaCodeLabel, text: areaCode, enabled: !searching)
                SettingsField(label: MarketplaceCopy.countryLabel, text: country, enabled: !searching)
                types
                Button(MarketplaceCopy.searchAction, action: onSearch)
                    .buttonStyle(.districtPrimary)
                    .disabled(searching)
            }
        }
    }

    /// ⚠️ THE THREE VALUES THE ROUTE ACCEPTS. Anything else is silently ignored
    /// server-side, so a fourth chip would be a control that changes nothing.
    private var types: some View {
        HStack(spacing: DistrictSpacing.tight) {
            chip(MarketplaceCopy.typeLocalLabel, value: MarketplaceCopy.numberTypeLocal)
            chip(MarketplaceCopy.typeTollFreeLabel, value: MarketplaceCopy.numberTypeTollFree)
            chip(MarketplaceCopy.typeMobileLabel, value: MarketplaceCopy.numberTypeMobile)
            Spacer(minLength: 0)
        }
    }

    private func chip(_ label: String, value: String) -> some View {
        Button(label) { onSelectType(value) }
            .buttonStyle(DistrictButtonStyle(variant: selectedType == value ? .primary : .secondary))
            .disabled(searching)
    }
}

// MARK: - Search results

struct SearchResultsList: View {
    let provider: String
    let numbers: [AvailableNumber]

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            carrier
            if numbers.isEmpty {
                // ⚠️ REACHABLE ONLY ONCE A SEARCH SUCCEEDED, so it genuinely means
                // the carrier has nothing matching these filters. Never "we could not
                // look", which is the failure card next door.
                EmptyStateView(
                    systemImage: "magnifyingglass",
                    title: MarketplaceCopy.searchEmptyTitle,
                    message: MarketplaceCopy.searchEmptyBody
                )
            } else {
                ForEach(numbers, id: \.phoneNumber) { number in
                    AvailableNumberRow(number: number)
                }
            }
        }
    }

    /// ⚠️ THE CARRIER THAT ACTUALLY ANSWERED, which need not be the one the operator
    /// expected: the resolved credentials decide, not the request. Blank counts as
    /// absent rather than rendering "Carrier: ".
    @ViewBuilder
    private var carrier: some View {
        if !provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            DistrictEyebrow(text: MarketplaceCopy.carrier(provider))
        }
    }
}

/// One number the carrier has for sale.
///
/// ⛔ NO CONTROL OF ANY KIND ON THIS ROW, WHICH IS THE POINT OF THE SCREEN. Buying is
/// a recurring carrier charge and it happens on the web; see the ⛔ at the top of
/// ``MarketplaceView``.
private struct AvailableNumberRow: View {
    let number: AvailableNumber

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        MarketplacePanel {
            Text(number.phoneNumber)
                .font(DistrictType.title)
                .foregroundStyle(colors.foreground)
            locality
            Text(capabilities)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
            price
        }
    }

    /// ⚠️ ABSENT ON A TOLL-FREE RESULT, which has no locality to report, so the line
    /// is dropped rather than drawn empty.
    @ViewBuilder
    private var locality: some View {
        if !localityText.isEmpty {
            Text(localityText)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.foreground)
        }
    }

    /// ⚠️ A BLANK PART IS DROPPED RATHER THAN JOINED. `[nil, "ON"]` joined naively
    /// renders ", ON", which reads as a missing value rather than as a toll-free
    /// number that has no locality.
    private var localityText: String {
        [number.locality, number.region].compactMap(Self.nonBlank).joined(separator: ", ")
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// ⚠️ PRESENT AND POSSIBLY EMPTY rather than absent, so an empty list falls back
    /// to the number's type instead of leaving a blank line.
    private var capabilities: String {
        let joined = number.capabilities.joined(separator: " · ")
        return joined.isEmpty ? number.type : joined
    }

    /// ⛔ AN ABSENT PRICE MEANS "not published", NOT "free". The carrier's pricing
    /// lookup fails independently of the search that returned the number and the key
    /// is then missing from the wire entirely, so rendering a zero here would quote a
    /// price nobody was given. See ``MarketplaceCopy/priceLabel(monthlyPrice:currency:)``.
    @ViewBuilder
    private var price: some View {
        if let label = MarketplaceCopy.priceLabel(monthlyPrice: number.monthlyPrice, currency: number.currency) {
            Text(label)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.foreground)
        }
    }
}

// MARK: - My numbers

/// The owned-number list, and the tap that opens one number's own actions.
///
/// ⛔ THE ROW IS TAPPABLE AND THE PANEL BEHIND IT CARRIES AN IRREVERSIBLE CONTROL, so the
/// tap opens a sheet rather than committing anything. ⚠️ A managed row is still tappable
/// deliberately: the sheet is where the operator is TOLD the line is not theirs to administer,
/// and a row that simply did not respond would read as a broken list.
struct OwnedNumbersList: View {
    let numbers: [ListedNumber]
    let partial: Bool
    let failedProviders: [String]
    let onSelect: (ListedNumber) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            // ⛔ THE BANNER SITS ABOVE THE ROWS AND DOES NOT REPLACE THEM. The list is
            // real but short: a carrier did not answer, so numbers the workspace owns
            // may be missing. A banner instead of the rows would discard an answer
            // already in hand, and rows with no banner would draw an incomplete list
            // as a complete one.
            if partial {
                PartialBanner(failedProviders: failedProviders)
            }
            if numbers.isEmpty {
                EmptyStateView(
                    systemImage: "phone",
                    title: MarketplaceCopy.ownedEmptyTitle,
                    message: MarketplaceCopy.ownedEmptyBody
                )
            } else {
                ForEach(numbers, id: \.phoneNumber) { number in
                    Button { onSelect(number) } label: {
                        ListedNumberRow(number: number)
                    }
                    .buttonStyle(.plain)
                    // ⚠️ THE ROW OPENS THE ACTIONS SHEET, IT DOES NOT RELEASE ANYTHING.
                    // The irreversible control lives in `NumberActionsSheet` behind a
                    // confirmation and is in `UITestApp.forbiddenSurfaces`; a test may
                    // open this row and read it.
                    .accessibilityIdentifier(A11yID.Marketplace.row(number.phoneNumber))
                }
            }
        }
    }
}

/// One owned number, wrapped so it can present a sheet.
///
/// ⛔ A WRAPPER RATHER THAN `extension ListedNumber: Identifiable`. A retroactive conformance
/// on a type this module does not own is the shape that breaks the day `DistrictModel` adds
/// its own, and Swift 6 warns about exactly that. The identity is the E.164 number, which is
/// the row's identity on the wire too.
struct SelectedNumber: Identifiable {
    let number: ListedNumber

    var id: String {
        number.phoneNumber
    }
}

/// One line the workspace already has, whoever supplies it.
private struct ListedNumberRow: View {
    let number: ListedNumber

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        MarketplacePanel {
            Text(number.phoneNumber)
                .font(DistrictType.title)
                .foregroundStyle(colors.foreground)
            friendlyName
            Text(MarketplaceCopy.numberMeta(provider: number.provider, status: number.status))
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
            managed
        }
    }

    /// ⚠️ ABSENT ON A ROW THE CARRIER NEVER NAMED, and a blank one counts as absent.
    @ViewBuilder
    private var friendlyName: some View {
        if let name = number.friendlyName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(name)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.foreground)
        }
    }

    /// ⛔ THE BADGE IS NOT COSMETIC. The release control lives on the sheet behind this
    /// row, and this flag is what withholds it. `managed` means the line is held on
    /// Distronode's carrier account rather than the tenant's, so it is theirs to USE and not to administer — and
    /// ``NumberActionsSheet`` says that in words rather than just omitting the buttons.
    @ViewBuilder
    private var managed: some View {
        if number.managed {
            DistrictBadge(text: MarketplaceCopy.managed, tone: .info)
                .padding(.top, DistrictSpacing.hairline)
        }
    }
}

/// The short-list banner, naming the carrier that did not answer.
///
/// ⛔ NOT A ``DistrictBadge``, THOUGH ANDROID USES ITS OWN. This client's badge is a
/// pill: it pins `lineLimit(1)` and a horizontal `fixedSize`, deliberately, so a
/// sentence put through it would report one enormous width and overflow the row
/// rather than wrapping. Its own ⚠️ says so. A wrapping warning strip is the same
/// meaning in the shape this design system has for it.
private struct PartialBanner: View {
    let failedProviders: [String]

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        HStack(alignment: .top, spacing: DistrictSpacing.tight) {
            // ⚠️ DECORATION. The banner's own sentence, immediately to its right,
            // names the providers that failed.
            Image(systemName: "exclamationmark.triangle")
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.warning)
                .accessibilityHidden(true)
            Text(MarketplaceCopy.partialBanner(failedProviders))
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DistrictSpacing.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tone.warning.fill(colors), in: RoundedRectangle(cornerRadius: DistrictRadius.card))
    }
}

// MARK: - Failure

/// One half's own failure, with a retry only when retrying could help.
///
/// ⚠️ A CARD, NOT A WHOLE-SCREEN STATE, exactly as ``WorkflowFailureCard`` and
/// ``AnalyticsCardFailure`` are: the other tab may have answered perfectly, and
/// replacing everything with one message would discard a correct answer already in
/// hand.
///
/// ⛔ THE RETRY IS OFFERED ONLY WHEN ``FailureText`` SAYS SO. A role refusal and a
/// contract mismatch produce the identical failure on every attempt, and a button
/// that cannot work reads as a broken app.
struct MarketplaceFailureCard: View {
    let title: String
    let failure: FailureText
    let onRetry: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        MarketplacePanel {
            VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
                Text(title)
                    .font(DistrictType.titleSmall)
                    .foregroundStyle(colors.foreground)
                Text(failure.message)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.mutedForeground)
                if case .retry = failure.action {
                    Button(MarketplaceCopy.retry, action: onRetry)
                        .buttonStyle(.districtSecondary)
                }
            }
        }
    }
}
