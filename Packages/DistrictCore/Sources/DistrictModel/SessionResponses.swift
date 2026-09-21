import Foundation

/// A bare `{success:true}` acknowledgement.
///
/// ⚠️ ONE TYPE FOR SEVERAL ROUTES THAT GENUINELY ANSWER THE SAME SHAPE
/// (`auth/native/revoke`, `contacts/clear-intel`, `knowledge` DELETE, the
/// two push-registration routes, `district/devices/register` and
/// `district/devices/unregister`, and all four workspace-settings writes:
/// `workspace/persona`, `workspace/tools`, `workspace/directory` and
/// `workspace/routing-rules`). Sharing
/// it is safe only because the contract gate pins each fixture against it
/// separately — if one of those routes grows a field, that fixture fails and the
/// others do not, which is exactly the signal wanted. A shared type verified
/// against ONE fixture would be the opposite.
///
/// ⛔ THE FOUR SETTINGS WRITES ARE THE ONES WHERE THE ABSENCE OF ANY OTHER KEY IS
/// ITSELF LOAD-BEARING, and it is recorded here rather than left implicit: none of
/// them echoes the config it wrote, so a caller has to RE-READ
/// ``WorkspaceConfigResponse`` instead of adopting a body. See the ⛔ at the foot
/// of `WorkspaceConfigResponses.swift`.
///
/// ⛔ ON THE UNREGISTER PATH THE FLAG IS LOAD-BEARING RATHER THAN CEREMONIAL, and
/// that is the one place a reader should not skim it. The server answers
/// `{success:true}` even when there was no row to delete — deliberately, so the
/// route is not an existence oracle over the device-id space — but a delete that
/// THREW answers 500, and that means the row may still be live and this handset
/// may still receive another person's notifications after they sign in on it. So
/// "the flag was true" is the whole difference between "push is off for this
/// device" and "we do not know". `PushRegistrationResponse` on the Kotlin side
/// carries the identical note.
public struct SuccessResponse: Codable, Sendable {
    public let success: Bool
}

/// `POST /api/auth/native/devices/revoke` and
/// `POST /api/auth/native/revoke-all`.
///
/// ⛔ `revoked: 0` IS A SUCCESS, NOT A FAILURE, AND MUST NOT BE RENDERED AS ONE.
/// The per-device route answers `{success:true, revoked:0}` for a device id that
/// is not yours, deliberately: device ids are client-generated and opaque, so
/// answering 404 for a stranger's id and 200 for a real one would turn the route
/// into a membership oracle over the id space. Zero is also the honest answer
/// for the ordinary races — a row already revoked from another device, or a
/// chain that rotated between the list read and the tap. All of them resolve to
/// the same user-facing action: re-read the list and show what is there.
///
/// ⚠️ REVOKES REFRESH TOKENS, NOT ACCESS TOKENS. A revoked device keeps working
/// for the rest of its access token's ≤10 minutes. That bound is the server's
/// and no client-side count can shorten it, so a screen that says "signed out"
/// immediately is overstating what happened.
public struct DeviceRevokeResponse: Codable, Sendable {
    public let success: Bool
    public let revoked: Int
}

/// `GET /api/district/messages/unread-count`.
///
/// ⚠️ ``workspaceId`` IS ECHOED BACK AND IS WORTH CHECKING. The badge is read on
/// a timer while the workspace picker can change underneath it, so a response
/// that arrives after a switch belongs to the previous workspace; comparing this
/// against the active id is what stops a stale count being painted over the new
/// one.
public struct UnreadCountResponse: Codable, Sendable {
    public let success: Bool
    public let count: Int
    public let workspaceId: String
}
