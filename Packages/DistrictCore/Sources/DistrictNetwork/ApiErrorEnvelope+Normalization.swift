import DistrictModel
import Foundation

/// The lenient half of the error path: getting an ``ApiErrorEnvelope`` out of
/// bytes that may not contain one, and getting a showable sentence out of that
/// envelope.
///
/// ⛔ THE WIRE TYPE LIVES IN `DistrictModel` AND IS EXTENDED HERE RATHER THAN
/// RE-DECLARED. ``ApiErrorEnvelope`` is pinned by the strict contract gate
/// as the shape of three real bodies; a second copy in this module would compile
/// (a same-module type shadows an imported one on unqualified lookup) and would
/// then drift from the gated one silently, which is the exact failure the gate
/// exists to prevent.
///
/// ⛔ AND THE DECODE HERE IS DELIBERATELY THE OPPOSITE OF THAT GATE. Strict in
/// the gate, lenient in the field: the gate rejects an unknown key so a server
/// change reds CI, while this decode swallows anything so a server change
/// degrades to "a vaguer sentence" on already-installed builds instead of
/// breaking every error path on every phone. Do not swap them.
public extension ApiErrorEnvelope {
    /// Decode an error body, tolerating anything.
    ///
    /// ⚠️ A NON-JSON BODY IS EXPECTED HERE, NOT EXCEPTIONAL: an edge 502, a
    /// captive-portal interception or a proxy timeout all answer HTML. Returning
    /// nil keeps the status-code mapping working when the body is useless, which
    /// is exactly when the status code is all there is. Mirrors the Kotlin
    /// client's `DistrictApiClient.parseError`, which falls back to an empty
    /// envelope for the same reason.
    ///
    /// ⚠️ A WRONG-TYPED FIELD DISCARDS THE WHOLE ENVELOPE rather than the one
    /// field, deliberately: kotlinx throws on the first type mismatch and loses
    /// the rest, so salvaging `code` out of `{"error": 42, "code": "X"}` here
    /// would make the two clients branch differently on identical bytes. Neither
    /// shape has ever been observed; the parity is what is being preserved.
    ///
    /// - Parameter body: the raw response bytes, or nil when there was no body.
    ///   ⚠️ nil and empty are the same fact and must stay that way, or a
    ///   transport that returns `Data()` where another returns nil would produce
    ///   a different error for the same response.
    /// - Returns: the envelope, or nil when the bytes carried none.
    static func lenient(_ body: Data?) -> ApiErrorEnvelope? {
        guard let body, !body.isEmpty else { return nil }
        return try? JSONDecoder().decode(ApiErrorEnvelope.self, from: body)
    }

    /// The message to show, or nil when the server sent none worth showing.
    ///
    /// ⛔ `error` WINS AND `code` IS NEVER SUBSTITUTED FOR IT, which is the one
    /// normalisation rule the two clients must agree on byte-for-byte. Kotlin's
    /// `DistrictApiClient.mapFailure` reads
    /// `envelope.error?.takeIf { it.isNotBlank() }` and carries `code` in a
    /// SEPARATE field of `ApiResult.HttpFailure`; a blank `error` alongside a
    /// present `code` therefore yields NO message on either client, not the code
    /// string. `REGIONS_DEGRADED` is not a sentence and must never reach a screen.
    ///
    /// ⚠️ BLANK MEANS ABSENT (Kotlin `isBlank()` parity), but a non-blank value
    /// is returned VERBATIM — including any surrounding whitespace. Trimming here
    /// would make this client's copy differ from the Kotlin client's for the same
    /// bytes, and the two get compared in support threads.
    ///
    /// ⛔ NIL IS A REAL ANSWER AND MUST NOT BE PAPERED OVER HERE. The Kotlin
    /// client substitutes `ApiErrorEnvelope.FALLBACK_MESSAGE` at this point;
    /// the Swift side deliberately does not, because ``ApiError`` documents that
    /// inventing copy makes a contract regression look like an ordinary error to
    /// every screen. The fallback sentence is the CALLER's choice, at the UI
    /// boundary.
    var message: String? {
        guard let error, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return error
    }
}
