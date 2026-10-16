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
/// ⛔ THE WEB'S FIELD GRAMMAR: A `card` GROUND INSIDE A 1PX `input` BORDER (3.0.2, visual QA
/// AP-021). Until 3.0.2 the field was FILLED with ``DistrictColors/input``, a mid-grey box in
/// light mode, on which the muted placeholder measured 4.34:1 in dark, short of AA; the
/// site's `.form` fields (`ledger.css`) take `card` with an `input` edge, and on `card` the
/// same placeholder is 6.07:1 (dark) and 7.41:1 (light). A field that uses the platform's
/// colour or reaches for ``DistrictColors/muted`` instead is a second treatment. There is
/// one, and a new field gets it by calling ``View/districtField()`` rather than by copying
/// six modifiers off a neighbour.
///
/// ⚠️ A `ViewModifier`, NOT A `TextFieldStyle`, AND THE REASON IS THE PALETTE READ.
/// `DistrictColors` is resolved from `colorScheme` per view (see the ⛔ on
/// ``DistrictTheme``), and a `TextFieldStyle` is not a `View`, so an
/// `@Environment` property on one never updates. The idiom here is
/// ``View/districtBackground()``'s. It also means the treatment covers `SecureField`,
/// which a `TextFieldStyle` reaches only by accident of the environment.
///
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
            .background(colors.card, in: RoundedRectangle(cornerRadius: DistrictRadius.control))
            .overlay {
                RoundedRectangle(cornerRadius: DistrictRadius.control)
                    .strokeBorder(colors.input, lineWidth: 1)
            }
    }
}

extension Text {
    /// The prompt of a field whose label is already drawn beside it: none.
    ///
    /// ⚠️ THE LABEL STAYS THE FIELD'S TITLE, SO ASSISTIVE TECHNOLOGY STILL NAMES IT (3.0.2,
    /// visual QA AP-021). Without a prompt a `TextField` shows its title as the placeholder,
    /// which repeated the label printed just above it, word for word.
    static var noPlaceholder: Text {
        Text(verbatim: "")
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
    /// inherited from `foregroundStyle`, so a caller that wants one on the palette
    /// passes a styled `prompt:`; a field with its label drawn beside it passes
    /// ``Text/noPlaceholder``.
    func districtField() -> some View {
        modifier(DistrictFieldModifier())
    }
}
