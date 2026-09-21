@testable import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The workspace list's success side: the envelope it must affirm and the order it keeps.
///
/// ⚠️ A SEPARATE FILE ONLY BECAUSE `RepositoryTests` IS AT SWIFTLINT'S LENGTH CEILINGS.
/// The failure statuses (the degraded 503, a plain 503, an undecodable body) stay there.
final class WorkspaceListPageTests: XCTestCase {
    /// ⛔ A 200 THAT DOES NOT AFFIRM `success: true` IS A FAILURE, not an empty list.
    /// An empty list is a real answer ("you have no workspaces"), so a body that says
    /// nothing of the kind must not be read as one.
    func testAWorkspaceListThatDoesNotAffirmSuccessIsAFailure() async {
        let body = Bodies.workspaceList().replacingOccurrences(of: #""success":true"#, with: #""success":false"#)
        let transport = RepositoryTransport(json: body)

        let result = await WorkspaceRepository(client: .repositoryTest(transport)).list()

        XCTAssertEqual(result.failureOnly, .api(.decoding("WorkspaceListResponse did not affirm success=true")))
    }

    /// ⛔ THE ROWS KEEP THE SERVER'S ORDER. Index 0 is the workspace the browser treats
    /// as active, so a page that re-sorted them would put the app and the browser on
    /// different tenants.
    func testTheRowsKeepTheServersOrder() async {
        let transport = RepositoryTransport(json: Bodies.workspaceList(entries: [
            Bodies.workspaceEntry(id: "ws_2", name: "South Studio"),
            Bodies.workspaceEntry(id: "ws_1", name: "North Studio"),
        ]))

        let result = await WorkspaceRepository(client: .repositoryTest(transport)).list()

        XCTAssertEqual(result.successOnly?.workspaces.map(\.id), ["ws_2", "ws_1"])
    }
}
