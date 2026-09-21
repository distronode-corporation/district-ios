import DistrictModel
import DistrictNetwork
import Foundation

/// Asserts the `success` flag every District envelope carries and nothing else
/// reads.
///
/// ⛔ WITHOUT THIS, AN HTTP 200 WHOSE BODY IS `{}` DECODES CLEANLY AND
/// CONFIDENTLY LIES, and two of those lies are the worst outcomes this client
/// has:
///
///   - an empty `workspace/list` envelope reads as **"this account belongs to no
///     workspace at all"**, which routes a paying customer to an onboarding or
///     checkout dead end. That exact conflation — "we could not look" rendered as
///     "there is nothing" — sends a subscribed customer to a checkout page;
///   - an empty `overview` envelope reads as **four confident zeros**.
///
/// ⛔ IT IS CHECKED BY HAND RATHER THAN BY THE PARSER, and that is deliberate.
/// The SHIPPED parser has to stay lenient about unknown and missing keys so a
/// field added server-side degrades to "ignored" on already-installed builds
/// rather than breaking every response on every phone in the field. Leniency
/// about EXTRA keys and strictness about THIS key are independent, and this is
/// how the second one is expressed. Strictness about the whole shape lives in the
/// contract gate, which decodes committed fixtures and compares key sets.
///
/// ⚠️ REPORTED AS ``ApiError/decoding(_:)`` ON PURPOSE. A 200 that does not affirm
/// success is contract drift. It is NOT connectivity, so "check your connection"
/// would be wrong, and it is not a retryable server error either.
///
/// ⚠️ TWO MEMBERS, NOT FOUR, AND THE TWO THAT WENT ARE THE `JSONValue` ONES.
/// `reject(_:_:)` and `unwrap(_:_:_:)` existed for the era when every repository
/// hand-picked keys out of an untyped document; once the MVP read surface moved to
/// DTOs their only caller (`CallsRepository`) stopped needing them and they became
/// public API with no callers and no tests — which under `ci/coverage-gate.sh`'s
/// 100% floor is not a neutral leftover but uncovered lines. Deleted rather than
/// pinned by a test: a test for a helper nothing calls proves only that the helper
/// still compiles. ``require(_:_:)`` survives because the timeline read is still
/// untyped by decision (see ``ThreadEvent``), and ``affirm(_:_:_:)`` because a
/// typed decode cannot check a flag.
public enum ResponseEnvelope {
    /// The envelope's body, once the flag has been checked.
    ///
    /// - Parameter name: the response whose envelope failed, for the diagnostic.
    ///   ⚠️ The message deliberately carries NO body preview: these responses hold
    ///   customer call transcripts and contact details, and the only diagnostic
    ///   fact needed is "the flag was not true".
    ///
    /// ⚠️ RETURNS THE DOCUMENT RATHER THAN A BOOLEAN, so a caller cannot end up
    /// with a checked envelope and a separately-unwrapped optional that has to
    /// carry a `?? .null` fallback no input can reach.
    public static func require(_ name: String, _ json: JSONValue?) -> Result<JSONValue, ApiError> {
        guard let json, json["success"]?.boolValue == true else {
            return .failure(.decoding("\(name) did not affirm success=true"))
        }
        return .success(json)
    }

    /// The typed equivalent: check a decoded DTO's own `success` flag.
    ///
    /// ⛔ IT IS NOT REDUNDANT NOW THAT THE READS DECODE TYPED, AND THE REASON IS
    /// NARROWER THAN IT LOOKS. A required non-optional field does reject `{}` —
    /// but it does not reject a well-formed body that happens to say
    /// `success: false`, and two routes on this surface answer exactly that with
    /// a **200**: `messaging/test` reports a credential refusal that way by
    /// design, and any route whose handler falls into its own error branch after
    /// the headers are written does too. ``ApiClient/send(_:as:)`` only maps
    /// STATUS, so without this the composer would report a refused send as sent.
    ///
    /// ⚠️ REPORTED AS ``ApiError/decoding(_:)`` for the reason ``require(_:_:)``
    /// gives: a 200 that does not affirm success is contract drift, not
    /// connectivity and not a retryable server error.
    public static func affirm<T>(_ name: String, _ success: Bool, _ value: T) -> Result<T, ApiError> {
        guard success else {
            return .failure(.decoding("\(name) did not affirm success=true"))
        }
        return .success(value)
    }
}
