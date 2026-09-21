import Foundation

/// How each sidebar row reads: its title, its symbol, its identifier, and the sentence the
/// detail column shows while a list section has nothing open.
///
/// ⛔ A TAB'S ROW IS THE TAB. Its title and symbol come from ``Tab``, so the sidebar and
/// the tab bar cannot name the same place two ways; a rotation from one to the other must
/// not look like a move to somewhere else.
///
/// ⛔ A HUB'S TITLE IS THE TITLE OF THE SCREEN IT OPENS, read from the same constant that
/// screen's navigation bar reads. The Overview's rows say the same words, with one
/// exception a test pins: its HQ row is a call to action ("Open District HQ"), which reads
/// wrongly as the name of a place.
///
/// ⚠️ THE SYMBOLS REUSE THE ONES THE SCREENS ALREADY DRAW where there is one (Billing's
/// card, Rooms' camera, Support's lifebuoy), and are chosen here otherwise. The Desk is a
/// full tray rather than the Inbox's empty one, and the dialler an outgoing call rather
/// than the Calls tab's handset, so no two rows share a glyph.
extension SidebarItem {
    var sidebarTitle: String {
        switch self {
        // ⚠️ THE `?? ""` IS UNREACHABLE: these five cases are exactly the ones with a tab.
        case .overview, .inbox, .calls, .contacts, .account: tab?.label ?? ""
        case .hq: HQCopy.title
        case .analytics: "Analytics"
        case .marketplace: MarketplaceCopy.title
        case .billing: BillingCopy.title
        case .rooms: RoomsCopy.title
        case .workflows: WorkflowsCopy.title
        case .desk: DeskCopy.title
        case .dialer: "Dial"
        case .scheduling: "Scheduling"
        case .support: SupportCopy.title
        case .settings: SettingsCopy.hubTitle
        }
    }

    var sidebarSymbol: String {
        switch self {
        case .overview, .inbox, .calls, .contacts, .account: tab?.systemImage ?? ""
        case .hq: "sparkles"
        case .analytics: "chart.bar"
        case .marketplace: "number"
        case .billing: "creditcard"
        case .rooms: "video"
        case .workflows: "flowchart"
        case .desk: "tray.full"
        case .dialer: "phone.arrow.up.right"
        case .scheduling: "calendar"
        case .support: "lifepreserver"
        case .settings: "gearshape"
        }
    }

    /// The identifier a UI test addresses the row by. See ``A11yID/Sidebar``.
    var accessibilityID: String {
        switch self {
        case .overview: A11yID.Sidebar.overview
        case .inbox: A11yID.Sidebar.inbox
        case .calls: A11yID.Sidebar.calls
        case .contacts: A11yID.Sidebar.contacts
        case .hq: A11yID.Sidebar.hq
        case .analytics: A11yID.Sidebar.analytics
        case .marketplace: A11yID.Sidebar.marketplace
        case .billing: A11yID.Sidebar.billing
        case .rooms: A11yID.Sidebar.rooms
        case .workflows: A11yID.Sidebar.workflows
        case .desk: A11yID.Sidebar.desk
        case .dialer: A11yID.Sidebar.dialer
        case .scheduling: A11yID.Sidebar.scheduling
        case .support: A11yID.Sidebar.support
        case .settings: A11yID.Sidebar.settings
        case .account: A11yID.Sidebar.account
        }
    }

    /// What the detail column says while this list section has no row open, or nil for a
    /// section that is not a list.
    ///
    /// ⚠️ AN INSTRUCTION RATHER THAN "Nothing selected". The list beside it is the thing to
    /// act on, and in portrait it is behind a button, so the sentence says what to do.
    var detailPlaceholder: (title: String, symbol: String)? {
        switch self {
        case .inbox: ("Select a conversation", "tray")
        case .calls: ("Select a call", "phone")
        case .contacts: ("Select a contact", "person.2")
        case .desk: ("Select a ticket", "tray.full")
        case .support: ("Select a request", "lifepreserver")
        case .overview, .account, .hq, .analytics, .marketplace, .billing, .rooms, .workflows, .dialer,
             .scheduling, .settings:
            nil
        }
    }
}
