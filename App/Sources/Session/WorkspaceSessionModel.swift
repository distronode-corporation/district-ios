import DistrictData
import DistrictModel
import Foundation
import Observation

/// The workspace picture the shell renders, with every "nothing to show" kept
/// apart from every other one.
///
/// ⛔ SIX DISTINCT NON-CONTENT CASES, AND COLLAPSING ANY TWO OF THEM IS THE BUG THIS
/// TYPE EXISTS TO PREVENT. A 503 `REGIONS_DEGRADED`, a 200 carrying `degradedRegions`,
/// an account with no workspaces and an account whose workspaces are all withheld for
/// non-payment are four different sentences and four different offers. Rendering
/// the first as the third routes a paying customer to a checkout page.
enum WorkspaceSessionState {
    case loading

    /// A complete list, with the workspace to operate on.
    case content(WorkspaceListPage, selected: WorkspaceEntry)

    /// ⛔ A SUCCESS THAT IS GENUINELY INCOMPLETE, and the half every client misses.
    /// Some regions answered and others did not, so the rows shown are real but they
    /// are not all of them. It arrives GREEN, on a 200, with a short list. Caption
    /// it; never present it as the whole account.
    case partial(WorkspaceListPage, selected: WorkspaceEntry, degradedRegions: [String])

    /// ⛔ NOTHING RESOLVED AND A REGION IS DOWN: the 503. "We could not look", not
    /// "there is nothing".
    case degraded(String)

    /// A real answer: this account genuinely belongs to no workspace.
    case empty

    /// ⛔ AN EMPTY LIST WITH A NON-ZERO `inactiveCount` IS A LAPSED ACCOUNT, NOT A
    /// NEW ONE, and it is the only way to tell them apart. ⛔ Neither screen may
    /// offer a way to PAY: billing is read-only in this app (App Store Review
    /// Guideline 3.1.3(b)), so the lapsed copy names the website and stops there.
    case lapsed(inactiveCount: Int)

    case failed(FailureText)
}

/// Resolves which workspace the app is operating on, and holds the list behind it.
///
/// ⛔ THE ACTIVE WORKSPACE IS THIS CLIENT'S OWN STATE, NOT THE SERVER'S. The
/// browser's active workspace is the httpOnly `distronode_workspace_id` cookie, which
/// the lister promotes to index 0 and every server-side `requireWorkspaceRole`
/// fallback then reads. A bearer-token client holds no cookies, so it sends
/// `workspaceId` explicitly on every request instead, and remembers the choice in
/// ``WorkspaceSelectionStore``.
@MainActor
@Observable
final class WorkspaceSessionModel {
    private(set) var state: WorkspaceSessionState = .loading

    private let container: AppContainer
    private let selection: WorkspaceSelectionStore

    init(container: AppContainer, selection: WorkspaceSelectionStore = WorkspaceSelectionStore()) {
        self.container = container
        self.selection = selection
    }

    /// The workspace to send on every request, or nil while none has resolved.
    var workspaceId: String? {
        selectedEntry?.id
    }

    /// This member's role in the selected workspace.
    ///
    /// ⛔ PARSED THROUGH ``WorkspaceRole/fromWire(_:)``, WHICH FAILS CLOSED. nil means
    /// "the role could not be established", never "assume client": the tempting
    /// default is what the SERVER falls back to for a member with no explicit row,
    /// but the server reaches that conclusion having confirmed the membership exists.
    ///
    /// ⚠️ THIS IS THE LIST'S ROLE, WHICH THE OVERVIEW MAY LATER OVERRIDE. The
    /// server can grant `agency` for support access with no membership row at all, and
    /// `GET /api/district/overview` reports the EFFECTIVE role while
    /// `workspace/list` reports the membership one. A destination that needs the
    /// effective role must take it from the overview, not from here.
    var role: WorkspaceRole? {
        WorkspaceRole.fromWire(selectedEntry?.role)
    }

    /// Every workspace on the current page, for a picker.
    var workspaces: [WorkspaceEntry] {
        page?.workspaces ?? []
    }

    var selectedEntry: WorkspaceEntry? {
        switch state {
        case let .content(_, selected): selected
        case let .partial(_, selected, _): selected
        default: nil
        }
    }

