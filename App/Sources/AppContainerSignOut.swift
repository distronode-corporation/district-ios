import Foundation

/// The two sign-out entry points ``AppContainer`` offers its callers.
///
/// ⛔ SPLIT OUT OF `AppContainer.swift` BECAUSE THAT FILE SITS AGAINST THE
/// `file_length` CEILING `swiftlint --strict` PROMOTES TO AN ERROR. It is the same call `DialerTasks.swift` and
/// `IncomingCallTasks.swift` already made about their own models, and nothing here is
/// a separate concern from the container.
///
/// ⚠️ THE PRICE IS `signOutCoordinator` WIDENING FROM `private` TO
/// MODULE-VISIBLE, because Swift's `private` is file-scoped and an extension in
/// another file cannot reach one. ⛔ `store` DELIBERATELY DID NOT WIDEN: it is the
/// only token store in the process and its `private` is what stops a second owner
/// appearing. Widen nothing else without the same test.
///
/// ⚠️ Extracting the TAIL rather than the initialiser was deliberate: the init is
/// where the reasoning density is, and moving it would have split the comments from
/// the construction order they describe.
extension AppContainer {
    /// Sign out, on the server and locally.
    ///
    /// ✅ SERVER-SIDE REVOCATION IS WIRED. `POST /api/auth/native/revoke` is
    /// called with the stored refresh token before anything wipes it, and the
    /// token is written to ``TokenStore``'s revoke outbox first so a 503 (the
    /// route's answer when its database write threw, meaning the session may
    /// still be live for the rest of its 60-day window) is retried on a later
    /// launch rather than stranding a credential nobody is tracking. The
    /// ordering, and the reason the local wipe happens either way, are on
    /// ``SignOutCoordinator``.
    ///
    /// ⛔ THE ORDER IS UNREGISTER, THEN REVOKE, THEN FORGET, AND ONLY THE FIRST TWO
    /// ARE HERE. `beforeRevoke` is the push-token unregister
    /// (``PushRegistrar/unregisterForSignOut()``): it authenticates with the ACCESS
    /// token, so it MUST run before the revoke ends the session — afterwards there
    /// is no credential left to make the call with and the row sits registered
    /// until APNs eventually reports the token gone. The third step,
    /// ``PushRegistrar/forget()``, belongs to the caller because it must also run
    /// on sign-outs that never reach this method at all (see
    /// ``SessionModel/refreshPhase()``).
    ///
    /// ⛔ INJECTED RATHER THAN CALLED DIRECTLY, so this container does not gain a
    /// reference to a `UIKit`-shaped object it would then own the lifetime of. The
    /// hook is `() async -> Void` and NOT a `Result`: a failed unregister must not
    /// be able to stop the revoke, because a live refresh token is the worse thing
    /// to leave behind, and the server retires a stale push row on its own.
    ///
    /// ⚠️ DEFAULTED TO A NO-OP so a caller with no push to withdraw (and any
    /// future test) is not forced to supply one.
    func signOut(beforeRevoke: () async -> Void = {}) async {
        await beforeRevoke()
        await signOutCoordinator.signOut()
    }

    /// Finish any sign-out whose revoke never reached the server.
    ///
    /// ⚠️ CALLED FROM A `.task` ON THE ROOT VIEW rather than from `init`. Both
    /// hooks run on every cold start, signed in or not, which is the property
    /// that matters (every other trigger is conditional on state a signed-out
    /// user no longer has — see ``SignOutCoordinator/drainPendingRevoke()``).
    /// `.task` is chosen because it gives the work a lifetime SwiftUI owns and
    /// cancels: a detached task spawned from `init` would outlive nothing in
    /// particular, and `AppContainer` is `@MainActor`, so starting unstructured
    /// concurrency from its initialiser is the shape that later grows into a
    /// container that is not fully constructed when its own task reads it.
    func drainPendingRevoke() async {
        await signOutCoordinator.drainPendingRevoke()
    }
}
