@testable import DistrictAI
import DistrictModel
import XCTest

/// The one vocabulary for roles and regions, shared by the member list, the workspace
/// picker and Support.
final class WorkspaceDisplayTests: XCTestCase {
    /// ⛔ THE WEB MEMBERS SCREEN'S WORDS (`workspaceAdminI18n.ts`, `roleLabels`), never
    /// the wire values. The picker used to say "Agency" where the member list said
    /// "Administrator".
    func testRolesReadAsTheWebMembersScreenNamesThem() {
        XCTAssertEqual(WorkspaceRole.agency.displayLabel, "Administrator")
        XCTAssertEqual(WorkspaceRole.client.displayLabel, "Member")
        XCTAssertEqual(WorkspaceRole.viewer.displayLabel, "Viewer")
    }

    /// ⛔ AN UNKNOWN REGION IS ITS OWN ID, UPPERCASED, NEVER A DEFAULT.
    func testRegionsAreNamedAndAnUnknownOneIsNeverCoercedToUS() {
        XCTAssertEqual(RegionCopy.label("us"), "US")
        XCTAssertEqual(RegionCopy.label("ca"), "Canada")
        XCTAssertEqual(RegionCopy.label("eu"), "Europe")
        XCTAssertEqual(RegionCopy.label("apac"), "APAC")
        XCTAssertEqual(RegionCopy.label("mx"), "MX")
    }
}
