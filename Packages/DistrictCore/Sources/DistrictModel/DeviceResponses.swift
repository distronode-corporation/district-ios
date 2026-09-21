import Foundation

/// One installation with a live refresh-token chain on this account.
///
/// ⛔ `deviceName` IS CLIENT-SUPPLIED AND UNTRUSTED. The token route's schema
/// says so where the value is stored, and the device-list route repeats it: this
/// string is whatever the app that signed in sent, echoed back for display. It is
/// not a device attestation and nothing may be DECIDED from it — least of all
/// which row is the phone in the user's hand, which is answered by comparing
/// ``deviceId`` against `AppContainer.deviceId`. Two identical handsets on one
/// account produce two identical-looking names, so a screen that marked "this
/// device" by name would be a coin flip on exactly the account where getting it
/// wrong means signing out the phone you are holding and leaving the lost one
/// live.
///
/// ⛔ `lastUsedAt` IS "LAST REFRESHED", NOT "LAST USED", AND A LABEL MUST NOT
/// OVERSTATE IT. The server stamps it only when a refresh token ROTATES
/// (`rotateNativeSession`), and the access token lives ten minutes — so a phone
/// in continuous use reports a value up to about ten minutes stale, and a phone
/// that was opened once and left alone reports the moment of that open forever
/// after. Good enough for "which of these is the one I am holding", useless for
/// anything finer.
///
/// ⚠️ BOTH OPTIONALS ARE GENUINELY NULL ON THE WIRE, NOT ABSENT. `deviceName` is
/// `String | null` server-side because the field is optional on token exchange,
/// and `lastUsedAt` is `Date | null` because a session that has never been
/// refreshed has never been stamped — which is every session for its first ten
/// minutes, i.e. exactly the row a user sees right after signing in.
/// `district-devices.json` carries one row of each shape, and the two nulls have
/// exact `allowedExplicitNulls` paths so a decoder that regressed to non-null
/// fails the strict gate rather than a phone.
///
/// ⚠️ `platform` AND `createdAt` ARE NON-OPTIONAL BECAUSE THE COLUMNS ARE.
/// `NativeSession.platform` is a plain non-null `String` (an enum would have
/// meant a migration on four regional databases) and `createdAt` has a default,
/// so `listNativeDevices` can never select a null into either.
///
/// ⚠️ THE TWO TIMESTAMPS ARE ISO-8601 STRINGS, NOT INSTANTS. `NextResponse.json`
/// serialises a `Date` through `JSON.stringify`, and this module deliberately
/// owns no date parsing — the same call ``CallSummary`` and ``WorkspaceMember``
/// make, for the same reason: one decoder strategy would have to be right for
/// every timestamp on the surface and they do not all agree.
public struct DeviceSession: Codable, Sendable {
    public let deviceId: String
    /// ⛔ Display only, and untrusted. See the class doc.
    public let deviceName: String?
    /// "ios" or "android". Free text on the wire; the server's zod enum is the
    /// real gate, and a blank value is a rendering problem rather than an error.
    public let platform: String
    /// ⛔ Last ROTATION, not last use. Null until the first refresh.
    public let lastUsedAt: String?
    public let createdAt: String
}

/// `GET /api/auth/native/devices` — every live install on this account, newest
/// first.
///
/// ⛔ AN EMPTY LIST IS A LEGITIMATE SUCCESS AND IS NOT A SIGN-OUT. The route
/// filters on `rotatedAt: null`, so a chain caught mid-refresh has its old row
/// already stamped and its successor not yet visible to the query — which on a
/// single-device account is an EMPTY list arriving on a perfectly good session.
/// It renders as an explanatory empty state, never as a failure and never as a
/// reason to re-authenticate.
///
/// ⚠️ `devices` IS NON-OPTIONAL because `findMany` always emits the array; an
/// absent key is contract drift, and the strict gate is what catches it. The
/// `success` flag is still checked by hand at the repository, because a required
/// field rejects `{}` and does not reject a well-formed `success: false`.
public struct DevicesResponse: Codable, Sendable {
    public let success: Bool
    public let devices: [DeviceSession]
}

// ⛔ THE PUSH PAIR IS NOT HERE, AND THAT IS THE ANSWER RATHER THAN AN OMISSION.
// `POST /api/district/devices/register` and `/unregister` — the push surface,
// a DIFFERENT prefix from the session-management routes above and one that 404s
// them — both answer exactly `{"success": true}`, which is what
// ``SuccessResponse`` already is. `district-device-register.json` and
// `district-device-unregister.json` are therefore gated against that type in
// `ImplementedFixtures`, the same way `district-native-revoke.json`,
// `district-clear-intel.json`, `district-knowledge-delete.json`,
// `district-draft-delete.json` and `district-directory-patch.json` are.
//
// ⚠️ SHARING THE TYPE IS SAFE ONLY BECAUSE THE GATE PINS EACH FIXTURE
// SEPARATELY. Two bespoke structs with identical members would prove nothing the
// shared one does not, and would read as though the two bodies were known to
// differ. The day either route grows a field, ITS fixture fails and the others do
// not — and the answer then is to split a real type out to here, not to widen
// ``SuccessResponse``. The Kotlin client took the identical decision, and wrote
// the identical caveat, on `PushRegistrationResponse`.
//
// ⚠️ NEITHER ROUTE ECHOES THE TOKEN, THE DEVICE ID OR THE PLATFORM BACK, which is
// the server's decision and the right one: a push token identifies one
// installation, and a response that repeated it would put it in one more log.
// Nothing here should grow a field for it.
