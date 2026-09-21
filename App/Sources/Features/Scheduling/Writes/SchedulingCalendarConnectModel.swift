import DistrictModel
import DistrictNetwork
import Foundation
import Observation

/// The Google/Microsoft calendar connection: the one hand-off on this surface that
/// leaves the app.
///
/// ⛔ IT IS NOT AN ADMIN OP AND IT CANNOT BE MADE ONE. The consent screen belongs
/// to the provider, so the round trip has to happen in a browser; the catalog has
/// no `calendar.connect`, and `GET /v1/calendar/connect` lives on the scheduler
/// behind its own session. The hand-off is therefore
/// `GET /api/district/scheduling/sso` with an explicit `next`, exactly as the web
/// console spends it for its calendar Connect link, which this mirrors.
///
/// ⛔ THE `next` IS DOUBLE-ENCODED AND THE INNER ENCODE IS THE LOAD-BEARING ONE.
/// `safeNextPath` refuses any `next` containing a literal `://` (the check that
/// stops an open redirect) and `return_to` is an ABSOLUTE URL. Encoding the return
/// URL before it is placed in `next`, and then encoding `next` as a whole, is what
/// lets an absolute URL travel inside a value that may not contain one. A single
/// encode reads correctly, passes review, and has its `next` dropped on the floor
/// at the far end — where the only symptom is landing on the scheduler's default
/// page. The outer encode is `SchedulingSSOClient`'s; the inner one is here.
///
/// ⛔ AND THE 410 GUARD DOES NOT APPLY TO THIS `next`. `isRetiredConsolePath` fires
/// for a `next` that lands on `/admin`, which is why the tenancy card's hand-off
/// can answer 410; `/v1/calendar/connect` is not that path, so this leg still
/// mints.
///
/// ⚠️ `return_to` IS THE WEB DASHBOARD'S CALENDAR PAGE, NOT A CUSTOM SCHEME, AND
/// THAT IS A DELIBERATE REFUSAL TO GUESS. `districtai://` would let
/// `ASWebAuthenticationSession` close itself on return, and nothing available here
/// establishes that the fork accepts a non-http `return_to` — it parses the value
/// and requires a host, and its behaviour beyond that is not readable from this
/// repo. The web URL is the value production already spends every day. The cost is
/// that the operator taps Done; the sheet's dismissal is what triggers the re-read,
/// so no outcome is lost either way.
///
/// ⚠️ NOTHING HERE STORES THE MINTED URL. It carries a 60-second single-use token,
/// so it is answered and presented immediately; the caller drops it when the sheet
/// dismisses, the same rule `SchedulingModel.schedulerHandOff()` follows.
@MainActor
@Observable
final class SchedulingCalendarConnectModel {
    /// ⛔ THE TWO PROVIDERS A CONNECT EXISTS FOR, AND THE NAMES ARE THE FORK'S.
    /// The fork's calendar service keys its provider map on exactly `google` and
    /// `microsoft`, and `GET /v1/calendar/connect?provider=` 400s on anything else.
    /// `caldav` is a third provider with no OAuth redirect, which is why it is not
    /// in this list and has a form of its own.
    static let oauthProviders = ["google", "microsoft"]

    /// The dashboard page the round trip comes back to.
    static let calendarPath = "/dashboard/district/scheduling/calendar"

    private(set) var busy = false
    private(set) var failure: FailureText?

    private let sso: SchedulingSSOClient
    private let baseURL: URL
    private let workspaceId: String
    private let onChanged: () -> Void

    init(
        sso: SchedulingSSOClient,
        baseURL: URL,
        workspaceId: String,
        onChanged: @escaping () -> Void
    ) {
        self.sso = sso
        self.baseURL = baseURL
        self.workspaceId = workspaceId
        self.onChanged = onChanged
    }

    /// Which providers to draw a Connect control for.
    ///
    /// ⛔ `configured` IS THE INSTANCE'S ANSWER AND `unconfiguredProviders` NARROWS
    /// IT. A tenancy on a scheduler with no calendar credentials gets no controls
    /// and one sentence; a tenancy on a scheduler that has Google and not Microsoft
    /// gets one control. ⚠️ `unconfiguredProviders` is NULL, not `[]`, on a fully
    /// configured instance — the common case — so nil means "none are missing".
    static func offeredProviders(_ status: SchedulingCalendarStatus) -> [String] {
        guard status.configured else { return [] }
        let unconfigured = Set(status.unconfiguredProviders ?? [])
        return oauthProviders.filter { !unconfigured.contains($0) }
    }

    /// The `next` the SSO route is asked for, with `return_to` already encoded.
    ///
    /// ⚠️ BUILT BY HAND RATHER THAN THROUGH `URLComponents`. The value is not a URL
    /// — it is a path-and-query that has to survive being a query VALUE — and
    /// `URLComponents` would re-encode the inner `return_to` against a set that
    /// leaves `/` and `:` alone, undoing the encode this depends on.
    static func nextPath(provider: String, returnTo: String) -> String {
        "/v1/calendar/connect?provider=\(SchedulingSSOClient.encode(provider))"
            + "&return_to=\(SchedulingSSOClient.encode(returnTo))"
    }

    var returnTo: String {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = Self.calendarPath
        components?.query = nil
        components?.fragment = nil
        return components?.url?.absoluteString ?? baseURL.absoluteString + Self.calendarPath
    }

    /// Mint a hand-off for one provider. nil means nothing to open, and the reason
    /// is in ``failure``.
    func connect(provider: String) async -> URL? {
        guard !busy else { return nil }
        busy = true
        failure = nil
        let next = Self.nextPath(provider: provider, returnTo: returnTo)
        let outcome = await sso.handOffURL(workspaceId: workspaceId, next: next)
        busy = false
        switch outcome {
        case let .success(url):
            return url
        case let .failure(error):
            failure = Self.handOffFailure(error)
            return nil
        }
    }

    /// ⚠️ CALLED WHEN THE BROWSER SHEET CLOSES, WHATEVER HAPPENED IN IT. The app is
    /// not told the outcome — the callback appends `calendar=connected` or
    /// `calendar=error` to a page in the browser, which this process never sees — so
    /// the honest move is to re-read the status and let it say what is connected.
    func handOffFinished() {
        onChanged()
    }

    func dismissFailure() {
        failure = nil
    }

    /// ⚠️ 409 IS NOT A FAULT. The route answers it when the tenancy is not `ready`,
    /// which is the honest state of a workspace mid-provision, and it says so rather
    /// than reporting a failure the user would try to fix. Everything else, the 410
    /// included, falls to the shared mapping — which shows the server's own sentence
    /// for a 4xx and never invents one.
    private static func handOffFailure(_ error: ApiError) -> FailureText {
        if case .http(status: 409, message: _) = error {
            return FailureText(message: SchedulingWriteCopyC.connectNotReadyYet, action: .none)
        }
        return FailureText.from(error)
    }
}
