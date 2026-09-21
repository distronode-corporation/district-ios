import SwiftUI

/// The theme background, painted where a `NavigationStack` would otherwise paint
/// the platform's own.
///
/// ⛔ WITHOUT THIS THE SIGNED-IN APP NEVER SHOWS `DistrictColors.background`, THOUGH
/// EVERY PIECE OF EVIDENCE SAYS IT DOES. `RootView`'s `SessionGate` paints the page —
/// one `ZStack` whose first layer is `colors.background.ignoresSafeArea()`. That is
/// not enough: ``ShellView`` puts a `TabView` of `NavigationStack`s over it, and a
/// `NavigationStack` supplies its own opaque container background, which is pure
/// black in dark mode and white in light. Measured over captured frames without this
/// modifier, `#0E1C1F` appeared in 96.9% of the sign-in screen's dark frames and
/// 91.1% of the workspace picker's, and in **0 of 41** signed-in frames. The two
/// surfaces that looked right are precisely the two that render OUTSIDE the tabs.
///
/// ⛔ PAINTING AT THE `TabView` DOES NOT WORK, WHICH IS THE TRAP AND IS WHY THIS IS
/// A HELPER RATHER THAN ONE MODIFIER IN ONE PLACE. The stacks are above the tab
/// view and paint over it, so a background there is covered by the very thing that
/// is covering `SessionGate`. Verified on a device rather than reasoned about: it
/// has to go on the stack's ROOT content and on the `navigationDestination`
/// content, because a pushed screen is a second container with the same default.
///
/// ⛔ AND `scrollContentBackground(.hidden)` IS NOT OPTIONAL. A `List` or a `Form`
/// paints its OWN background over whatever is behind it, so the four tabs that are
/// lists would have kept the platform colour with the modifier below them doing
/// nothing visible. The order is the one that was measured to work: hide the scroll
/// content's background first, then paint.
///
/// ⚠️ NO `toolbarBackground` HERE. The tab bar and navigation bar are left to the
/// platform's material deliberately: what was measured is the pair of
/// modifiers below, and adding a third that nobody has seen render would be
/// guessing on the one surface this file exists to stop guessing about. If the bars
/// want the palette, that is its own change with its own screenshot.
///
/// ⚠️ THE PALETTE IS READ FROM `colorScheme`, NOT FROM THE ENVIRONMENT. That is
/// ``DistrictColors/resolve(_:)``'s whole design — see the ⛔ on
/// `DistrictTheme.swift`, which explains why there is no `@Entry` colour key — so
/// this modifier needs no wiring above it and cannot be given the wrong palette by
/// a subtree that forgot something.
private struct DistrictBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(DistrictColors.resolve(colorScheme).background.ignoresSafeArea())
    }
}

extension View {
    /// Put the theme background under this screen. ⛔ Applied to every
    /// `NavigationStack` root AND to every `navigationDestination` body; see the ⛔
    /// on `ShellBackground.swift`.
    func districtBackground() -> some View {
        modifier(DistrictBackgroundModifier())
    }
}
