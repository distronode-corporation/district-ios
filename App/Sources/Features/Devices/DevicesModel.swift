import DistrictData
import DistrictModel
import Foundation
import Observation

/// The device list itself.
///
/// ⛔ THE READ AND THE WRITES CARRY SEPARATE STATE, for the reason the contact
/// dossier does: a revoke that failed must not blank a list the user is reading.
/// The rows on screen are a correct answer already in hand, and replacing them
/// with an error would lose the very rows they were about to act on. So this
/// enum describes the READ only; the write's outcome lives beside it on the
/// model.
///
/// ⚠️ `ready([])` IS A LEGITIMATE ANSWER ON A PERFECTLY GOOD SESSION and is not
/// a failure. The route filters on `rotatedAt: null`, so a chain caught
/// mid-refresh is briefly invisible — on a single-device account that is an empty
/// list while the user is very much signed in. It renders as an explanatory empty
/// state and must never read as "you have been signed out".
enum DevicesListState {
    case loading
    case ready([DeviceSession])
    case failed(FailureText)
}

/// The device list's state machine.
///
/// ⛔ THIS MODEL DOES NOT SIGN THE USER OUT AND MUST NOT LEARN HOW. Two of its
/// actions end THIS installation's session server-side, and the local half of
/// that — revoking, wiping the Keychain, dropping the workspace selection, in that
/// order — belongs to ``SessionModel/signOut()`` and
/// to `AppContainer`. So both mutations ANSWER whether the caller must run it,
/// exactly the way ``ContactDetailModel/delete()`` answers whether to pop. A
/// model reaching for the session would also make the ordering a question about
/// two objects.
///
/// ⛔ THE SIGN-OUT IS DEMANDED ON A SUCCESSFUL RESPONSE REGARDLESS OF THE COUNT.
/// A `revoked: 0` for THIS device means the row was already gone (revoked from
/// another device, or rotated out from under the list), and in every one of those
/// cases the credential this app holds is dead or about to be. Staying signed in
/// would leave the user staring at a device list that no longer contains them,
/// which is the confusing half of both outcomes.
///
/// ⚠️ THE INSTALLATION ID IS READ ONCE, HERE, FROM THE CONTAINER. Reading it can
/// WRITE — ``DeviceIdentity/current(defaults:)`` mints and stores a UUID on first
/// call — and a model constructed per navigation is the wrong place for that. The
/// container already read it at launch; this copies the value.
@MainActor
@Observable
final class DevicesModel {
    private(set) var list: DevicesListState = .loading

    /// ⚠️ ONE FLAG FOR EVERY WRITE ON THE SCREEN, not one per row. Both writes
    /// end sessions and both are followed by a re-read, so allowing a second
    /// while the first is in flight would race two revokes against one refresh —
    /// and one of the two can sign this device out mid-flight. Same call
    /// ``ContactDetailModel`` makes with `saving`.
    private(set) var busy = false

    /// ⚠️ Shown ALONGSIDE the list, never instead of it.
    private(set) var mutationFailure: FailureText?

    /// ⛔ NOT A FAILURE, AND IT MUST NOT BE PAINTED AS ONE. `revoked: 0` comes
    /// back for a device id the account does not own (the server refuses to be a
    /// membership oracle), for a row another device already revoked, and for a
    /// chain that rotated between the list read and the tap. None of those is an
    /// error and all of them mean the same thing to the user: what you tapped is
    /// not what is there now, here is the current list. Rendering it in red would
    /// report a fault that did not happen; rendering it as success would claim a
    /// revocation that did not happen either.
    private(set) var nothingRevoked = false

    /// ⛔ THE ONLY TRUSTWORTHY WAY TO TELL WHICH ROW IS THE PHONE IN THE USER'S
    /// HAND. Device names are client-supplied free text, so two identical
    /// handsets on one account produce two identical-looking rows; deciding by
    /// name is a coin flip on exactly the account where getting it wrong signs out
    /// the phone you are holding and leaves the lost one live.
    let thisDeviceId: String

