import DistrictData
import Foundation
import Observation

/// Whether the overview offers the owner the rest of the setup wizard.
///
/// ⛔ A MODEL OF ITS OWN, NOT A FOURTH ``OverviewModel/State``. The card is optional and
/// the overview is not: every failure here, a member's ordinary **403** included, means
/// "offer nothing" and must never replace or delay the numbers. Folding it into the
/// overview's state would give a setup read the power to fail the screen.
///
/// ⛔ ASKED AFTER THE OVERVIEW HAS RENDERED, never before or alongside it, so the one read
/// the screen depends on never waits for one it does not.
///
/// ⚠️ THE FETCH IS A CLOSURE so the workspace-switch rule can be tested without a network.
/// The production one is the container's ``OverviewRepository`` (see
/// ``init(container:)``), never a repository built here.
@MainActor
@Observable
final class FinishSetupModel {
    /// Whether to draw the card, for ``workspaceId``.
    private(set) var isOffered = false
    /// The workspace in view. An answer about any other workspace is dropped.
    private(set) var workspaceId: String?

    private let fetch: @Sendable (String) async -> Bool

    init(fetch: @escaping @Sendable (String) async -> Bool) {
        self.fetch = fetch
    }

    convenience init(container: AppContainer) {
        let overview = container.overview
        self.init(fetch: { workspaceId in await overview.needsWebSetup(workspaceId: workspaceId) })
    }

    /// The workspace in view changed (or was re-confirmed).
    ///
    /// ⚠️ A SWITCH CLEARS THE CARD AT ONCE; THE SAME WORKSPACE KEEPS IT. Another tenant's
    /// card must not linger over this one's numbers while its answer is in flight, but a
    /// pull-to-refresh of the same workspace should not make the card blink. Android keeps
    /// it through a refresh the same way.
    func workspaceChanged(to workspaceId: String?) {
        guard workspaceId != self.workspaceId else { return }
        self.workspaceId = workspaceId
        isOffered = false
    }

    /// Ask whether `workspaceId`'s owner has setup left to finish.
    ///
    /// ⛔ A LATE ANSWER FOR A WORKSPACE NO LONGER IN VIEW IS DROPPED. The user can switch
    /// tenant while this is in flight, and adopting the answer then would offer one
    /// workspace's setup over another's overview.
    func refresh(workspaceId: String) async {
        workspaceChanged(to: workspaceId)
        let answer = await fetch(workspaceId)
        guard self.workspaceId == workspaceId else { return }
        isOffered = answer
    }
}
