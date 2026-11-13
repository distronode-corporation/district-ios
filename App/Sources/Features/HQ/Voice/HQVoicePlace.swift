import DistrictModel

/// Where the member is in the app, as an HQ voice screen report names it.
///
/// ⛔ A PAGE FROM THE CORE'S CLOSED TABLE AND, AT MOST, ONE RECORD ID. Never a title, a name, a
/// number or a search: the agent reads the record itself, in the workspace, from the id.
struct HQVoicePlace: Equatable {
    let page: HQVoicePage
    let selected: HQVoiceSelection?

    init(_ page: HQVoicePage, _ selected: HQVoiceSelection? = nil) {
        self.page = page
        self.selected = selected
    }

    /// The screen on top: the last route pushed, else the selected section's root.
    static func of(_ item: SidebarItem, top: Route?) -> HQVoicePlace {
        top.flatMap(of(_:)) ?? HQVoicePlace(page(pageID(item)))
    }

    /// The page id of a section's root.
    static func pageID(_ item: SidebarItem) -> String {
        switch item {
        case .overview: "home"
        case .dialer: "phone"
        case .inbox, .calls, .contacts, .hq, .analytics, .marketplace, .billing, .rooms, .workflows, .desk, .live,
             .scheduling, .support, .settings, .account:
            "\(item)"
        }
    }

    /// A pushed screen's place. ⚠️ An Inbox thread names its conversation only when its key is
    /// a contact's (`contact:<id>`): an `addr:` key is an address, which is never sent.
    static func of(_ route: Route) -> HQVoicePlace? {
        switch route {
        case let .callDetail(_, callId):
            HQVoicePlace(.calls, HQVoiceSelection(kind: .call, id: callId))
        case let .thread(_, _, threadKey, _, _):
            HQVoicePlace(.inbox, contactID(threadKey).flatMap { HQVoiceSelection(kind: .conversation, id: $0) })
        case let .contactDetail(_, _, contactId):
            HQVoicePlace(.contacts, HQVoiceSelection(kind: .contact, id: contactId))
        case .hq: HQVoicePlace(.hq)
        case let .superviseCall(_, _, callId):
            HQVoicePlace(page("live"), HQVoiceSelection(kind: .call, id: callId))
        case .activeRoom: HQVoicePlace(page("meeting"))
        default: HQVoicePlace(page(sectionID(route)))
        }
    }

    /// The section a pushed screen without a record of its own belongs to.
    private static func sectionID(_ route: Route) -> String {
        switch route {
        case .analytics: "analytics"
        case .marketplace: "marketplace"
        case .billing: "billing"
        case .workflows: "workflows"
        case .rooms: "rooms"
        case .dialer: "phone"
        case .liveCalls: "live"
        case .workspaceSettings: "settings"
        case .scheduling: "scheduling"
        case .support, .supportRequest: "support"
        case .desk, .deskTicket: "desk"
        case .devices: "account"
        case .callDetail, .thread, .contactDetail, .hq, .activeRoom, .superviseCall: "home"
        }
    }

    private static func contactID(_ threadKey: String) -> String? {
        let prefix = "contact:"
        guard threadKey.hasPrefix(prefix) else { return nil }
        return String(threadKey.dropFirst(prefix.count))
    }

    /// ⚠️ EVERY ID ABOVE IS IN THE TABLE (`HQVoicePlaceTests` walks them all); the home page
    /// stands in should the service ever drop one.
    private static func page(_ id: String) -> HQVoicePage {
        HQVoicePage(id: id) ?? .home
    }
}

extension ShellPaths {
    /// The place on screen now, for ``HQVoiceSession/report(_:)``.
    var hqVoicePlace: HQVoicePlace {
        HQVoicePlace.of(selection, top: regularPath(for: selection).last)
    }
}
