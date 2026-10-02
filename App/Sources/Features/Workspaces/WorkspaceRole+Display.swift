import DistrictModel

/// How a workspace role reads on screen, everywhere the app names one.
///
/// ⛔ ONE TABLE, AND IT IS THE WEB MEMBERS SCREEN'S (`workspaceAdminI18n.ts`,
/// `roleLabels`). The member list and the workspace picker used to name the same role
/// two ways ("Administrator" on one, "Agency" on the other). "agency" is a poor word
/// for a person, so the wire value never reaches the screen for a role this build
/// knows.
///
/// ⚠️ A ROLE THAT DOES NOT PARSE HAS NO LABEL HERE. Each caller decides what to show
/// instead (the raw wire string, or nothing); see the ⚠️ on
/// ``WorkspaceRole/fromWire(_:)``.
extension WorkspaceRole {
    var displayLabel: String {
        switch self {
        case .agency: "Administrator"
        case .client: "Member"
        case .viewer: "Viewer"
        }
    }
}
