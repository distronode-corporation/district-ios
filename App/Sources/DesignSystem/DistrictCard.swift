import SwiftUI

/// The card shell: an optional eyebrow over its content, on the card surface.
///
/// ⛔ ONE SHELL FOR EVERY FEATURE. Analytics, Billing, Support, the Marketplace and
/// Settings each used to carry their own copy of this view, and about twenty screens
/// wrote the background-plus-border inline; they had drifted on spacing and on whether a
/// border was drawn. A card design change is now one edit here. The Android client has
/// the same component under the same name.
///
/// ⚠️ `spacing` IS THE ONE THING A FEATURE STILL CHOOSES. Settings and scheduling cards
/// space their rows at ``DistrictSpacing/row`` (see ``SettingsCard``), a marketplace row
/// at ``DistrictSpacing/hairline``, everything else at the default.
///
/// ⛔ THE GENERIC IS `Inner`, NOT `Content`. `View`'s own associated type is `Body`, but
/// the family of names that become accidental witnesses is wider than that (`Content`,
/// `Label`, `ID`, `Value`, `Configuration`), and a generic parameter is as capable of
/// colliding as a nested type. See the ⛔ in `DistrictButton.swift`.
struct DistrictCard<Inner: View>: View {
    private let eyebrow: String?
    private let spacing: CGFloat
    private let bordered: Bool
    private let inner: Inner

    init(
        eyebrow: String? = nil,
        spacing: CGFloat = DistrictSpacing.tight,
        bordered: Bool = true,
        @ViewBuilder content: () -> Inner
    ) {
        self.eyebrow = eyebrow
        self.spacing = spacing
        self.bordered = bordered
        inner = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let eyebrow {
                DistrictEyebrow(text: eyebrow)
            }
            inner
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DistrictSpacing.card)
        .districtCardSurface(bordered: bordered)
    }
}

extension View {
    /// The card's fill and corner, plus its one-point border unless `bordered` is false.
    ///
    /// ⚠️ PADDING AND WIDTH ARE THE CALLER'S. A list of rows inside a card carries its
    /// own insets and a video tile its own size, so this is the surface only;
    /// ``DistrictCard`` adds the standard padding for a titled panel.
    func districtCardSurface(bordered: Bool = true) -> some View {
        modifier(DistrictCardSurface(bordered: bordered))
    }
}

private struct DistrictCardSurface: ViewModifier {
    let bordered: Bool

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let colors = DistrictColors.resolve(colorScheme)
        content
            .background(colors.card, in: RoundedRectangle(cornerRadius: DistrictRadius.card))
            .overlay {
                if bordered {
                    RoundedRectangle(cornerRadius: DistrictRadius.card)
                        .strokeBorder(colors.border, lineWidth: 1)
                }
            }
    }
}

/// A label over a value, in an unbordered card: the call and contact detail screens'
/// field shape.
struct DetailFieldCard: View {
    let label: String
    let value: String

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(label)
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
            Text(value)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.foreground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DistrictSpacing.gutter)
        .districtCardSurface(bordered: false)
    }
}

/// One KPI tile, on the Overview and on Analytics.
///
/// ⚠️ THE LABEL IS THE MONO EYEBROW, NOT A BOLD SMALL HEADING. Android's tiles used
/// `labelSmall` at Material's default weight, which read as a heading competing with
/// the number beneath it; the eyebrow demotes it to an annotation so the value is
/// unambiguously the subject.
struct DistrictMetricTile: View {
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
        .districtCardSurface()
        // ⚠️ THE LABEL AND VALUE ARE ONE ANNOUNCEMENT. Read separately a screen
        // reader says "Total Calls Routed" then "412" with no stated relationship;
        // paired, the tile announces itself as a fact.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
    }
}
