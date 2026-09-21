import DistrictModel
import DistrictNetwork
import Foundation

/// The whole native scheduling admin, as ONE method.
///
/// ⛔ ONE GENERIC `perform`, NOT SEVENTY-FIVE WRAPPERS, AND THAT IS A BOUNDARY
/// DECISION RATHER THAN AN ECONOMY. The server owns the catalog: the scheduler
/// path, the HTTP verb, the params schema and the response allowlist all live in
/// `admin-ops.ts`, and every one of them is a thing a second copy here would
/// silently disagree with. What this layer owns is the ENVELOPE — which is the
/// one piece of the contract the catalog does not describe and every op shares.
///
/// ⛔ IT GOES THROUGH ``ApiClient/sendUnmapped(_:)``, AND ANY EDIT THAT "TIDIES"
/// THAT INTO ``ApiClient/send(_:as:)`` BREAKS IT IN THE QUIET DIRECTION. A failed
/// op is a **200** carrying `{ok:false, failure, status}` — the request reached
/// us, cleared auth, cleared the role bar, validated, and the scheduler refused.
/// `send(_:as:)` would hand those bytes to `JSONDecoder` against the caller's
/// type: usually a ``ApiError/decoding(_:)`` blaming the contract for an outage,
/// and occasionally worse, because a type whose every field is optional decodes
/// `{ok:false}` CLEANLY and reports an outage as an empty success.
///
/// ⛔ NOTHING HERE RETRIES, AND THE SERVER'S OWN RETRY IS THE REASON IT MUST NOT
/// START. The server's route already performs exactly ONE re-mint and ONE re-send on a
/// 401, bounded because an unbounded one rotates the member's scheduler key on
/// every request and a rotation logs out everyone else holding it. A retry loop
/// added on this side multiplies that, and 46 of the 75 ops are writes.
///
/// ⛔ AND NOTHING HERE VALIDATES `params`. The catalog's zod schema is the only
/// validator and it runs server-side; a second, laxer copy here would refuse
/// bodies the server accepts (a client-side bug nobody can work around) or accept
/// bodies it rejects (a **400** the user cannot act on). `params` is passed
/// through verbatim, PATH KEYS INCLUDED — see
/// ``DistrictEndpoints/schedulingAdmin(workspaceId:op:params:)``.
public struct SchedulingAdminRepository: Sendable {
    /// Called when the server reports an `op` name this client sent and it does
    /// not have. See ``init(client:reportUnknownOp:)``.
    public typealias UnknownOpReporter = @Sendable (SchedulingAdminOp) -> Void

    private let client: ApiClient
    private let reportUnknownOp: UnknownOpReporter

    /// - Parameter reportUnknownOp: what to do about a **400 `unknown_op`**.
    ///
    ///   ⛔ THAT REFUSAL IS A PROGRAMMER ERROR AND NOTHING A USER CAN ACT ON. It
    ///   means ``SchedulingAdminOp`` and `ADMIN_OPS` have diverged — a key renamed
    ///   or withdrawn on the server — which is invisible to the compiler, because
    ///   the op crosses the wire as a string. The app passes a reporter that traps
    ///   in a debug build, so the divergence is found by whoever caused it, and is
    ///   a no-op in release, where a crash would be a far worse answer than the
    ///   generic sentence ``SchedulingAdminError/unknown`` earns.
    ///
    ///   ⛔ REQUIRED, WITH NO DEFAULT, AND THE TRAP LIVES IN THE APP. Whether a
    ///   process may crash is the app's policy, not this package's, and an
    ///   `assertionFailure` here would be the one statement in the package a debug
    ///   test run cannot execute without trapping. A caller that leaves it out
    ///   fails to compile rather than silently losing the debug check.
    public init(client: ApiClient, reportUnknownOp: @escaping UnknownOpReporter) {
        self.client = client
        self.reportUnknownOp = reportUnknownOp
    }