    private let devices: DevicesRepository

    init(container: AppContainer) {
        devices = container.devices
        thisDeviceId = container.deviceId
    }

    /// Read the list.
    ///
    /// - Parameter refreshing: ⚠️ TRUE KEEPS THE ROWS ON SCREEN. A re-read after
    ///   a revoke would otherwise blank a list the user is reading in order to
    ///   redraw almost the same thing, and on this screen the flicker lands
    ///   exactly when someone is checking whether their lost phone is gone.
    func load(refreshing: Bool = false) async {
        if !refreshing {
            list = .loading
        }
        switch await devices.list() {
        case let .success(rows):
            list = .ready(rows)
        case let .failure(error):
            // ⛔ A FAILURE, NEVER AN EMPTY LIST. "We could not look" and "there is
            // nothing" read to a paying customer as account loss when confused,
            // and on this screen the second one reads as "everything is signed
            // out".
            list = .failed(FailureText.from(error))
        }
    }

    /// Sign out one device. Answers true when the caller must run the local
    /// sign-out because the device signed out was this one.
    ///
    /// ⚠️ REVOKING ANOTHER DEVICE MUST NOT TOUCH THE LOCAL SESSION. It answers
    /// false and re-reads, which is the whole difference between "sign out my
    /// lost phone" and "sign myself out".
    func revoke(deviceId: String) async -> Bool {
        let signsOutThisDevice = deviceId == thisDeviceId
        guard beginWrite() else { return false }
        switch await devices.revoke(deviceId: deviceId) {
        case let .success(revoked):
            return await finish(revoked: revoked, signsOutThisDevice: signsOutThisDevice)
        case let .failure(error):
            failWrite(error)
            return false
        }
    }

    /// Sign out every device, INCLUDING THIS ONE. Answers true on success.
    ///
    /// ⛔ TRUE IS UNCONDITIONAL ON SUCCESS, because the server's "all" genuinely
    /// means all: its own route header says that sparing the caller would be a
    /// control nobody could reason about. A client that stayed signed in here
    /// would be holding a credential the server has already retired, and would
    /// discover that as a 401 on some later screen instead of as the sign-out the
    /// user asked for.
    func revokeAll() async -> Bool {
        guard beginWrite() else { return false }
        switch await devices.revokeAll() {
        case let .success(revoked):
            return await finish(revoked: revoked, signsOutThisDevice: true)
        case let .failure(error):
            failWrite(error)
            return false
        }
    }

    /// ⚠️ Both notices are transient by nature, so the screen dismisses them
    /// without a re-read.
    func dismissNotices() {
        mutationFailure = nil
        nothingRevoked = false
    }

    // MARK: - Internals

    /// ⛔ THE SECOND TAP IS DROPPED, NOT QUEUED. Both writes end sessions and both
    /// are followed by a re-read; a queued second one could revoke a row the
    /// refreshed list no longer shows, or race the local sign-out the first one is
    /// about to trigger.
    private func beginWrite() -> Bool {
        guard !busy else { return false }
        busy = true
        mutationFailure = nil
        nothingRevoked = false
        return true
    }

    private func finish(revoked: Int, signsOutThisDevice: Bool) async -> Bool {
        // ⚠️ Cleared BEFORE the caller acts on the answer. `signOut()` tears this
        // screen down, and leaving the flag set would strand a disabled list if
        // that teardown were ever made conditional.
        busy = false
        // ⚠️ Only meaningful for ANOTHER device. For this one the screen is going
        // away, so a notice nobody can read would be noise — and a zero count
        // still signs this device out, for the reason on the class.
        nothingRevoked = !signsOutThisDevice && revoked == 0
        guard !signsOutThisDevice else { return true }
        // ⚠️ Refreshing rather than reloading: the row that vanished is the only
        // change, and blanking the rest to redraw it would lose the user's place.
        await load(refreshing: true)
        return false
    }

    private func failWrite(_ error: ApiError) {
        busy = false
        mutationFailure = FailureText.from(error)
    }
}