    var page: WorkspaceListPage? {
        switch state {
        case let .content(page, _): page
        case let .partial(page, _, _): page
        default: nil
        }
    }

    /// Read the list and resolve a selection.
    func load() async {
        state = .loading
        switch await container.workspaces.list() {
        case let .success(page):
            apply(page)
        case let .failure(error):
            state = Self.failureState(error)
        }
    }

    /// Switch workspace, persist the choice, and re-read.
    ///
    /// ⚠️ TAKES AN ID RATHER THAN AN ENTRY so a caller cannot pass a row from a stale
    /// list, and does NOT validate it here: validation belongs where the list is
    /// known, in ``apply(_:)``, which drops a selection that no longer appears. The
    /// server is the final authority regardless and answers 403 for an id the caller
    /// is not a member of.
    func select(_ workspaceId: String) async {
        selection.setSelectedWorkspaceId(workspaceId)
        await load()
    }

    /// ⛔ THE PRECEDENCE HERE IS NOT ARBITRARY, AND EVERY STEP RESOLVES AGAINST THE
    /// LIST THE SERVER JUST SENT. An id is only ever adopted if it appears in
    /// `workspaces`, which is what makes a stale, revoked or lapsed selection
    /// harmless: it fails to match and the next candidate is used.
    ///
    ///   1. This device's explicit choice, the user's most recent and most local
    ///      intent.
    ///   2. The account's stored default, so a fresh install lands where the browser
    ///      would. ⚠️ The server echoes `defaultWorkspaceId` WITHOUT checking it
    ///      against the list, so it genuinely can name a workspace that is not there.
    ///   3. Index 0, the server's own answer to "which is active": it has already
    ///      applied owned-first ordering. ⛔ Do NOT re-sort and then treat the new
    ///      first element as the default, or the app and the browser disagree about
    ///      which tenant is in view.
    ///
    /// Steps 2 and 3 are ``WorkspaceListPage/defaultSelection``.
    private func apply(_ page: WorkspaceListPage) {
        let stored = selection.selectedWorkspaceId()
        let selected = page.workspaces.first(where: { $0.id == stored }) ?? page.defaultSelection

        // ⚠️ Drop a selection that no longer resolves, so the app stops re-reading a
        // dead id on every launch. ⛔ Only when the list is COMPLETE: forgetting it on
        // an incomplete answer would discard a valid choice because one region was
        // briefly unreachable. Single-line condition on purpose (see the ⚠️ on
        // `WorkspaceListPage.defaultSelection`).
        if let stored, selected?.id != stored, !page.isPartial {
            selection.setSelectedWorkspaceId(nil)
        }

        guard let selected else {
            state = Self.vacantState(for: page)
            return
        }
        guard page.isPartial else {
            state = .content(page, selected: selected)
            return
        }
        state = .partial(page, selected: selected, degradedRegions: page.degradedRegions)
    }

    /// A list with no selectable row. ⛔ The order of these three checks is the
    /// answer: lapsed beats incomplete beats empty, because a wrong "you have
    /// nothing" is the expensive one.
    private static func vacantState(for page: WorkspaceListPage) -> WorkspaceSessionState {
        if page.isBlockedByBilling {
            return .lapsed(inactiveCount: page.response.inactiveCount)
        }
        guard page.isPartial else { return .empty }
        return .degraded(degradedText(regions: page.degradedRegions).message)
    }

    private static func failureState(_ error: WorkspaceListError) -> WorkspaceSessionState {
        guard case let .regionsDegraded(_, regions) = error else { return .failed(FailureText.from(error)) }
        return .degraded(degradedText(regions: regions).message)
    }

    /// ⚠️ ROUTED BACK THROUGH ``FailureText`` RATHER THAN WORDED HERE, so the 503 and
    /// the partial 200 say the same thing about the same regions. Two copies of this
    /// sentence would drift, and the one that drifted would be the rarer path.
    private static func degradedText(regions: [String]) -> FailureText {
        FailureText.from(WorkspaceListError.regionsDegraded(message: nil, regions: regions))
    }
}
