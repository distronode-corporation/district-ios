import DistrictAuthCore
import DistrictNetwork
import Foundation

// ⛔ SPLIT OUT OF `AppContainer.swift` BY A LINE CEILING, NOT BY A DESIGN CHANGE.
// That file sits against swiftlint's 500-line `file_length`, which `--strict` makes
// an error. Keep the glue below here, and keep it empty.

/// The native-auth client, with both of its seams pinned to the auth layer's
/// types.
///
/// ⛔ THE FIVE EXTENSIONS BELOW ARE THE WHOLE OF THE APP-SIDE AUTH GLUE, AND
/// THEY ARE EMPTY BY DESIGN. ``NativeAuthClient`` lives in `DistrictNetwork`
/// because every line of it is pure logic over the ``HTTPTransport`` seam and is
/// therefore testable on the Linux tier, where nothing in this directory is.
/// `DistrictNetwork` and `DistrictAuthCore` are siblings, though — neither
/// depends on the other — so the network module cannot name
/// ``NativeTokenResponse``, ``RefreshResult``, ``RevokeOutcome`` or either client
/// protocol. It takes them as generic parameters, and these lines supply them:
/// each conformance is satisfied by members those types already declare (a Swift
/// enum case witnesses a static requirement, which is why even
/// ``RevokeDeferral``'s `unexpected(status:)` needs no code).
///
/// ⛔ NOTHING HERE MAY GROW A BODY. A mapping function written here would be a
/// security-relevant status map living on the one tier with no tests and a
/// macOS-only compiler — the refresh one (429 is not a dead
/// credential; a 400 has not spent the token) or the revoke one (ONLY a 200 lets
/// the credential go). `NativeAuthSeamTests` declares these same conformances
/// against mirrors of these types precisely so the pattern cannot break here
/// without breaking there first.
typealias AppNativeAuthClient = NativeAuthClient<NativeTokenResponse, RefreshResult, RevokeOutcome>
extension NativeTokenResponse: NativeAuthTokenWire {}

extension RefreshResult: NativeRefreshOutcome {}

extension RevokeDeferral: NativeRevokeDeferral {}

extension RevokeOutcome: NativeRevokeOutcome {}

extension NativeAuthClient: RefreshClient where Refresh == RefreshResult {}

extension NativeAuthClient: RevokeClient where Revoke == RevokeOutcome {}
