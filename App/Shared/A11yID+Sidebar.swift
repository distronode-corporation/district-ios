/// The regular-width shell: the sidebar's rows and the empty detail column.
///
/// ⚠️ NEW STRINGS WITH NO KOTLIN TWIN, and they will not get one while the Android client
/// is phone-only. They follow ``A11yID/Nav``'s shape (`district-<surface>-<item>`) so a
/// test plan reads the same across the two shells.
///
/// ⚠️ ONE CONSTANT PER ROW RATHER THAN A FUNCTION OF THE ITEM, because this file is also
/// compiled into the UI-test bundle, which cannot see `SidebarItem`. The app maps each
/// item onto its constant with an exhaustive switch, so a new item has to be given one.
///
/// ⚠️ ITS OWN FILE, like the other `A11yID+*.swift` siblings: `A11yID.swift` is the base
/// and the extensions are expected rather than exceptional.
extension A11yID {
    enum Sidebar {
        static let overview = "district-sidebar-overview"
        static let inbox = "district-sidebar-inbox"
        static let calls = "district-sidebar-calls"
        static let contacts = "district-sidebar-contacts"
        static let hq = "district-sidebar-hq"
        static let analytics = "district-sidebar-analytics"
        static let marketplace = "district-sidebar-marketplace"
        static let billing = "district-sidebar-billing"
        static let rooms = "district-sidebar-rooms"
        static let workflows = "district-sidebar-workflows"
        static let desk = "district-sidebar-desk"
        static let dialer = "district-sidebar-dialer"
        static let scheduling = "district-sidebar-scheduling"
        static let support = "district-sidebar-support"
        static let settings = "district-sidebar-settings"
        static let account = "district-sidebar-account"

        /// The detail column's empty state, shown while a list section has no row open.
        ///
        /// ⚠️ ONE IDENTIFIER FOR ALL FIVE LIST SECTIONS. Which section it belongs to is
        /// the sidebar's selection, so a test asserts that separately rather than reading
        /// it out of this string.
        static let detailPlaceholder = "district-detail-placeholder"
    }
}
