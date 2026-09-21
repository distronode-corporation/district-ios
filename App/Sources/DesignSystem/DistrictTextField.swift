import SwiftUI

/// The one text-entry treatment, on the palette rather than the platform's.
///
/// ⛔ `.textFieldStyle(.roundedBorder)` PAINTS A NEAR-BLACK BOX THAT APPEARS IN NO
/// PALETTE, AND IT BECOMES THE MOST VISIBLE COLOUR ON A SETTINGS SCREEN. Measured in
/// the simulator: `#000000` covered **16.9% of the Agent persona screen**, as
/// UIKit-drawn black boxes sitting on `#16292D` cards on an
/// `#0E1C1F` page. The system style supplies its own fill and ignores everything
/// around it, so a field that sets no background does not inherit the card's, it
/// gets UIKit's — which is the same failure shape as ``ShellBackground``'s
/// `NavigationStack`, one level further in.
///
/// ⛔ `input` IS THE TOKEN FOR THIS. ``DistrictColors/input`` is documented "Field
/// border and fill" and exists for exactly this job; a field that uses the platform's
/// colour or reaches for ``DistrictColors/muted`` instead is a second treatment. There
/// is one, and a new field gets it by calling ``View/districtField()``
/// rather than by copying six modifiers off a neighbour.
///
/// ⚠️ A `ViewModifier`, NOT A `TextFieldStyle`, AND THE REASON IS THE PALETTE READ.
/// `DistrictColors` is resolved from `colorScheme` per view (see the ⛔ on
/// ``DistrictTheme``), and a `TextFieldStyle` is not a `View`, so an
/// `@Environment` property on one never updates. The idiom here is
/// ``View/districtBackground()``'s. It also means the treatment covers `SecureField`,
/// which a `TextFieldStyle` reaches only by accident of the environment.
///
/// ⚠️ THE STROKE IS ``DistrictColors/border``, MATCHING ``SettingsCard``, rather than
/// `input` again. It reads as an inset edge in both schemes: in dark the border is a
/// step below the fill, in light a step above it, and in both it sits between the fill
/// and the card behind it.
private struct DistrictFieldModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(DistrictType.bodySmall)
            .foregroundStyle(colors.foreground)
            .padding(DistrictSpacing.tight)
            .background(colors.input, in: RoundedRectangle(cornerRadius: DistrictRadius.control))
            .overlay {
                RoundedRectangle(cornerRadius: DistrictRadius.control)
                    .strokeBorder(colors.border, lineWidth: 1)
            }
    }
}

extension View {
    /// Put the District field treatment on this `TextField` or `SecureField`.
    ///
    /// ⛔ REPLACES `.textFieldStyle(_:)` AT THE CALL SITE, it does not sit beside one:
    /// this applies `.plain` itself, and a `.roundedBorder` left below it would win and
    /// repaint the platform's box inside the palette's.
    ///
    /// ⚠️ GOES LAST IN THE CHAIN, AND THAT IS A DELIBERATE CONVENTION RATHER THAN A
    /// REQUIREMENT. Keyboard type, content type, capitalisation, autocorrection, submit
    /// label and `disabled` all travel through the environment, so they would reach the
    /// field from outside the padding too — but "would" is a claim about SwiftUI that
    /// nothing in this repo can compile, let alone assert. Put it last and every
    /// existing modifier keeps sitting exactly where it sat on the bare field, so the
    /// only thing this changes is the decoration.
    ///
    /// ⚠️ THE PLACEHOLDER IS THE ONE THING IT CANNOT REACH. Its colour is not
    /// inherited from `foregroundStyle`, so a caller that wants it on the palette
    /// passes a styled `prompt:` (see ``SettingsField``).
    func districtField() -> some View {
        modifier(DistrictFieldModifier())
    }
}
