import Foundation

/// The envelope `POST /api/district/scheduling/admin` wraps every one of its 75
/// operations in.
///
/// ⛔ A FAILED OP IS A **200**, AND THAT IS WHY THE FLAG IS READ BEFORE THE
/// PAYLOAD RATHER THAN WITH IT. `failureResponse` answers
/// `{ok:false, failure, status}` at HTTP 200 deliberately: the request reached
/// Distronode, was authorised, cleared the op's role bar and validated, and the
/// SCHEDULER is what refused. One generic type with a non-optional `data` cannot
/// decode that body at all, and one with an optional `data` cannot tell "the op
/// answered null" from "the op failed" — so the flag is its own decode.
///
/// ⚠️ `status` IS PARSED AND DELIBERATELY UNUSED. It is the scheduler's own HTTP
/// status, carried for a log line; it must never reach the client's five-code
/// vocabulary, which is keyed on `failure` alone.
public struct SchedulingAdminEnvelopeHead: Codable, Sendable, Equatable {
    public let ok: Bool
    public let failure: String?
    public let status: Int?
}

/// The success envelope, once ``SchedulingAdminEnvelopeHead`` has said it is one.
///
/// ⛔ IT MODELS `ok` AS WELL AS `data`, AND DROPPING THE FLAG WOULD FAIL THE
/// CONTRACT GATE RATHER THAN MERELY BEING UNTIDY. `StrictDecodeVerifier`
/// re-encodes and compares KEY SETS, so a key the server sends and this type does
/// not model vanishes on the round trip and is reported. The flag is redundant to
/// a caller that already branched on the head; it is not redundant to the wire.
///
/// ⚠️ `Encodable` IS CONDITIONAL, because the runtime decode is parameterised on
/// `Decodable` alone — nothing in the app ever encodes one of these. The
/// conformance exists so the gate can round-trip the payloads that ARE `Codable`.
public struct SchedulingAdminSuccess<Payload: Decodable>: Decodable {
    public let ok: Bool
    public let data: Payload
}

extension SchedulingAdminSuccess: Encodable where Payload: Encodable {}

extension SchedulingAdminSuccess: Sendable where Payload: Sendable {}

/// The body of a non-2xx from that route: `{error}`, plus `{fields}` on an
/// `invalid_params`.
///
/// ⛔ FIELD NAMES, NEVER MESSAGES. `issueFields` flattens zod issues to paths and
/// drops the text on purpose — an issue's message quotes the offending input
/// straight back out of the API. Anything rendering ``fields`` must treat the
/// entries as identifiers to look up, not as prose to show.
///
/// ⚠️ BOTH PROPERTIES ARE OPTIONAL AND THE BODY IS STILL MEANINGFUL WITHOUT
/// EITHER. A 500 answers `{"error":"Internal Server Error"}` with no fields, and
/// an edge refusal may carry neither; the STATUS is what decides the outcome, and
/// this type only ever refines it.
public struct SchedulingAdminErrorBody: Codable, Sendable, Equatable {
    public let error: String?
    public let fields: [String]?
}

/// The `data` of the sixteen ops that answer nothing.
///
/// ⛔ IT IS NOT AN EMPTY BODY AND MODELLING IT AS ONE FAILS. The catalog's
/// `NO_CONTENT` is `z.unknown().transform(() => ({ ok: true }))`, so a 204 or an
/// empty 2xx from the scheduler is rewritten into a real object before it reaches
/// this client — `{"ok":true,"data":{"ok":true}}` on the wire, an outer flag and
/// an inner one that mean different things. `Void` is not `Decodable`, and an
/// empty struct would decode a `{ok:false}` failure body just as happily, which is
/// the mistake this type exists to make impossible.
///
/// ⚠️ `ok` IS DECODED STRICTLY RATHER THAN DEFAULTED, and the reason is that it is
/// the only thing here to get wrong. The value is constant by construction — the
/// transform ignores its input — so the field is not information about the
/// request; it is a pin on the server's own shape, and a `?? true` would let that
/// shape change without anything noticing.
public struct SchedulingNoContent: Codable, Sendable, Equatable {
    public let ok: Bool
}
