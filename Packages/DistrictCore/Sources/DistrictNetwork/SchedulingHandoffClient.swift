import DistrictModel
import Foundation

/// What `POST /api/district/scheduling/handoff` answers.
///
/// ⚠️ EXACTLY TWO KEYS, AND EXTRA ONES ARE A FAILURE RATHER THAN A SHRUG. Swift's
/// synthesised `Decodable` ignores keys it does not know, which is how a client
/// silently keeps working against a contract that has moved underneath it. The
/// strict decode below is the repo's own habit, not a new rule.
public struct SchedulingHandoff: Sendable, Equatable {
    /// ⛔ SINGLE-USE AND SHORT-LIVED. The server documents 60 seconds; the client
    /// re-mints on every tap rather than caching, because a cached code is a code
    /// that will be stale exactly when somebody needs it.
    public let url: URL
    public let expiresIn: Int

    public init(url: URL, expiresIn: Int) {
        self.url = url
        self.expiresIn = expiresIn
    }
}

/// Why a hand-off mint failed.
///
/// ⚠️ TWO 400s GET THEIR OWN CASES BECAUSE EACH HAS ITS OWN REMEDY, and an
/// ``ApiError/http(status:message:)`` cannot carry the `code` that tells them apart.
public enum SchedulingHandoffFailure: Error, Equatable, Sendable {
    /// 400 `nonce_required`: the server now refuses unbound mints. The message is the
    /// sentence to show ("Update the app to open the website from it."), nil when the
    /// body carried none.
    case nonceRequired(message: String?)

    /// 400 `invalid_nonce`: the nonce sent was refused. ⛔ A failure, never retried
    /// with the same nonce; the next tap starts again from leg 1.
    case invalidNonce

    /// Every other failure, normalised exactly as the client always has.
    case api(ApiError)
}

/// Mints the hand-off URL into the tenant's own scheduler.
///
/// ⛔ IT DOES NOT REPLACE `scheduling/sso`; THE TWO COEXIST. Where the scheduler's
/// own ADMIN SPA is switched off, `scheduling/sso` answers
/// **410 `scheduler_console_retired`** for a `next` that lands on `/admin` and mints
/// normally for everything else, which means the CALENDAR-OAUTH round trip
/// (`next=/v1/calendar/connect…`). The admin surfaces are served natively through
/// ``EndpointID/schedulingAdmin`` instead.
///
/// ⛔ THE URL IS REFUSED UNLESS IT IS `https` AND ON THE API'S OWN HOST. The value
/// arrives in a response body and is then handed to a browser, so an attacker who
/// could influence it would have a redirect into anywhere. `SchedulingSSOClient`
/// makes the same check on its `Location` header and for the same reason; this is
/// the stricter half, because a host comparison is available here and was not there.
public struct SchedulingHandoffClient: Sendable {
    private let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    /// Leg 1 of the bound hand-off: the page the BROWSER opens to receive the nonce
    /// cookie, on the API's own host.
    ///
    /// ⛔ OPENED IN THE SAME BROWSER COMPONENT AS LEG 3, NEVER FETCHED HERE. The cookie
    /// is host-only and lands in whichever jar made the request; leg 3 redeems only in a
    /// jar holding it. `SFSafariViewController` and `ASWebAuthenticationSession` do not
    /// share one, so mixing them is a 410 on every bound redeem.
    public func startURL(state: String) -> URL? {
        client.pageURL(DistrictPaths.schedulingHandoffStart, query: [ApiQueryItem("state", state)])
    }

    /// Leg 2: mint the code, bound to `nonce` when there is one.
    ///
    /// ⛔ nil SENDS NO `nonce` KEY AT ALL, which is the unbound flow every installed
    /// build already uses and the server accepts until `HANDOFF_REQUIRE_NONCE` is on.
    /// The response body is the same two keys either way.
    public func mint(
        workspaceId: String,
        next: String? = nil,
        nonce: String? = nil
    ) async -> Result<SchedulingHandoff, SchedulingHandoffFailure> {
        let descriptor = DistrictEndpoints.schedulingHandoff(workspaceId: workspaceId, next: next, nonce: nonce)
        let outcome = await client.sendUnmapped(descriptor)
        switch outcome {
        case let .failure(error):
            return .failure(.api(error))
        case let .success(raw):
            guard ApiErrorNormalizer.isSuccess(raw.statusCode) else {
                return .failure(Self.refusal(raw))
            }
            return decode(raw.body).flatMap(verified).mapError(SchedulingHandoffFailure.api)
        }
    }

    /// ⛔ THE TWO NONCE REFUSALS ARE TOLD APART BY `code`, NEVER BY THE SENTENCE, and
    /// only on a 400: the same code on any other status is not this contract. Every
    /// other refusal keeps the shared normalisation, so a 401, 403, 409 or 429 reads
    /// exactly as it did before the nonce existed.
    private static func refusal(_ raw: RawResponse) -> SchedulingHandoffFailure {
        let envelope = ApiErrorEnvelope.lenient(raw.body)
        if raw.statusCode == 400, envelope?.code == ApiErrorCode.nonceRequired {
            return .nonceRequired(message: envelope?.message)
        }
        if raw.statusCode == 400, envelope?.code == ApiErrorCode.invalidNonce {
            return .invalidNonce
        }
        return .api(ApiErrorNormalizer.apiError(statusCode: raw.statusCode, body: raw.body))
    }

    /// ⛔ STRICT: MISSING KEYS AND UNKNOWN KEYS BOTH FAIL. A body that grew a field is
    /// a contract change somebody must look at, and a body that lost one is a client
    /// about to render nothing.
    private func decode(_ body: Data) -> Result<SchedulingHandoff, ApiError> {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return .failure(.decoding("The hand-off response was not a JSON object."))
        }
        guard Set(object.keys) == ["url", "expiresIn"] else {
            return .failure(.decoding(
                "The hand-off response did not carry exactly `url` and `expiresIn`."
            ))
        }
        guard let raw = object["url"] as? String, let expiresIn = object["expiresIn"] as? Int else {
            return .failure(.decoding("The hand-off response's `url` or `expiresIn` was the wrong type."))
        }
        guard let url = URL(string: raw) else {
            return .failure(.decoding("The hand-off address was not a URL."))
        }
        return .success(SchedulingHandoff(url: url, expiresIn: expiresIn))
    }

    /// ⛔ HTTPS ONLY, AND THE API'S OWN HOST ONLY.
    ///
    /// ⚠️ `SFSafariViewController` accepts only `http`/`https` and TRAPS on anything
    /// else, so an unexpected scheme would be a crash rather than a refusal — the
    /// same trap `SchedulingSSOClient` documents. And a hand-off that is not TLS puts
    /// a single-use sign-in code on the wire in clear.
    private func verified(_ handoff: SchedulingHandoff) -> Result<SchedulingHandoff, ApiError> {
        guard handoff.url.scheme?.lowercased() == "https" else {
            return .failure(.decoding("The scheduling address was not an https address."))
        }
        guard let host = handoff.url.host?.lowercased(), host == client.baseHost else {
            return .failure(.decoding("The scheduling address was not on this workspace's own host."))
        }
        return .success(handoff)
    }
}
