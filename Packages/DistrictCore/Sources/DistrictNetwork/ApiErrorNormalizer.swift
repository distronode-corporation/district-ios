import DistrictModel
import Foundation

/// Turns one HTTP outcome — a status code and whatever bytes came back — into
/// the single ``ApiError`` every District call resolves to.
///
/// ⛔ CALLERS MUST NEVER PARSE AN ERROR BODY THEMSELVES. There are three
/// envelopes (see ``ApiErrorEnvelope``) and a fourth non-case (a body that is not
/// JSON at all), and the one thing that keeps them interchangeable to a screen is
/// that exactly one function collapses them. The Kotlin client holds the same
/// rule in `DistrictApiClient.mapFailure` / `parseError`, and the mapping below
/// is derived from it line by line so the two clients answer the same bytes the
/// same way.
///
/// ⚠️ THE ONE DELIBERATE DIVERGENCE FROM KOTLIN IS THE MISSING-MESSAGE CASE, AND
/// IT IS A DIFFERENCE IN WHERE THE FALLBACK LIVES RATHER THAN IN WHETHER THERE IS
/// ONE. Kotlin substitutes `ApiErrorEnvelope.FALLBACK_MESSAGE` here, so its
/// failure types can carry a non-null `String`; ``ApiError/http(status:message:)``
/// carries `String?` and its doc comment forbids inventing copy at this layer,
/// because a fabricated sentence makes a contract regression indistinguishable
/// from an ordinary error at every call site. The UI owns the fallback. Both
/// clients show the server's sentence when there is one, which is the part a user
/// can see.
///
/// ⚠️ STATUS-SPECIFIC OUTCOMES (401 → sign out, 429 → keep the session, 503 with
/// `REGIONS_DEGRADED` → "we could not look", which is NOT "there is nothing")
/// are NOT branched here, unlike Kotlin's `ApiResult` hierarchy. ``ApiError``
/// keeps the status, so ``ApiError/isUnauthorized`` and a caller's own check on
/// `ApiErrorEnvelope.code` recover every one of them. Anything that needs the
/// code or the degraded region list decodes the body itself — with
/// `ApiErrorEnvelope.lenient(_:)`, the same decode this function performs, or
/// with `WorkspaceListDegradedError` for the array. Both are public for exactly
/// that reason.
public enum ApiErrorNormalizer {
    /// Map one response onto ``ApiError``.
    ///
    /// - Parameters:
    ///   - statusCode: the HTTP status. Anything outside 200...299 is a server
    ///     refusal and becomes ``ApiError/http(status:message:)``.
    ///   - body: the raw response bytes, or nil when there was no body at all.
    ///     ⚠️ nil and empty are the same fact here and must stay that way: a
    ///     transport that returns `Data()` for a 204 and one that returns nil
    ///     would otherwise produce different errors for the same response.
    ///
    /// - Returns: ``ApiError/decoding(_:)`` for a 2xx — which by construction
    ///   means the caller already failed to decode the declared contract, since
    ///   that is the only reason a success would reach this function — and
    ///   ``ApiError/http(status:message:)`` for everything else.
    public static func apiError(statusCode: Int, body: Data?) -> ApiError {
        guard !isSuccess(statusCode) else {
            return .decoding(decodingReason(statusCode: statusCode, byteCount: body?.count ?? 0))
        }
        return .http(status: statusCode, message: ApiErrorEnvelope.lenient(body)?.message)
    }

    /// ⚠️ 2xx ONLY, NOT `< 400`. A 3xx that reaches this function is a redirect
    /// the transport did not follow (the recording route answers 302 with a
    /// `Location` the app is meant to read), and reporting one as a decode
    /// failure would blame the contract for a redirect that was never followed.
    static func isSuccess(_ statusCode: Int) -> Bool {
        (200 ... 299).contains(statusCode)
    }

    /// ⛔ NO BODY PREVIEW IN THIS STRING, AND THAT IS A PRIVACY DECISION RATHER
    /// THAN AN OVERSIGHT. Kotlin's `ApiResult.DecodeFailure` carries a truncated
    /// `bodyPreview` in a SEPARATE field its UI never renders; ``ApiError`` has
    /// one `String` and ``ApiError/message`` returns it, so anything put here can
    /// reach a screen — and the bodies that fail to decode are call transcripts,
    /// contact records and message threads. The status and the size are enough to
    /// tell "the server sent nothing" from "the server sent a shape we do not
    /// know", which is what this string is for.
    static func decodingReason(statusCode: Int, byteCount: Int) -> String {
        "The server's response did not match the shape this app expects "
            + "(HTTP \(statusCode), \(byteCount) bytes)."
    }
}
