import Foundation
import Observation

/// A number waiting for the dialler: "Call back" on the watch's call card, continued on this
/// phone by Handoff (``CallBackHandoff``).
///
/// ⛔ IT FILLS THE FIELD AND NEVER DIALS, the rule of the dialler's own "Call them back" rows
/// (`DialerModel.callBack(_:)`): a Handoff picked up from the App Switcher is one tap, and one
/// tap must never place a billable call.
///
/// ⚠️ OBSERVED RATHER THAN READ ONCE IN `init`: the dialler may already be the screen shown,
/// in which case the route the Handoff lands on is the one already there and no view is
/// created to read it. ``Pending/id`` makes a second offer of the same number a change.
@MainActor
@Observable
final class DialerPrefill {
    struct Pending: Equatable {
        let id = UUID()
        let workspaceId: String
        let number: String
    }

    private(set) var pending: Pending?

    /// A Handoff that arrived before the workspace list could say which workspace it names
    /// (a cold launch). ``ShellView`` resolves it once the list is in.
    @ObservationIgnored var handoff: (workspaceId: String, callId: String)?

    func offer(_ number: String, workspaceId: String) {
        pending = Pending(workspaceId: workspaceId, number: number)
    }

    /// The number for this workspace's dialler, once. ⚠️ Another workspace's is left alone.
    func take(workspaceId: String) -> String? {
        guard let pending, pending.workspaceId == workspaceId else { return nil }
        self.pending = nil
        return pending.number
    }
}
