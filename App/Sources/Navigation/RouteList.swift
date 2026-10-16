import SwiftUI

/// A `List` whose rows push routes, and which takes a selection only when a layout gives
/// it one.
///
/// ⛔ nil IS THE TAB BAR AND IT BUILDS THE PLAIN `List` IT ALWAYS BUILT. On compact width
/// a row's `NavigationLink(value:)` pushes onto the tab's stack; on regular width the same
/// link SELECTS, because a `List` whose selection type matches the link's value updates the
/// selection instead of pushing, and the split view's detail column follows the selection.
/// Two initialisers rather than `List(selection: nil)` so the phone keeps the exact view it
/// had before the sidebar existed, not one that merely behaves the same.
///
/// ⛔ NO `navigationDestination` HERE OR ANYWHERE IN A CONTENT COLUMN. On regular width
/// this list sits in a split view column that has no stack of its own; the one
/// registration for `Route.self` is on the detail column's stack, and a second one would
/// be the runtime coin toss ``ShellView`` warns about.
struct RouteList<Content: View>: View {
    let selection: Binding<Route?>?
    private let content: Content

    init(selection: Binding<Route?>?, @ViewBuilder content: () -> Content) {
        self.selection = selection
        self.content = content()
    }

    var body: some View {
        if let selection {
            List(selection: selection) { content }
        } else {
            List { content }
        }
    }
}

extension View {
    /// A full-bleed row of a ``RouteList``: no insets, no separator, and on the phone the
    /// card ground.
    ///
    /// ⚠️ THE CARD GROUND ON THE PHONE (3.0.2 visual walk). A plain `List` row is an opaque
    /// system cell, pure white or pure black, which sat on the page's `background` in
    /// Contacts, Inbox and Calls as a colour the palette does not have. ``DistrictColors/card``
    /// is what every card and panel on the same page is drawn on.
    ///
    /// ⛔ NOT WHEN THE LIST SELECTS (regular width). A row background replaces the cell the
    /// system draws its selection highlight on, so on the iPad the open row would stop
    /// showing as open; the Desk and Support queues draw their own selection for exactly
    /// that reason (``CardSlice``). A selecting list keeps the system's cell.
    func routeListRow(selects: Bool) -> some View {
        modifier(RouteListRowGround(selects: selects))
    }
}

struct RouteListRowGround: ViewModifier {
    let selects: Bool

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Self.ground(colorScheme, selects: selects))
    }

    /// The row's ground: the card on the phone, the system's own cell (nil) in a list that
    /// selects.
    static func ground(_ scheme: ColorScheme, selects: Bool) -> Color? {
        selects ? nil : DistrictColors.resolve(scheme).card
    }
}
