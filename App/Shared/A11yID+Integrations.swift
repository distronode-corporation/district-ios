/// Workspace settings: Integrations.
///
/// ⚠️ NEW ON BOTH CLIENTS: Android has no Integrations screen yet, so these are named here
/// first, in Android's `district-<screen>-<control>` shape so a port can copy them.
extension A11yID {
    enum Integrations {
        static let root = "district-integrations-root"
        static let openPage = "district-integrations-open-page"
        static let desk = "district-integrations-desk"
        static let enrichment = "district-integrations-enrichment"

        /// One calendar provider's row, keyed by the provider's id (`google`, `microsoft`).
        static func calendar(_ provider: String) -> String {
            "district-integrations-calendar-\(provider)"
        }
    }
}
