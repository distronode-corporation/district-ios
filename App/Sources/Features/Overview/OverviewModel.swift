import DistrictModel
import Foundation
import Observation

/// Drives the Overview tab: one read of `GET /api/district/overview` for one
/// already-resolved workspace.
///
/// ⛔ THE WORKSPACE-LIST STATES ARE NOT THIS MODEL'S BUSINESS. Android's
/// `OverviewViewModel` owned both requests and therefore owned all five of the
/// list's outcomes as well — partial, degraded, empty, lapsed, signed out. Here
/// ``WorkspaceSessionModel`` owns the list and ``ShellView``'s gate renders those,
/// so this model only ever runs with a `workspaceId` that already resolved. Adding
/// a `noWorkspaces` case here would put a second, competing answer on the screen.
///
/// ⚠️ `@Observable` AND `@MainActor`, NOT `ObservableObject`. iOS 17 is the floor,
/// so the macro's per-property tracking applies. New models in this app must not
/// reach for `@Published`.
@MainActor
@Observable
final class OverviewModel {
    /// ⚠️ THREE CASES, AND `refreshing` IS WHY THERE ARE NOT FOUR. A re-read with
    /// content already on screen must not throw that content away — a spinner in
    /// place of numbers the user was reading is a worse answer than slightly stale
    /// numbers. So a refresh stays in ``content(_:refreshing:)`` and only a COLD
    /// load reaches ``loading``. Mirrors Android's `Content.refreshing` flag.
    ///
    /// ⚠️ NOTHING DRAWS A SECOND SPINNER FROM IT. SwiftUI's own `refreshable`
    /// indicator is on screen for exactly the span this flag is true; the flag's
    /// job is the fallback it PREVENTS, not an indicator it adds.
    enum State {
        case loading
        case content(OverviewResponse, refreshing: Bool)
        /// ⛔ NEVER RENDERED AS AN ABSENCE. "We could not look" and "there is
        /// nothing" read to a paying customer as account loss; ``FailureText``
        /// owns the wording and what may be offered.
        case failed(FailureText)
    }

    private(set) var state: State = .loading

    private let container: AppContainer

    /// ⚠️ TAKES THE CONTAINER, NEVER A REPOSITORY. Every repository is a `let` on
    /// the container built from the one ``ApiClient``; one constructed here would
    /// reach a second ``TokenRefreshCoordinator``.
    init(container: AppContainer) {
        self.container = container
    }

    /// Read the overview for one workspace.
    ///
    /// - Parameter workspaceId: ⛔ REQUIRED HERE EVEN THOUGH THE ROUTE ACCEPTS ITS
    ///   ABSENCE. Nil makes the SERVER choose, falling back to the first workspace
    ///   of its own membership listing — which cannot know what was selected in
    ///   this app, because that selection is local state rather than a cookie. The
    ///   result would be a screen labelled with one workspace's name showing
    ///   another's numbers, with no error anywhere.
    func load(workspaceId: String, refreshing: Bool = false) async {
        state = Self.pending(from: state, refreshing: refreshing)
        switch await container.overview.overview(workspaceId: workspaceId) {
        case let .success(response):
            state = Self.resolved(response, requested: workspaceId)
        case let .failure(error):
            state = .failed(FailureText.from(error))
        }
    }

    /// ⚠️ A REFRESH WITH NOTHING TO KEEP IS A COLD LOAD. Asking to refresh out of
    /// a failed state has no content to preserve, so it shows the spinner rather
    /// than nothing at all.
    private static func pending(from current: State, refreshing: Bool) -> State {
        guard refreshing else { return .loading }
        guard case let .content(response, _) = current else { return .loading }
        return .content(response, refreshing: true)
    }

    /// ⛔ A 200 ABOUT A DIFFERENT WORKSPACE IS A FAILURE, NOT A SUCCESS, and this is
    /// the check the iOS repository does not do while Android's does
    /// (`OverviewRepository.toActivity`'s sibling raises a synthetic 409
    /// `WORKSPACE_MISMATCH`). The response echoes which workspace actually answered
    /// precisely so a drifted local selection can be caught; without this the header
    /// would draw one tenant's name over another tenant's numbers. Retryable on
    /// purpose — reloading is what fixes it.
    private static func resolved(_ response: OverviewResponse, requested: String) -> State {
        guard response.workspaceId == requested else { return .failed(mismatch) }
        return .content(response, refreshing: false)
    }

    /// ⚠️ COMPUTED RATHER THAN A STORED `static let`, and only because `@Observable`
    /// is a macro that rewrites this type's stored properties. A computed static is
    /// something the macro provably does not touch, which is worth more here than
    /// the allocation it costs.
    private static var mismatch: FailureText {
        FailureText(
            message: "The workspace you selected is no longer the one we can report on. Please try again.",
            action: .retry
        )
    }
}