    /// Run one catalogued op and decode its `data` into the type the caller names.
    ///
    /// ⚠️ THE RESPONSE TYPE IS THE CALLER'S CHOICE AND IS NOT CHECKED AGAINST THE
    /// OP. Nothing on this side knows that `eventTypes.list` answers a list of
    /// event types — the catalog does, and it is not importable from Swift. Naming
    /// the wrong type is a ``SchedulingAdminError/decoding(_:)`` at runtime rather
    /// than a compile error, which is the cost of not duplicating 75 schemas. Use
    /// ``SchedulingNoContent`` for the sixteen ops that answer nothing.
    public func perform<Response: Decodable>(
        _ op: SchedulingAdminOp,
        workspaceId: String,
        params: JSONValue,
        as type: Response.Type
    ) async throws -> Response {
        let descriptor = DistrictEndpoints.schedulingAdmin(
            workspaceId: workspaceId,
            op: op,
            params: params
        )
        switch await client.sendUnmapped(descriptor) {
        case let .failure(error):
            // ⚠️ ONLY REACHED WHEN NO RESPONSE EXISTS — an unbuildable path, a
            // missing credential, a dead socket. `sendUnmapped` skips the status
            // mapping, so every answered request arrives on the other arm with
            // its body intact.
            throw Self.error(forUnanswered: error)
        case let .success(raw):
            return try decode(raw, op: op, as: type)
        }
    }

    private func decode<Response: Decodable>(
        _ raw: RawResponse,
        op: SchedulingAdminOp,
        as type: Response.Type
    ) throws -> Response {
        guard (200 ... 299).contains(raw.statusCode) else {
            throw refusal(raw, op: op)
        }
        guard let head = try? JSONDecoder().decode(SchedulingAdminEnvelopeHead.self, from: raw.body) else {
            // A 2xx that is neither shape is a contract we cannot read, and it is
            // NOT a retry. Same arm as the browser's.
            throw SchedulingAdminError.unknown
        }
        guard head.ok else {
            throw SchedulingAdminError.failure(.forFailure(head.failure ?? ""))
        }
        do {
            return try JSONDecoder().decode(SchedulingAdminSuccess<Response>.self, from: raw.body).data
        } catch {
            // ⛔ NO BODY PREVIEW, for ``ApiErrorNormalizer``'s reason: this text
            // can reach a screen and these bodies are customer bookings,
            // transcripts and meeting notes. The op name and the size are enough
            // to tell "sent nothing" from "sent a shape we do not know".
            throw SchedulingAdminError.decoding(
                "The scheduler's answer to '\(op.rawValue)' did not match the shape this app expects "
                    + "(\(raw.body.count) bytes)."
            )
        }
    }

    /// A non-2xx, which on this route is always OUR refusal rather than the
    /// scheduler's.
    ///
    /// ⚠️ THE `error` STRING IS CHECKED BEFORE THE STATUS FOR 409, copying
    /// `codeForStatus`. The route answers 409 for exactly one reason today, but
    /// `conflict` is a generic shape and a future 409 that is not about
    /// provisioning would otherwise tell an operator to go set up a feature they
    /// already have.
    ///
    /// ⚠️ 413 IS GROUPED WITH 429 AND 5xx HERE AND IS **NOT** IN THE BROWSER'S
    /// `codeForStatus`, where it falls through to `unknown`. Stated rather than
    /// left to be discovered: on this route a 413 is a params object over 5 MiB,
    /// which no user action shortens and no retry fixes, so neither answer is
    /// clearly right. If the two clients are ever made to agree, agree in ONE
    /// place — this comment and `admin-fetch.ts` are the pair.
    private func refusal(_ raw: RawResponse, op: SchedulingAdminOp) -> SchedulingAdminError {
        let body = try? JSONDecoder().decode(SchedulingAdminErrorBody.self, from: raw.body)
        let code = body?.error ?? ""
        if raw.statusCode == 400 {
            if code == "invalid_params" {
                return .invalidParams(body?.fields ?? [])
            }
            if code == "unknown_op" {
                reportUnknownOp(op)
                return .unknown
            }
        }
        return Self.error(forStatus: raw.statusCode, code: code)
    }

    static func error(forStatus status: Int, code: String) -> SchedulingAdminError {
        if status == 403 || status == 401 {
            return .forbidden
        }
        if status == 409, code == "scheduling_not_ready" {
            return .notReady
        }
        if status == 413 || status == 429 || status >= 500 {
            return .unavailable
        }
        return .unknown
    }

    /// ⚠️ A MISSING CREDENTIAL ARRIVES HERE AS A SYNTHETIC 401, not as a
    /// transport failure: ``ApiClient`` answers `.http(status: 401, message: nil)`
    /// without sending anything when the token provider returns nil. Routing it
    /// through the same status mapping is what makes "signed out" and "refused"
    /// one answer, which is correct — both mean this member cannot do it now.
    static func error(forUnanswered error: ApiError) -> SchedulingAdminError {
        switch error {
        case let .http(status, _):
            self.error(forStatus: status, code: "")
        case let .transport(reason):
            .transport(reason)
        case let .decoding(reason):
            .decoding(reason)
        }
    }
}
