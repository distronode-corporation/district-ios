import DistrictModel
import DistrictNetwork
import Foundation

/// The account's signed-in devices, and the two ways to end one.
///
/// ⛔ NO CACHE, AND HERE THAT IS A SAFETY PROPERTY RATHER THAN TIDINESS. This
/// list is what someone consults after losing a phone. A cached row would answer
/// "is my lost phone still signed in" with a value from before they asked, and
/// both directions of that error are bad: a stale live row invites a revoke that
/// already happened, and a stale absent row says the device is gone when it is
/// not.
///
/// ⛔ ACCOUNT-SCOPED, NOT WORKSPACE-SCOPED, and nothing here takes a
/// `workspaceId` because nothing could. A native session belongs to a USER and a
/// device belongs to a person across every workspace they hold; the scope comes
/// from the verified session and there is no parameter that could widen it. See
/// the ⛔ on ``DistrictEndpoints/devices()``.
///
/// ⛔ THIS LAYER DOES NOT SIGN THE USER OUT AND MUST NOT LEARN HOW. Revoking THIS
/// device, or revoking all, ends this installation's session server-side — but
/// the local half (revoking through `SignOutCoordinator`, wiping the Keychain,
/// dropping the workspace selection)
/// is `AppContainer`'s job and the ORDER of it matters. These functions report
/// what the server did and nothing more; the screen wires the consequence.
///
/// ⚠️ ALL THREE ROUTES AUTHENTICATE WITH THE SESSION BEARER, which is why they
/// can live on one `ApiClient` alongside every district route. That is worth
/// stating because the neighbouring `POST /api/auth/native/revoke` does NOT: it
/// takes the refresh TOKEN as its credential and is reached through
/// ``SignOutCoordinator``, never through here. The difference is who can call
/// it — a token route can only ever end the session of whoever holds the token,
/// so "sign out my lost phone" is unreachable through it by construction.
public struct DevicesRepository: Sendable {
    private let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    /// Read the device list, newest first.
    ///
    /// ⚠️ ENVELOPE-CHECKED EVEN THOUGH THE DTO'S FIELDS ARE REQUIRED. A required
    /// field rejects `{}`; it does not reject a well-formed body that says
    /// `success: false`, and this route's own catch branch answers exactly that
    /// shape on a 200 if the headers are already written. Without the check, "we
    /// could not look" would render as "you have no devices" — the same
    /// conflation that routed a paying customer to a checkout page on the web.
    ///
    /// ⚠️ Rate limited at 30/min PER ACCOUNT, sized for a settings screen. Nothing
    /// may poll this.
    public func list() async -> Result<[DeviceSession], ApiError> {
        let outcome = await client.send(DistrictEndpoints.devices(), as: DevicesResponse.self)
        return outcome
            .flatMap { ResponseEnvelope.affirm("DevicesResponse", $0.success, $0) }
            .map(\.devices)
    }

    /// Sign out one install, answering how many chains the server revoked.
    ///
    /// ⛔ `0` IS A SUCCESS AND MUST NOT BE PROMOTED TO AN ERROR HERE. The route
    /// answers `{success: true, revoked: 0}` for a device id that is not yours,
    /// deliberately: ids are client-generated and opaque, so a 404 for a
    /// stranger's id and a 200 for a real one would turn the route into a
    /// membership oracle over the id space. Zero is equally the honest answer for
    /// the ordinary races — a row another device already revoked, or a chain that
    /// rotated between the list read and the tap. This layer cannot tell those
    /// apart and neither can the server, so the count is carried through
    /// untouched and the screen decides what to say.
    ///
    /// ⛔ A COUNT RATHER THAN `Void`, WHICH IS THE WHOLE REASON THIS RETURNS
    /// ANYTHING. "Nothing was revoked" is a distinct outcome from "one chain was
    /// revoked", and collapsing it into success claims a revocation that did not
    /// happen while rendering it as a failure reports a fault that did not
    /// happen either.
    ///
    /// ⚠️ A THROWN WRITE IS NOT "nothing to revoke": the route answers 500, and
    /// that arrives here as ``ApiError/http(status:message:)``. The session may
    /// still be live, so a caller must not report success.
    ///
    /// ⚠️ REVOKES REFRESH TOKENS, NOT ACCESS TOKENS. A revoked device keeps
    /// working for the rest of its access token's ten minutes; that bound is the
    /// server's and no client-side count can shorten it.
    public func revoke(deviceId: String) async -> Result<Int, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.revokeDevice(deviceId: deviceId),
            as: DeviceRevokeResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("DeviceRevokeResponse", $0.success, $0) }
            .map(\.revoked)
    }

    /// Sign out every install, INCLUDING THIS ONE.
    ///
    /// ⛔ THE CALLER IS NOT SPARED, AND THAT IS THE SERVER'S DECISION rather than
    /// an oversight: an "all" that quietly excepted the device that asked would be
    /// a control nobody could reason about. A caller must treat success as this
    /// device's own sign-out and run the local half itself, because the server has
    /// no way to tell this process that its credential just died — it will simply
    /// 401 on the next request.
    ///
    /// ⚠️ `0` IS A LEGITIMATE SUCCESS HERE TOO: a second press, after the first
    /// revoked everything. It still signs this device out, for the reason above.
    public func revokeAll() async -> Result<Int, ApiError> {
        let outcome = await client.send(DistrictEndpoints.revokeAllDevices(), as: DeviceRevokeResponse.self)
        return outcome
            .flatMap { ResponseEnvelope.affirm("DeviceRevokeAllResponse", $0.success, $0) }
            .map(\.revoked)
    }
}
