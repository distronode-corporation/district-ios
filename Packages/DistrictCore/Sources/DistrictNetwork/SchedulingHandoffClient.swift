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

    public func mint(workspaceId: String, next: String? = nil) async -> Result<SchedulingHandoff, ApiError> {
        let descriptor = DistrictEndpoints.schedulingHandoff(workspaceId: workspaceId, next: next)
        let outcome = await client.send(descriptor)
        return outcome.flatMap { raw in
            decode(raw.body).flatMap(verified)
        }
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
