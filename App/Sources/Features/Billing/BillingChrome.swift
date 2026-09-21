import SwiftUI

/// The card shell every billing section sits in: an eyebrow, then its content.
///
/// ⚠️ LOCAL TO THIS FEATURE RATHER THAN PROMOTED INTO `DesignSystem/`, and the same call
/// ``AnalyticsCard`` documents. Several screens have each written this same
/// `background(colors.card, in: RoundedRectangle(...))` inline; extracting them all into
/// one component is worth doing as a change of its own, touching every caller at once.
///
/// ⛔ THE GENERIC IS `Inner`, NOT `Content`. `View`'s own associated type is `Body`, but
/// the family of names that become accidental witnesses is wider than that (`Content`,
/// `Label`, `ID`, `Value`, `Configuration`), and a generic parameter is as capable of
/// colliding as a nested type. See the ⛔ in `DistrictButton.swift`.
struct BillingCard<Inner: View>: View {
    private let title: String
    private let inner: Inner

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    init(title: String, @ViewBuilder content: () -> Inner) {
        self.title = title
        inner = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            DistrictEyebrow(text: title)
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

/// The settled sentence a card shows when it has something to say rather than something
/// to show.
///
/// ⚠️ ITS OWN COMPONENT SO THE "nothing yet" CASES CANNOT DRIFT APART FROM EACH OTHER OR
/// FROM THE FAILURE TEXT. An unmetered month, an account with no Stripe customer and a
/// vendor outage are all answers rather than faults, and none of them may be typeset like
/// the red failure copy below.
struct BillingNote: View {
    let text: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(DistrictType.bodySmall)
            .foregroundStyle(DistrictColors.resolve(colorScheme).mutedForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The Stripe section's own transport failure.
///
/// ⚠️ A CARD, NOT A WHOLE-SCREEN STATE. The plan card above it came from a different
/// server and is still correct, so replacing everything with one message would discard
/// the half that survived.
///
/// ⚠️ AND THIS IS **NOT** HOW A STRIPE OUTAGE ARRIVES. That is a 200 carrying
/// `billingUnavailable` and renders as ``BillingUnavailableCard``. This one means the
/// request itself failed: an unreachable origin, a dead session, or a shape this build
/// cannot parse.
///
/// ⛔ THE RETRY IS OFFERED ONLY WHEN ``FailureText`` SAYS SO, exactly as ``FailureView``
/// does. Contract drift and a role refusal produce the identical failure on every
/// attempt, and a button that cannot work reads as a broken app.
struct BillingCardFailure: View {
    let title: String
    let failure: FailureText
    let onRetry: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        BillingCard(title: title) {
            Text(failure.message)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.destructive)
                .multilineTextAlignment(.leading)
            if case .retry = failure.action {
                Button(BillingCopy.retry, action: onRetry)
                    .buttonStyle(DistrictButtonStyle(variant: .ghost, size: .small))
            }
        }
    }
}
