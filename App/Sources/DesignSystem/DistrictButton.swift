import SwiftUI

/// The button variants, ported from the web's button classes by way of
/// Android's `DistrictButton.kt`.
///
/// ⛔ `primary` PUTS DARK TEXT ON THE INDIGO IN DARK MODE, WHICH LOOKS WRONG UNTIL
/// YOU CHECK THE CONTRAST. The dark accent is a LIGHT indigo, so white on it fails
/// WCAG AA while `district-foreground`'s near-black passes comfortably; in light
/// mode the accent is a DEEP indigo and the same token is white. Both come from
/// the web's `tokens.css`; it is a contrast decision, not a style
/// flourish. See ``DistrictColors/districtForeground``.
///
/// ⚠️ THE WEB'S PRIMARY BUTTON IS `filled`, NOT `district`, AND THIS ONE HAS NOT
/// MOVED. The Ledger fills its primary button with `--filled` / `--filled-foreground`,
/// a token ``DistrictColors`` does not carry. This stays on the accent until that
/// token is added deliberately.
///
/// ⚠️ `destructive` IS A TINTED OUTLINE, NOT A RED FILL. The web uses
/// `bg-destructive/10 text-destructive border-destructive/25`, because a solid red
/// fill reads as "this already went wrong" rather than "this action is
/// destructive". The solid destructive colour is reserved for actual error
/// surfaces.
enum DistrictButtonVariant {
    case primary
    case secondary
    case ghost
    case destructive
}

/// `medium` is the default (40pt, 14pt text); `small` (32pt, 12pt) is for dense
/// toolbars.
///
/// ⚠️ 32pt is BELOW Apple's 44pt touch-target guidance and it is on the web's spec,
/// so `small` is for pointer-dense surfaces only. Anything a thumb reaches for
/// should be `medium`.
enum DistrictButtonSize {
    case small
    case medium

    /// ⛔ 44 FOR BOTH, WHICH IS APPLE'S MINIMUM TOUCH TARGET AND NOT A STYLE CHOICE.
    /// `.small` was 32 and `.medium` 40; both are under the 44x44 the Human Interface
    /// Guidelines require and both are reachable by anyone with a tremor or a large
    /// finger, not only by someone using an accessibility setting. ⚠️ It is a MINIMUM,
    /// so a button whose scaled label is taller still grows past it.
    var minHeight: CGFloat {
        44
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .small: 12
        case .medium: 16
        }
    }

    /// ⚠️ `DistrictFont` RATHER THAN `Font`, since the tokens are descriptors now:
    /// the `.font(_:)` overload resolves them through `@ScaledMetric`. Returning a
    /// `Font` here would compile only by discarding the scaling.
    var font: DistrictFont {
        switch self {
        case .small: DistrictType.label
        case .medium: DistrictType.labelLarge
        }
    }
}

/// A District button.
///
/// ⚠️ A `ButtonStyle` RATHER THAN A BESPOKE VIEW, so every button keeps SwiftUI's
/// accessibility traits, its disabled semantics and its default hit testing for
/// free. Only the colours, shape and metrics are overridden.
struct DistrictButtonStyle: ButtonStyle {
    var variant: DistrictButtonVariant = .primary
    var size: DistrictButtonSize = .medium

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(variant: variant, size: size, configuration: configuration)
    }

    /// ⛔ A NESTED VIEW RATHER THAN `@Environment` ON THE STYLE ITSELF. A
    /// `ButtonStyle` is not a `View`, so SwiftUI does not reliably update dynamic
    /// properties declared on it: an `@Environment` there can read a stale value or
    /// never update at all. Reading `colorScheme` and `isEnabled` from a real view is
    /// the shape Apple's own samples use and the only one guaranteed to track.
    ///
    /// ⛔ AND IT MUST NOT BE CALLED `Body`. `ButtonStyle` declares an associated type
    /// of exactly that name, so a nested `Body` becomes its WITNESS rather than a
    /// private helper — which fails twice over: a `private` witness cannot be less
    /// accessible than the conforming type, and `makeBody`'s opaque `some View` then
    /// no longer matches a requirement whose return type has been pinned to a nominal
    /// `Body`. Both errors landed on the Mac from one four-letter name. Making the
    /// type `internal` fixes only the first (verified on Linux against a synthetic
    /// protocol of the same shape); the name is the actual defect, and the collision
    /// was accidental rather than intended, so the fix is to stop colliding. The same
    /// trap is waiting under `Content`, `Label`, `ID`, `Value` and `Configuration`.
    private struct StyledLabel: View {
        let variant: DistrictButtonVariant
        let size: DistrictButtonSize
        let configuration: ButtonStyleConfiguration

        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.isEnabled) private var isEnabled

        private var colors: DistrictColors {
            .resolve(colorScheme)
        }

        var body: some View {
            configuration.label
                .font(size.font)
                .foregroundStyle(ink)
                .padding(.horizontal, size.horizontalPadding)
                .frame(minHeight: size.minHeight)
                .background(container, in: RoundedRectangle(cornerRadius: DistrictRadius.control))
                .overlay {
                    RoundedRectangle(cornerRadius: DistrictRadius.control)
                        .strokeBorder(border, lineWidth: 1)
                }
                // ⚠️ The web's `disabled:opacity-50` applied to the WHOLE control.
                // Letting SwiftUI substitute its own disabled greys would make a
                // disabled button invisible on a near-black surface rather than
                // merely quiet.
                .opacity(isEnabled ? 1 : 0.5)
                // ⚠️ A press feedback of our own, because a custom ButtonStyle
                // replaces the system's entirely and a control with no press state
                // reads as unresponsive on a slow network.
                .opacity(configuration.isPressed ? 0.8 : 1)
                // ⛔ A POINTER EFFECT OF OUR OWN, FOR THE SAME REASON AS THE PRESS STATE: a
                // custom ButtonStyle does not get the one a system-styled button does, so on
                // an iPad with a trackpad these were the only buttons that did not answer the
                // pointer. Shaped to the control, so the highlight is the button and not its
                // bounding box; off while disabled, like every other response.
                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: DistrictRadius.control))
                .hoverEffect(.highlight, isEnabled: isEnabled)
        }

        private var container: Color {
            switch variant {
            case .primary: colors.district
            case .secondary: colors.card
            case .ghost: .clear
            case .destructive: colors.destructive.opacity(0.10)
            }
        }

        private var ink: Color {
            switch variant {
            case .primary: colors.districtForeground
            case .secondary: colors.foreground
            case .ghost: colors.mutedForeground
            case .destructive: colors.destructive
            }
        }

        private var border: Color {
            switch variant {
            case .primary, .ghost: .clear
            case .secondary: colors.border
            case .destructive: colors.destructive.opacity(0.25)
            }
        }
    }
}

extension ButtonStyle where Self == DistrictButtonStyle {
    /// The filled indigo. One per screen.
    static var districtPrimary: DistrictButtonStyle {
        DistrictButtonStyle(variant: .primary)
    }

    /// The bordered card-coloured button, for everything alongside the primary.
    static var districtSecondary: DistrictButtonStyle {
        DistrictButtonStyle(variant: .secondary)
    }

    /// Borderless, for tertiary actions inside a row.
    static var districtGhost: DistrictButtonStyle {
        DistrictButtonStyle(variant: .ghost)
    }

    /// ⚠️ A TINTED OUTLINE, NOT A RED FILL. See ``DistrictButtonVariant``.
    static var districtDestructive: DistrictButtonStyle {
        DistrictButtonStyle(variant: .destructive)
    }
}
