import Foundation

/// How a list section's one stored stack is split into a selected row and the screens
/// pushed beside it, on regular width.
///
/// ⛔ THE STORED PATH IS `[selected, ...tail]`, THE SAME ARRAY THE TAB BAR PUSHES, AND THAT
/// IDENTITY IS WHAT MAKES A LAYOUT FLIP LOSSLESS. On compact width a tapped call is the
/// first push on the Calls stack; on regular width it is the highlighted row in the content
/// column and the root of the detail column. Storing both as one array means a rotation
/// changes which view reads it, never what it says, so a dialler or a room pushed deep in
/// the detail is still there on the other side of a flip. ``ShellPaths`` carries the rest
/// of that argument.
///
/// ⛔ WRITING BACK WHAT WAS READ IS A NO-OP, AND SELECTING THE ROW ALREADY SELECTED IS ONE
/// TOO. SwiftUI may write a `List`'s selection back while it rebuilds a column, and a
/// setter that answered every write with `[route]` would drop the tail on that write,
/// taking a live call's controls with it. The cost is that tapping the open row does not
/// pop its detail to the root, which the tab bar's second tap does; the detail's own back
/// button still does.
///
/// ⚠️ A nil SELECTION LEAVES THE PATH ALONE for the same reason. Nothing a person does in
/// a single-selection list deselects a row, so a nil write is SwiftUI's rather than
/// theirs, and honouring it would empty the detail column under them.
///
/// ⚠️ PURE AND STATIC so the mapping can be tested without a view; the bindings in
/// ``RegularShellView`` are one call each.
enum ListDetailPath {
    /// The row the content column highlights, and the root of the detail column.
    static func selection(in path: [Route]) -> Route? {
        path.first
    }

    /// The path after the content column selects `route`.
    static func selecting(_ route: Route?, in path: [Route]) -> [Route] {
        guard let route, route != path.first else { return path }
        return [route]
    }

    /// What the detail column's own stack holds: every push after the selected row.
    static func tail(of path: [Route]) -> [Route] {
        Array(path.dropFirst())
    }

    /// The path after the detail column's stack changes to `tail`.
    ///
    /// ⚠️ WITH NOTHING SELECTED THERE IS NO DETAIL STACK TO WRITE, so a write that arrives
    /// anyway (a stack being torn down after its section was reset) cannot resurrect
    /// screens under a row that is no longer there.
    static func replacingTail(_ tail: [Route], in path: [Route]) -> [Route] {
        guard let first = path.first else { return path }
        return [first] + tail
    }

    /// Whether the content column moved off a row it had open.
    ///
    /// ⚠️ ONLY THE SIDEBAR LAYOUT ASKS. On compact width leaving a row is a pop, which a
    /// shrinking path already says; on regular width it is a new selection at the same
    /// depth, and a list that re-reads when a row is left (the Inbox clears a badge that
    /// way) has to be told separately.
    static func leftSelection(from previous: [Route], to current: [Route]) -> Bool {
        guard let before = previous.first else { return false }
        return current.first != before
    }
}

extension SidebarItem {
    /// Whether this section is a list with its detail beside it on regular width.
    ///
    /// ⛔ FIVE, AND EACH ONE'S FIRST PUSH IS ALWAYS ONE OF ITS OWN ROWS: a call, a thread, a
    /// contact, a desk ticket, a support request. That is what lets the first element of
    /// the stored path stand for the selected row. Every other section is a screen of its
    /// own (a dashboard, a form, a hub of sections, the dialler) and gets the whole detail
    /// column instead.
    var isListSection: Bool {
        switch self {
        case .inbox, .calls, .contacts, .desk, .support:
            true
        case .overview, .account, .hq, .analytics, .marketplace, .billing, .rooms, .workflows, .dialer,
             .scheduling, .settings:
            false
        }
    }
}
