import DistrictModel
import DistrictNetwork
import Foundation

/// Telephony analytics, and the workspace's metered usage.
///
/// ⛔ THREE INDEPENDENT READS BEHIND ONE SCREEN, DELIBERATELY NOT COMBINED HERE.
/// Analytics is raw SQL over the `Call` table; usage and usage history are metering
/// `groupBy`s on a different route, in two different response shapes. They fail for
/// different reasons, so folding them into one `Result` would let either failure
/// blank an answer the caller already holds — an operator who can see this month's
/// SMS count losing it because a call aggregate timed out. The caller runs them
/// concurrently and keeps three sub-states; this layer's job is to keep each one
/// honest on its own.
///
/// ⚠️ NO CACHING AND NO PAGER. Analytics is a fixed-size aggregate per window and
/// usage is one row per month, so neither pages — and a stale cache behind a figure
/// an operator is reading as current is worse than a second request.
public struct AnalyticsRepository: Sendable {
    /// The span the web console asks for.
    ///
    /// ⚠️ ONE COPY OF THE DECISION, HERE, RATHER THAN A NUMBER AT EACH CALL SITE.
    /// Two surfaces quoting different spans under one "Recent months" heading is
    /// exactly the drift a default parameter exists to prevent.
    public static let defaultHistoryMonths = 3

    private let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    /// The analytics window.
    ///
    /// ⛔ THE ENVELOPE GUARD MATTERS MORE HERE THAN ALMOST ANYWHERE ELSE ON THIS
    /// SURFACE. ``AnalyticsResponse`` requires every key, so `{}` no longer decodes
    /// — but a well-formed body that says `success: false` still does, and it
    /// renders as ZERO CALLS, ZERO CONVERSIONS and a flat trend. That is not an
    /// empty state, it is a fabricated one, and an operator has nothing on the
    /// screen to tell it from a genuinely quiet week.
    ///
    /// - Parameter range: ⛔ AN ``AnalyticsRange``, NEVER A STRING. An unrecognised
    ///   `timeRange` is not an error server-side: the route silently serves 7d with
    ///   a 200, under whatever heading the UI happens to be showing.
    public func analytics(
        workspaceId: String,
        range: AnalyticsRange
    ) async -> Result<AnalyticsResponse, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.analytics(workspaceId: workspaceId, range: range),
            as: AnalyticsResponse.self
        )
        return outcome.flatMap { ResponseEnvelope.affirm("AnalyticsResponse", $0.success, $0) }
    }

    /// This month's metered usage, or nil when nothing has been metered yet.
    ///
    /// ⛔ THE NIL IS CARRIED THROUGH INSIDE A SUCCESS, NOT CONVERTED INTO A FAILURE
    /// AND NOT INTO AN EMPTY OBJECT. `.success(nil)` means "we asked, and there is
    /// genuinely nothing recorded for this month"; a `.failure` means "we could not
    /// find out". The screen says different things about them — a sentence against a
    /// retry — and collapsing them in either direction is the mistake this signature
    /// exists to prevent, because the collapsed form asserts a billing fact nobody
    /// measured.
    ///
    /// ⚠️ DELIBERATELY UNLIKE ``ContactsRepository/detail(workspaceId:contactId:)``,
    /// where a success with no payload IS malformed and absence arrives as a 404.
    /// Here the nil is the payload and the route documents it as such.
    public func usage(workspaceId: String) async -> Result<UsageMonth?, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.usage(workspaceId: workspaceId),
            as: UsageResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("UsageResponse", $0.success, $0) }
            .map(\.usage)
    }

    /// The last `months` months, newest first.
    ///
    /// ⚠️ A SHORT LIST IS NOT AN ERROR AND AN EMPTY ONE IS NOT A FAILURE. The server
    /// skips months with no rows and clamps the request to 1...24, so the answer can
    /// be shorter than asked for — or empty for a workspace that has never been
    /// metered, which means exactly what it says.
    public func usageHistory(
        workspaceId: String,
        months: Int = AnalyticsRepository.defaultHistoryMonths
    ) async -> Result<[UsageMonth], ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.usageHistory(workspaceId: workspaceId, months: months),
            as: UsageHistoryResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("UsageHistoryResponse", $0.success, $0) }
            .map(\.usage)
    }
}
