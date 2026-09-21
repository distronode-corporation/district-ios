import SwiftUI

/// The card shell every analytics section sits in: an eyebrow, then its content.
///
/// ⚠️ LOCAL TO THIS FEATURE RATHER THAN PROMOTED INTO `DesignSystem/`. The Android
/// client has a shared `DistrictCard`; this one does not yet, and three screens have
/// each written the same `background(colors.card, in: RoundedRectangle(...))` inline
/// (`CallDetailCard`, `AccountView`, `OverviewView`'s tile). Extracting all four into
/// one component is worth doing as a change of its own, touching every caller at once.
///
/// ⛔ THE GENERIC IS `Inner`, NOT `Content`. `View`'s own associated type is `Body`,
/// but the family of names that become accidental witnesses is wider than that
/// (`Content`, `Label`, `ID`, `Value`, `Configuration`), and a generic parameter is
/// as capable of colliding as a nested type. See the ⛔ in `DistrictButton.swift`.
struct AnalyticsCard<Inner: View>: View {
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

/// One card area's own failure.
///
/// ⚠️ A CARD, NOT A WHOLE-SCREEN STATE. The other reads on this screen may have
/// answered fine, and replacing everything with one message would discard a correct
/// answer already on screen. The whole-screen ``FailureView`` is reached only when
/// every read failed.
///
/// ⛔ THE RETRY IS OFFERED ONLY WHEN ``FailureText`` SAYS SO, exactly as
/// ``FailureView`` does. Contract drift and a role refusal produce the identical
/// failure on every attempt, and a button that cannot work reads as a broken app.
/// ⚠️ A `signIn` failure therefore draws no control here: this screen is a pushed
/// destination with nowhere to send a sign-in, and the sentence still says what
/// happened. That is the case ``FailureView``'s own optional handlers exist for.
struct AnalyticsCardFailure: View {
    let title: String
    let failure: FailureText
    let onRetry: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        AnalyticsCard(title: title) {
            Text(failure.message)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.destructive)
                .multilineTextAlignment(.leading)
            if case .retry = failure.action {
                Button("Try again", action: onRetry)
                    .buttonStyle(DistrictButtonStyle(variant: .ghost, size: .small))
            }
        }
    }
}

/// One KPI tile.
///
/// ⚠️ THE LABEL IS THE MONO EYEBROW, matching the Overview's tiles: it demotes the
/// label to an annotation so the number is unambiguously the subject.
struct AnalyticsMetricTile: View {
    let label: String
    let value: String
    let caption: String

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            DistrictEyebrow(text: label)
            Text(value)
                .font(DistrictType.metric)
                .foregroundStyle(colors.foreground)
            Text(caption)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DistrictSpacing.card)
        .background(colors.card, in: RoundedRectangle(cornerRadius: DistrictRadius.card))
        .overlay {
            RoundedRectangle(cornerRadius: DistrictRadius.card)
                .strokeBorder(colors.border, lineWidth: 1)
        }
        // ⚠️ THE LABEL AND VALUE ARE ONE ANNOUNCEMENT. Read separately a screen
        // reader says the label and then a bare number with no stated relationship.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
    }
}

/// A labelled metered amount.
///
/// ⛔ AN ABSENT AMOUNT IS LABELLED, NEVER PRINTED AS ZERO. "We do not meter this for
/// you" and "we metered it and it was zero" are different facts, and only one of
/// them may appear as `0` beside a billing label. See ``AnalyticsFormat/absent``.
struct AnalyticsAmountRow: View {
    let label: String
    let amount: Double?

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DistrictSpacing.tight) {
            Text(label)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(amount.map(AnalyticsFormat.amount) ?? AnalyticsFormat.absent)
                .font(DistrictType.bodySmall)
                .foregroundStyle(amount == nil ? colors.mutedForeground : colors.foreground)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The settled sentence a card shows when it has nothing to draw.
///
/// ⚠️ ITS OWN COMPONENT SO THE THREE "nothing yet" CASES CANNOT DRIFT APART. An
/// empty trend, an unmetered month and an unmetered history are all absences rather
/// than failures, and they must not be typeset like the red failure text above.
struct AnalyticsNote: View {
    let text: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(DistrictType.bodySmall)
            .foregroundStyle(DistrictColors.resolve(colorScheme).mutedForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
