import Foundation

/// The five top-level destinations, in the Android nav bar's order.
///
/// ⚠️ THE ORDER IS THE ANDROID CLIENT'S AND IS NOT ARBITRARY: overview, inbox,
/// calls, contacts, account. Two people comparing a phone each is a routine support
/// interaction, and a tab bar that reads differently on the two platforms turns it
/// into a translation exercise.
///
/// ⛔ `account` IS NOT WORKSPACE-SCOPED, AND THAT IS LOAD-BEARING RATHER THAN
/// TIDINESS. Sign-out and account deletion are properties of the ACCOUNT, not of a
/// tenant, so this tab must stay reachable when no workspace resolves at all, which
/// is exactly the state a first launch and an App Review account are in. Its
/// contents may never require a `workspaceId`. Mirrors `Routes.SETTINGS`.
enum Tab: String, Hashable, CaseIterable {
    case overview
    case inbox
    case calls
    case contacts
    case account

    var label: String {
        switch self {
        // ⚠️ FROM `A11yID.NavLabel`, WHICH THE UI-TEST BUNDLE ALSO COMPILES. The tab
        // bar can only be addressed by label, so a literal here and a literal in the
        // test would be a suite that passes until somebody renames a tab.
        case .overview: A11yID.NavLabel.overview
        case .inbox: A11yID.NavLabel.inbox
        case .calls: A11yID.NavLabel.calls
        case .contacts: A11yID.NavLabel.contacts
        case .account: A11yID.NavLabel.account
        }
    }

    /// ⚠️ SF SYMBOLS, WHICH ARE THE ONE ICON SET GUARANTEED TO BE PRESENT. Nothing
    /// is bundled, so a tab icon cannot go missing with an asset catalog change, and
    /// each one renders at the platform's own weight and scale.
    /// The accessibility identifier its tab-bar button carries.
    ///
    /// ⛔ IDENTITY RATHER THAN THE LABEL, AND THE STRINGS ARE ANDROID'S VERBATIM.
    /// A UI test matching "Overview" would break the moment the word changes and
    /// would need translating the day the app is localised; `district-nav-overview`
    /// is the same token Android already uses, so one test plan reads on both.
    var accessibilityID: String {
        switch self {
        case .overview: A11yID.Nav.overview
        case .inbox: A11yID.Nav.inbox
        case .calls: A11yID.Nav.calls
        case .contacts: A11yID.Nav.contacts
        case .account: A11yID.Nav.account
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .inbox: "tray"
        case .calls: "phone"
        case .contacts: "person.2"
        case .account: "person.crop.circle"
        }
    }
}
