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
