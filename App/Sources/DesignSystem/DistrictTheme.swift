import SwiftUI

/// The Ledger palette, ported from the web.
///
/// ⛔ THE SOURCE OF TRUTH IS THE WEB'S LEDGER TOKEN TABLE (`tokens.css`), NOT THIS
/// FILE AND NOT ANY DASHBOARD STYLESHEET. That one table is what the web dashboard
/// and both native `DistrictColors` pairs are written from. Change a value there
/// first, then carry it here. If they ever disagree, `tokens.css` wins.
///
/// ⚠️ THE ANDROID CLIENT'S `DistrictColors.kt` MOVES IN ITS OWN CHANGE, so the two
/// native palettes are not guaranteed byte-identical at any moment. Compare either
/// client against `tokens.css`, never against the other.
///
/// ⛔ THERE IS EXACTLY ONE ACCENT. `district` is used for links and the
/// answered-in-region mark and nothing else; every other emphasis on this palette
/// is carried by `filled` on the web and by weight, rule and band here. Do not
/// reintroduce a second brand colour, a glow token or a decorative cyan.
///
/// ⚠️ DARK IS THE REAL THEME. Dark is designed rather than inverted, and the light
/// palette exists for parity; the light values are separately darkened for contrast
/// on white rather than being the dark values lightened, so the two are not
/// mechanically derivable from each other, which is why both are written out.
///
/// ⚠️ ONE WEB TOKEN HAS NO HOME HERE. `--filled` / `--filled-foreground` (the web's
/// table header row and primary button) has no field on this struct, so it is not
/// ported; ``DistrictButton`` still fills its primary style with ``district``. That
/// is a known divergence from the web's button, not an omission to quietly patch by
/// pointing an existing token at a `filled` value.
///
/// ⛔ NO ASSET CATALOG AND NO `UIColor(dynamicProvider:)`. Both would drag UIKit
/// into a directory whose whole point is that it depends on nothing but SwiftUI.
/// The palette is resolved once, from `colorScheme`, by ``View/districtTheme()``
/// and handed down the environment instead.
struct DistrictColors {
    /// The page.
    let background: Color
    /// Default text.
    let foreground: Color
    /// Page chrome: bars and sheets. One step above ``background``.
    let surface: Color
    /// Panels and cards. One step above ``surface``.
    let card: Color
    /// Solid subtle fill: field backgrounds, inert chips.
    let muted: Color
    /// Secondary text. Readable, not decorative.
    let mutedForeground: Color
    /// The calm 1px border that separates surfaces instead of a shadow.
    let border: Color
    /// Field border and fill, marginally lighter than ``border``.
    let input: Color
    /// Raised or pressed surface above ``card``.
    let elevated: Color
    /// ⛔ The single brand accent: the logo's teal (colour v3).
    let district: Color
    /// Text ON ``district``.
    ///
    /// ⚠️ IT FLIPS WITH THE SCHEME, AND THE DARK SIDE LOOKS WRONG UNTIL YOU MEASURE
    /// IT. The dark accent is a light teal, so white on it fails WCAG AA (1.8:1) while
    /// the near-black `#0e1c1f` passes at 9.6:1; the light accent is a deep teal and
    /// takes white at 6.6:1. Both values are read from `tokens.css`, not derived
    /// here, and matching them is a contrast decision rather than a stylistic one.
    let districtForeground: Color
    let success: Color
    let onSuccess: Color
    let warning: Color
    let onWarning: Color
    let destructive: Color
    let onDestructive: Color
    let info: Color
    let onInfo: Color
    /// ⛔ THE INKS A TINTED CHIP DRAWS ON ITS OWN 12% FILL (a badge, an avatar, a desk chip),
    /// one per tinted tone. The fill is the tone at ``containerAlpha`` over the surface, so
    /// the tone itself as the label left six badge pairs between 3.91:1 and 4.44:1, short
    /// of AA for a 12pt label (3.0.2). Each chip ink is its tone mixed ``chipInkMix`` of the
    /// way towards ``foreground``, the highest-contrast ink in the scheme, which lifts the
    /// worst pair to 4.71:1 and keeps the hue. Not tokens of their own in `tokens.css`:
    /// derived from two that are, and `DistrictContrastTests` checks each literal against
    /// that derivation, so a palette edit that forgets them fails.
    let districtChipInk: Color
    let successChipInk: Color
    let warningChipInk: Color
    let destructiveChipInk: Color
    let infoChipInk: Color
}

