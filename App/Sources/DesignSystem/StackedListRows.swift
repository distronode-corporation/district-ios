import SwiftUI

/// Rows for a `List` that has to look like a padded `VStack` in a `ScrollView`.
///
/// ⛔ WHY SUCH A SCREEN IS A `List` AT ALL: A `List` IS THE ONLY CONTAINER THAT TAKES A
/// SELECTION. On regular width the Desk and Support queues sit beside their detail, and
/// the open row has to stay highlighted there; a stack of buttons cannot say which one is
/// open. On compact width the same list has to look exactly like that stack,
/// and each modifier below exists to undo one thing a plain `List` adds by default.
///
/// ⚠️ MEASURED ON THE SIMULATOR, NOT ASSUMED: a plain `List` row is an OPAQUE system-
/// background cell (hence `listRowBackground(.clear)`), carries a separator (hidden), and
/// a `NavigationLink` in one draws a disclosure chevron even under `.buttonStyle(.plain)`
/// (hence ``plainRouteRow()``). A stack draws none of those.
extension View {
    /// One block of the stack, as a row: the page gutter at the sides, and the gap
    /// the stack's `spacing` would put above it.
    ///
    /// ⛔ THE GAP GOES ABOVE A ROW, NEVER BELOW, BECAUSE THAT IS HOW A `VStack` SPACES:
    /// between neighbours, and not after the last. The last row adds the stack's bottom
    /// padding itself, which is the only row that knows it is last.
    func stackedListRow(top: CGFloat, bottom: CGFloat = 0) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(
                EdgeInsets(top: top, leading: DistrictSpacing.gutter, bottom: bottom, trailing: DistrictSpacing.gutter)
            )
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    /// A route row that draws no disclosure chevron, as a `NavigationLink` in a stack does
    /// not.
    func plainRouteRow() -> some View {
        buttonStyle(.plain)
            .navigationLinkIndicatorVisibility(.hidden)
    }

    /// The list those rows sit in.
    ///
    /// ⛔ THE MINIMUM ROW HEIGHT IS ZERO, or a one-line block shorter than the system's
    /// 44 points would be padded to it and push everything under it down.
    func stackedList() -> some View {
        listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 0)
    }
}

/// One row's slice of a bordered card that spans several `List` rows.
///
/// ⛔ EACH SLICE DRAWS THE WHOLE CARD'S SHAPE, EXTENDED PAST ITS OWN EDGES AND CLIPPED TO
/// THEM, rather than a shape of its own. A middle row's rounded rectangle reaches beyond
/// its top and bottom, so only its straight sides survive the clip; the first and last
/// keep their real corners. Stacked, the slices are the card that one `VStack` would
/// draw, down to the same corner curve and the same inset stroke, which a hand-drawn open
/// path would only approximate.
///
/// ⚠️ THE OVERHANG IS TWICE THE RADIUS because a continuous corner's curve runs about one
/// and a half radii along each edge; anything shorter would clip a sliver of a corner
/// into the middle of the card.
struct CardSlice: ViewModifier {
    let first: Bool
    let last: Bool

    /// ⚠️ DRAWN BY THE ROW RATHER THAN BY THE `List`. The row's own background is clear so
    /// the page shows in the gutters, which leaves the system nothing to paint a selection
    /// on; the card says it instead, in the same tint as a selected filter chip.
    var selected = false

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let colors = DistrictColors.resolve(colorScheme)
        let shape = RoundedRectangle(cornerRadius: DistrictRadius.card)
        return content
            .background {
                ZStack {
                    shape.fill(colors.card)
                    if selected {
                        shape.fill(colors.district.opacity(DistrictColors.containerAlpha))
                    }
                }
                .padding(.top, first ? 0 : -overhang)
                .padding(.bottom, last ? 0 : -overhang)
            }
            .overlay {
                shape.strokeBorder(colors.border, lineWidth: 1)
                    .padding(.top, first ? 0 : -overhang)
                    .padding(.bottom, last ? 0 : -overhang)
            }
            .clipped()
    }

    private var overhang: CGFloat {
        DistrictRadius.card * 2
    }
}
