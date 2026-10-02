import DistrictData
import DistrictModel
import Foundation

/// The paged call log for ONE workspace.
///
/// ⚠️ THE ONE PAGED-FEED MACHINE, NOT A COPY OF IT. Contacts runs the same
/// ``PagedFeedModel``; see the ⛔ there.
///
/// ⚠️ THE WORKSPACE IS FIXED FOR THE LIFETIME OF THIS MODEL. Switching workspace must
/// build a new one rather than mutate this: ``OffsetPager``'s offsets and its dedup
/// set are only meaningful within one tenant, and reusing them across a switch would
/// mix two workspaces' rows. ``CallLogView`` enforces it with `.id(workspaceId)`.
typealias CallLogModel = PagedFeedModel<CallSummary>

extension PagedFeedModel where Row == CallSummary {
    /// ⚠️ THE PAGER IS BUILT FROM THE CONTAINER'S ONE REPOSITORY, NEVER FROM A
    /// REPOSITORY CONSTRUCTED HERE. A second `CallsRepository` would carry a second
    /// `ApiClient` and reach a second `TokenRefreshCoordinator`; see the ⛔ on
    /// ``AppContainer``.
    convenience init(container: AppContainer, workspaceId: String) {
        self.init(pager: container.calls.pager(workspaceId: workspaceId))
    }
}