extension DistrictColors {
    /// The designed theme. `[data-theme="dark"]` in `tokens.css`.
    static let dark = DistrictColors(
        background: Color(districtHex: 0x0E1C1F),
        foreground: Color(districtHex: 0xE9F0F1),
        surface: Color(districtHex: 0x152528),
        card: Color(districtHex: 0x16292D),
        muted: Color(districtHex: 0x1D3236),
        mutedForeground: Color(districtHex: 0x93A8AB),
        border: Color(districtHex: 0x24393D),
        input: Color(districtHex: 0x2A4146),
        elevated: Color(districtHex: 0x1F373B),
        district: Color(districtHex: 0x67CDED),
        districtForeground: Color(districtHex: 0x0E1C1F),
        success: Color(districtHex: 0x74E9AA),
        // ⚠️ Every semantic colour takes BLACK text in dark mode, and `tokens.css`
        // does not publish an `on*` pair to copy: these four are the convention this
        // file has always carried, kept because the measurement still holds. The
        // dark fills are all light and saturated (black clears 8.0:1 on the worst of
        // them, `destructive`; white manages 2.6:1 there and fails outright).
        onSuccess: Color(districtHex: 0x000000),
        warning: Color(districtHex: 0xEAB90C),
        onWarning: Color(districtHex: 0x000000),
        destructive: Color(districtHex: 0xFE737F),
        onDestructive: Color(districtHex: 0x000000),
        info: Color(districtHex: 0x77BAFE),
        onInfo: Color(districtHex: 0x000000),
        districtChipInk: Color(districtHex: 0x81D4EE),
        successChipInk: Color(districtHex: 0x8BEAB8),
        warningChipInk: Color(districtHex: 0xEAC43A),
        destructiveChipInk: Color(districtHex: 0xFA8C96),
        infoChipInk: Color(districtHex: 0x8EC5FB)
    )

    /// Parity, for a user whose device is in light mode. `:root` in `tokens.css`.
    static let light = DistrictColors(
        background: Color(districtHex: 0xE8EDEE),
        foreground: Color(districtHex: 0x10282C),
        surface: Color(districtHex: 0xD6DFE1),
        card: Color(districtHex: 0xFFFFFF),
        muted: Color(districtHex: 0xF4F7F7),
        mutedForeground: Color(districtHex: 0x3F5A5E),
        border: Color(districtHex: 0xC9D6D8),
        input: Color(districtHex: 0xBFCED0),
        elevated: Color(districtHex: 0xF7F9F9),
        // Not the dark accent darkened: a separate deep teal that clears AA on
        // both `background` (5.6:1) and `card` (6.6:1).
        district: Color(districtHex: 0x01657D),
        districtForeground: Color(districtHex: 0xFFFFFF),
        success: Color(districtHex: 0x016F4E),
        // ⚠️ Mirror of the dark note: the light fills are all deep, so WHITE is the
        // readable text on every one of them (6.2:1 on the worst, `success`).
        onSuccess: Color(districtHex: 0xFFFFFF),
        warning: Color(districtHex: 0x754603),
        onWarning: Color(districtHex: 0xFFFFFF),
        destructive: Color(districtHex: 0xB4022D),
        onDestructive: Color(districtHex: 0xFFFFFF),
        info: Color(districtHex: 0x223092),
        onInfo: Color(districtHex: 0xFFFFFF),
        districtChipInk: Color(districtHex: 0x04596D),
        successChipInk: Color(districtHex: 0x046147),
        warningChipInk: Color(districtHex: 0x61400B),
        destructiveChipInk: Color(districtHex: 0x930A2D),
        infoChipInk: Color(districtHex: 0x1E2E7E)
    )

    /// The web's `/12` alpha, used for every tinted container: `bg-district/12`,
    /// `bg-success/12`, `bg-destructive/12`.
    static let containerAlpha: Double = 0.12

