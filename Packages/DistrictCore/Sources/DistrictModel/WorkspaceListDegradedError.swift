import Foundation

/// The 503 body from `GET /api/district/workspace/list` when one or more region
/// databases could not be reached.
///
/// ⛔ NEVER RENDER THIS AS AN ABSENCE OF DATA. The route answers 503 with this
/// body rather than an empty 200 precisely so the client can tell "we could not
/// look" from "there is nothing" — which, confused, reads to the user as account
/// loss. It needs its own case and its own copy, not the empty state.
///
/// ⛔ IT IS ITS OWN TYPE RATHER THAN ``ApiErrorEnvelope`` BECAUSE OF
/// ``degradedRegions``. Decoding it as the generic envelope would drop that
/// array silently — `JSONDecoder` cannot reject unknown keys — and the screen
/// would lose the only information that makes the message specific. The strict
/// gate is what makes that mistake fail: the key would go missing on re-encode.
///
/// ⚠️ NO `success` KEY AT ALL. This is the newer `{error, code}` helper shape,
/// so a DTO that required `success` would throw on the one response the user
/// most needs explained.
public struct WorkspaceListDegradedError: Codable, Sendable {
    /// Server-authored copy. ⛔ Branch on ``code``, never on this.
    public let error: String
    /// `REGIONS_DEGRADED`. See ``ApiErrorCode/regionsDegraded``.
    public let code: String
    /// Which regions could not be reached, e.g. `["eu", "apac"]`.
    ///
    /// ⚠️ ALSO PRESENT ON A **SUCCESSFUL** LIST. A 200 can carry a non-empty
    /// `degradedRegions` when some regions answered and others did not — that is
    /// the partial case (`district-workspace-list-partial.json`), where the
    /// workspaces array is genuinely incomplete and must be captioned as such.
    /// A client that only handled this array on the 503 path would silently
    /// present a partial list as the whole account.
    public let degradedRegions: [String]
}
