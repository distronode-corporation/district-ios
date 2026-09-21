import DistrictModel
import DistrictNetwork
import Foundation

/// Whether the active workspace's owner still has setup to finish (setup wizard plan 2.5).
///
/// ⚠️ ON THE OVERVIEW'S REPOSITORY RATHER THAN A `SetupRepository` OF ITS OWN, which is
/// where Android put it. The answer drives one optional card on the overview and nothing
/// else, and a new repository would be one more `let` on `AppContainer`, a file that sits
/// at SwiftLint's 500-line ceiling. The seam can move the day a second screen reads it.
public extension OverviewRepository {
    /// The raw read, for callers that want the body.
    func districtSetup(workspaceId: String) async -> Result<DistrictSetupResponse, ApiError> {
        await client.send(
            DistrictEndpoints.districtSetup(workspaceId: workspaceId),
            as: DistrictSetupResponse.self
        )
    }

    /// Whether to offer the owner the rest of setup.
    ///
    /// ⛔ EVERY FAILURE IS "NO", AND THAT IS THE DESIGN RATHER THAN SWALLOWING. A **403** is
    /// the ordinary answer for anyone who is not the owner, and a network error or a decode
    /// failure must never block or replace the overview the card sits on, so none of them
    /// has anything to show. The overview's own read reports real failures.
    func needsWebSetup(workspaceId: String) async -> Bool {
        switch await districtSetup(workspaceId: workspaceId) {
        case let .success(response): response.needsWebSetup
        case .failure: false
        }
    }
}