    /// How far each chip ink sits from its tone towards ``foreground``: see
    /// ``districtChipInk``.
    static let chipInkMix: Double = 0.2
}

/// The 4pt grid the web's spacing scale is built on (`--spacing: 0.25rem`).
///
/// ⚠️ NAMED BY ROLE, NOT BY SIZE. `xs`/`sm`/`md` would just be a slower way of
/// writing numbers. These names say where a value belongs, so a screen that needs
/// "the gap between cards" cannot accidentally reach for a row's inner padding and
/// drift from every other screen.
///
/// ⚠️ Static rather than an environment value, because spacing does not vary with
/// the colour scheme and an environment read that can never change is a lookup
/// pretending to be a decision.
enum DistrictSpacing {
    /// Between a label and the thing it labels.
    static let hairline: CGFloat = 4
    /// Between tightly related items inside a row.
    static let tight: CGFloat = 8
    /// Between stacked text lines in a list row.
    static let row: CGFloat = 12
    /// The screen's horizontal inset, and a card's inner padding.
    static let gutter: CGFloat = 16
    /// Card padding on the web (`px-5`).
    static let card: CGFloat = 20
    /// Between sibling cards and list sections.
    static let section: CGFloat = 24
    /// Below a page header (`mb-8`).
    static let header: CGFloat = 32
}

/// The web's radius conventions, which are consistent enough to be tokens.
///
/// `rounded-md` 6pt badges, `rounded-lg` 8pt buttons and fields, `rounded-xl` 12pt
/// cards and panels, `rounded-t-2xl` 16pt sheets.
enum DistrictRadius {
    static let badge: CGFloat = 6
    static let control: CGFloat = 8
    static let card: CGFloat = 12
    static let sheet: CGFloat = 16
}

extension DistrictColors {
    /// The palette for a colour scheme.
    ///
    /// ⛔ A FUNCTION OF `colorScheme` RATHER THAN A CUSTOM ENVIRONMENT KEY, AND THE
    /// REASON IS THE TOOLING RATHER THAN THE DESIGN. SwiftFormat's `environmentEntry`
    /// rule rewrites a hand-written `EnvironmentKey` into the `@Entry` macro, so
    /// `swiftformat --lint` in CI would red on the hand-written form — and
    /// `@Entry` is an Xcode 16-era macro that nobody in this programme can compile
    /// locally to confirm against an iOS 17 deployment target. Deriving the palette
    /// from a value SwiftUI already publishes needs neither, and it removes the
    /// footgun that a subtree rendered outside a theme modifier silently gets the
    /// wrong palette.
    ///
    /// ⚠️ A THIRD SCHEME IS NOT A HYPOTHETICAL SWITCH TO ADD LATER. `ColorScheme` is
    /// deliberately matched with a `!= .dark` test rather than a `switch`, so a value
    /// this build has never seen resolves to the light palette on a light device
    /// rather than failing to compile the day the SDK adds one.
    static func resolve(_ scheme: ColorScheme) -> DistrictColors {
        scheme == .dark ? .dark : .light
    }
}

/// Applies the brand tint for the current colour scheme.
///
/// ⚠️ TINT ONLY. The palette itself is read per view from `colorScheme` (see
/// ``DistrictColors/resolve(_:)``); what cannot be read that way is the tint SwiftUI's
/// OWN controls use. A `ProgressView`, a `TextField` caret or a system `Button`
/// would otherwise render in the platform blue next to correctly themed custom
/// components, which is the worst of both.
private struct DistrictThemeModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.tint(DistrictColors.resolve(colorScheme).district)
    }
}

extension View {
    /// Apply the District tint to this view and everything below it. Once, at the
    /// root.
    func districtTheme() -> some View {
        modifier(DistrictThemeModifier())
    }
}

extension Color {
    /// Build a colour from a packed 24-bit sRGB value, so the tokens above can be
    /// written as the same hex literals the web and the Kotlin client use.
    ///
    /// ⚠️ Opaque by construction. Alpha is applied at the use site with
    /// `.opacity(_:)`, because the only alpha this system has is
    /// ``DistrictColors/containerAlpha`` and burying it in a token would make a
    /// tinted fill indistinguishable from a solid one at the call site.
    init(districtHex hex: UInt32) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}
