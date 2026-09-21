import DistrictCall
import DistrictData
import DistrictModel
import Foundation

// The impure half of ``IncomingCallIdentity``: the one round trip that turns a
// ring push's two identifiers into a caller.
//
// ⛔ THE TYPE ITSELF AND EVERY RULE IT APPLIES LIVE IN `DistrictCall`, AND THE
// SPLIT IS THE POINT. `resolve(from:)` is a pure function of a ``CallSummary``: no
// UIKit, no CallKit, no SwiftUI, so it belongs on the tier `swift test` can reach
// on Linux, which is where the two sentinel rules that decide what this client
// hands the operating system as a phone number are pinned by tests. What is
// here is the part that genuinely cannot move: it needs a repository, a
// bearer, and the App's own notion of when a ring is still worth updating.

extension IncomingCallIdentity {
    /// Ask the workspace who is calling. nil for every unusable answer.
    ///
    /// ⛔ THE FETCH IS SECOND AND IT MAY NEVER BECOME FIRST. Apple terminates an app
    /// that receives a VoIP push without reporting a call, and repeated offences
    /// stop the pushes being delivered at all. The ⛔ on
    /// ``IncomingCallModel/incomingPush(uuid:event:)`` carries the detail. Reporting
    /// is synchronous with the push; this is a round trip that may take a second,
    /// may fail, and may never answer at all. Anything that put an `await` on this
    /// ahead of the report would trade the whole feature for a caller's name.
    ///
    /// ⛔ ONE REQUEST, NEVER RETRIED. A ring is bounded at thirty seconds and the
    /// server's rendezvous at about twenty-five, so a second attempt would be
    /// spending a caller's remaining silence on a cosmetic field. Every failure
    /// collapses to nil: a 404, a 401 from a handset that has not been unlocked
    /// since it booted, an offline radio and a malformed body are all the same
    /// thing here, which is "no name to show".
    ///
    /// ⚠️ ONE CASE CANNOT SUCCEED, BY CONSTRUCTION, AND IS NOT A BUG. Before the
    /// first unlock after a reboot the Keychain item is unreadable
    /// (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, see the ⛔ on
    /// ``KeychainTokenStore``), so ``TokenRefreshCoordinator`` has no bearer to
    /// hand over and ``ApiClient`` answers a local 401 rather than sending an
    /// unauthenticated request. That handset rings with the placeholder every time
    /// until somebody unlocks it once. Nothing here should be "fixed" to make it
    /// work.
    ///
    /// ⚠️ nil ALSO FOR A SUCCESSFUL READ THAT RESOLVED NOTHING, so a caller with
    /// no number and no contact leaves the ring exactly as it was rather than
    /// reporting an update that says nothing. See ``IncomingCallIdentity/isKnown``.
    ///
    /// ⛔ NOTHING HERE IS LOGGED. A caller's number is the most sensitive thing this
    /// screen will ever hold, and a log line outlives the call.
    static func lookUp(
        _ calls: CallsRepository,
        workspace: WorkspaceID,
        call: CallID
    ) async -> IncomingCallIdentity? {
        let outcome = await calls.detail(workspaceId: workspace.rawValue, callId: call.rawValue)
        guard case let .success(summary) = outcome else { return nil }
        let identity = resolve(from: summary)
        return identity.isKnown ? identity : nil
    }
}
