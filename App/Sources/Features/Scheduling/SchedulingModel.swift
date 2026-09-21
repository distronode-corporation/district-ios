import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import Observation

/// Which read is running, and therefore what a failure is allowed to do to the
/// screen.
///
/// ⛔ THE THIRD CASE IS THE POINT OF THIS TYPE. An auto-poll fires every ten
/// seconds while a tenancy provisions, so a single blip on a flaky connection
/// would otherwise replace a perfectly good "setting up" card with a failure the
/// user never asked for and did not cause. A poll therefore keeps whatever is on
/// screen and says nothing; the initial read and the manual refresh both report,
/// because a person is waiting on an answer in those two cases.
///
/// ⚠️ ``manual`` KEEPS THE CARD WHILE THE READ IS IN FLIGHT and still reports a
/// failure when it lands. Blanking to ``SchedulingScreenState/loading`` on a pull
/// to refresh would flash the one card this screen has.
enum SchedulingReadKind {
    case initial
    case manual
    case poll
}

/// The screen's top-level state.
///
/// ⛔ A FAILED READ IS ITS OWN CASE AND IS NEVER RENDERED AS "there is nothing
/// here". `tenant == nil` is an ordinary, expected answer on this surface (it is
/// every workspace before anybody presses Enable), so a read that did not happen
/// and a workspace with no booking page would otherwise be the same picture. See
/// ``FailureText``.
enum SchedulingScreenState {
    case loading
    case ready(SchedulingStatusResponse)
    case failed(FailureText)
}

/// The six things this screen can be showing once the status read has answered.
///
/// ⛔ SIX CASES RATHER THAN FOUR, BECAUSE `tenant == nil` MEANS TWO DIFFERENT
/// THINGS. A workspace with no tenancy row is either one nobody has provisioned
/// yet (ordinary, and the answer is a button) or one the feature does not admit
/// (also ordinary, and the answer is a sentence and nothing else). The tenancy
/// status covers the other four. Collapsing either pair would put a button in
/// front of somebody the enable route answers 403, or hide it from somebody who
/// only needed to press it.
///
/// ⚠️ THE TENANCY WINS OVER ELIGIBILITY WHENEVER THERE IS ONE. A workspace can be
/// provisioned and later removed from the allowlist — the status route sends both
/// answers precisely because they are independent — and in that case the booking
/// page is still live and its link is still the truth. Eligibility then decides
/// only whether Enable is offered. See ``offersEnable(eligible:canManage:)``.
enum SchedulingPresentation {
    /// The feature does not admit this workspace. ⛔ No button, and no route out:
    /// App Store Review Guideline 3.1.3(b) forbids a purchase path, and a
    /// "contact sales" link from a paid product's settings screen is the same
    /// offer wearing a different hat.
    case notEligible
    /// Admitted, never provisioned. The ordinary state of every workspace before
    /// the first press.
    case legacy
    case provisioning(SchedulingTenant)
    /// Booking pages are live. Named ``live`` rather than `ready` so it cannot be
    /// misread as ``SchedulingScreenState/ready(_:)``, which is about the READ.
    case live(SchedulingTenant)
    /// The last provision failed. ⚠️ Not terminal: the hourly reconciler tries
    /// again, and re-running Enable is the documented manual recovery.
    case failedProvision(SchedulingTenant)
    /// ⛔ THE ONE STATE NOTHING RE-PROVISIONS, AND THEREFORE THE ONE STATE THIS
    /// SCREEN DOES NOT OFFER TO HEAL. A human, or a workspace deletion, took the
    /// tenancy down; see the ⛔ on ``SchedulingTenantStatus``.
    case switchedOff(SchedulingTenant)
}

extension SchedulingPresentation {
    static func from(_ status: SchedulingStatusResponse) -> SchedulingPresentation {
        guard let tenant = status.tenant else { return status.eligible ? .legacy : .notEligible }
        return switch tenant.status {
        case .provisioning: .provisioning(tenant)
        case .ready: .live(tenant)
        case .error: .failedProvision(tenant)
        case .disabled: .switchedOff(tenant)
        }
    }

    /// Whether to draw the Enable button.
    ///
    /// ⛔ BOTH ANSWERS COME FROM THE SERVER AND NEITHER IS RE-DERIVED FROM THE
    /// ROLE THIS DESTINATION CARRIES. `canManage` is the status route telling the
    /// client which buttons to draw; a second gate built from a role STRING would
    /// fail closed on a role that did not parse and hide the button from an owner
    /// the server would have admitted. The enable route enforces both checks
    /// itself either way — this is an affordance, never a boundary.
    ///
    /// ⛔ `switchedOff` IS DELIBERATELY NOT OFFERED, WHICH DIVERGES FROM THE WEB
    /// CARD. The web card offers Enable for a disabled tenancy;
    /// `disabled` is the one status nothing re-provisions on purpose, and
    /// resurrecting booking pages somebody switched off is a change that should
    /// be made where the switch was thrown, not from a phone.
    func offersEnable(eligible: Bool, canManage: Bool) -> Bool {
        guard eligible, canManage else { return false }
        return switch self {
        case .legacy, .failedProvision: true
        case .notEligible, .provisioning, .live, .switchedOff: false
        }
    }

    /// ⚠️ ONLY WHERE RE-READING COULD HONESTLY CHANGE THE ANSWER. The other four
    /// states are settled until somebody acts, and the scroll view is pull-to-
    /// refresh everywhere regardless.
    var offersRefresh: Bool {
        switch self {
        case .provisioning, .failedProvision: true
        case .notEligible, .legacy, .live, .switchedOff: false
        }
    }

    var offersOpen: Bool {
        if case .live = self {
            return true
        }
        return false
    }

    /// Whether the card has an action row at all.
    ///
    /// ⛔ ``notEligible`` AND ``switchedOff`` ANSWER false, AND THAT IS THE WHOLE
    /// REASON THIS EXISTS RATHER THAN THE ROW DECIDING FOR ITSELF. Both states are
    /// specified to show a sentence and nothing else — one because App Store Review
    /// Guideline 3.1.3(b) forbids the only thing there would be to offer, the other
    /// because `disabled` is the one status nothing may re-provision — and a row
    /// that is built and then happens to be empty is a row a later edit fills in.
    func offersAnyAction(eligible: Bool, canManage: Bool) -> Bool {
        offersOpen || offersRefresh || offersEnable(eligible: eligible, canManage: canManage)
    }
}

/// The Scheduling screen's state machine: one read, one provision, one hand-off.
///
/// ⛔ NOTHING HERE RETRIES `enable`, AND NOTHING HERE MAY LEARN TO. One call
/// reaches two third parties (a tenancy at the scheduler and a DNS record at
/// Cloudflare) and its 5-per-hour brake FAILS OPEN, so a retry loop is somebody
/// else's API quota and a zone full of records. The 202 is telling the client to
/// re-read the status, which is what ``enable()`` does, once, on a human press.
/// See the ⛔ on ``SchedulingRepository``.
///
/// ⛔ AND THE AUTO-POLL READS THE STATUS ROUTE ONLY. ``pollWhileProvisioning()``
/// is a plain GET on a ten-second floor, driven by the screen's own visibility;
/// it must never be pointed at ``enable()`` for the reason above.
///
/// ⚠️ TAKES THE CONTAINER, NEVER A REPOSITORY OR A CLIENT. Both collaborators are
/// `let`s on the container built from the one ``ApiClient`` and the one
/// ``TokenRefreshCoordinator``; anything constructed here would reach a second
/// coordinator. See the ⚠️ on `AppContainer`'s stored properties.
@MainActor
@Observable
final class SchedulingModel {
    private(set) var state: SchedulingScreenState = .loading

    /// ⚠️ ONE FLAG FOR THE PROVISION, which is the only write on this screen.
    /// A second press while the first is in flight would spend another of the
    /// five hourly enables for an answer already on its way.
    private(set) var busy = false

    /// ⚠️ SEPARATE FROM ``busy``. Opening the scheduler is a read that spends a
    /// single-use token rather than a write, and it must stay pressable while a
    /// provision is settling.
    private(set) var opening = false

    /// ⚠️ SHOWN ALONGSIDE THE CARD, NEVER INSTEAD OF IT. It carries the
    /// operator-facing sentence from a refused provision or a refused hand-off,
    /// both of which leave the card's own answer intact and worth reading.
    private(set) var notice: String?

    /// ⛔ TEN SECONDS IS A FLOOR, NOT A TARGET. The reconciler re-runs a stalled
    /// provision hourly, so nothing here is racing anything; the poll exists so a
    /// provision that finishes in twenty seconds does not need a tap to be seen.
    static let pollInterval: Duration = .seconds(10)

    private let scheduling: SchedulingRepository
    private let sso: SchedulingSSOClient
    private let handoff: SchedulingHandoffClient
    private let workspaceId: String

    init(container: AppContainer, workspaceId: String) {
        scheduling = container.scheduling
        sso = container.schedulingSSO
        handoff = container.schedulingHandoff
        self.workspaceId = workspaceId
    }

    /// Whether the tenancy is mid-provision, which is the only state that polls.
    var isProvisioning: Bool {
        guard case let .ready(status) = state else { return false }
        guard let tenant = status.tenant else { return false }
        if case .provisioning = tenant.status {
            return true
        }
        return false
    }

    /// Read the tenancy's state.
    func load(_ kind: SchedulingReadKind = .initial) async {
        if case .initial = kind {
            state = .loading
        }
        switch await scheduling.status(workspaceId: workspaceId) {
        case let .success(status):
            state = .ready(status)
        case let .failure(error):
            // ⛔ A POLL SAYS NOTHING. See the ⛔ on ``SchedulingReadKind``.
            if case .poll = kind {
                return
            }
            state = .failed(FailureText.from(error))
        }
    }

    /// Provision the tenancy, once, on an explicit press.
    ///
    /// ⛔ THE RE-READ IS UNCONDITIONAL, INCLUDING AFTER A REFUSAL. The 202 says
    /// the provision has already run and the row is the truth; a 403 means the
    /// allowlist answer this screen is holding is stale, and a 429 means somebody
    /// else's press may have moved the row since. Trusting the POST's own view
    /// would leave the card describing a state that no longer exists.
    func enable() async {
        guard !busy else { return }
        busy = true
        notice = nil
        let outcome = await scheduling.enable(workspaceId: workspaceId)
        notice = Self.enableNotice(for: outcome)
        busy = false
        await load(.manual)
    }

    /// Mint the hand-off that replaced the retired console.
    ///
    /// ⛔ RE-MINTED ON EVERY TAP, NEVER CACHED. The code is single-use and lives about
    /// sixty seconds, so a cached one is stale exactly when somebody needs it — and a
    /// stale code lands on a page saying the link has expired, which reads as a broken
    /// app rather than as a code that did its job.
    ///
    /// ⚠️ SAME `opening` FLAG AND SAME `notice` AS ``schedulerHandOff()``, so the two
    /// routes cannot both be in flight and the screen has one place to read a failure.
    func manageScheduling() async -> URL? {
        guard !opening else { return nil }
        opening = true
        notice = nil
        let outcome = await handoff.mint(workspaceId: workspaceId)
        opening = false
        switch outcome {
        case let .success(mint):
            return mint.url
        case let .failure(error):
            notice = Self.handOffNotice(for: error)
            return nil
        }
    }

    /// Mint a hand-off into the scheduler's own admin, for one press.
    ///
    /// ⛔ THE URL IS ANSWERED, NEVER STORED. It carries a 60-second single-use
    /// token in its query string, so keeping it on this model would leave a live
    /// credential in memory long after the sheet closed and would make a second
    /// press cheap to serve from a value that is already spent. The caller
    /// presents it immediately and drops it when the sheet dismisses.
    ///
    /// ⚠️ nil MEANS "nothing to open" AND THE REASON IS IN ``notice``, so the
    /// caller never has to invent copy for a failure it did not classify.
    func schedulerHandOff() async -> URL? {
        guard !opening else { return nil }
        opening = true
        notice = nil
        let outcome = await sso.handOffURL(workspaceId: workspaceId)
        opening = false
        switch outcome {
        case let .success(url):
            return url
        case let .failure(error):
            notice = Self.handOffNotice(for: error)
            return nil
        }
    }

    /// Re-read on a ten-second floor for as long as the tenancy is provisioning.
    ///
    /// ⚠️ THE CALLER OWNS "visible". This loop stops when its task is cancelled,
    /// and the screen ties that task's lifetime to its own appearance and to the
    /// scene being active — so a backgrounded app and a screen the user navigated
    /// away from both poll nothing.
    func pollWhileProvisioning() async {
        while !Task.isCancelled, isProvisioning {
            try? await Task.sleep(for: Self.pollInterval)
            guard !Task.isCancelled else { return }
            await load(.poll)
        }
    }

    func dismissNotice() {
        notice = nil
    }

    // MARK: - Outcome copy

    /// ⛔ `ok: false` INSIDE A 202 IS A SUCCESSFUL RESPONSE CARRYING THE ONE
    /// SENTENCE THAT SAYS WHAT WENT WRONG. Promoting it to a failure would throw
    /// that sentence away; the fallback exists only for a server that sent
    /// neither.
    private static func enableNotice(for outcome: Result<SchedulingEnableResponse, ApiError>) -> String? {
        switch outcome {
        case let .success(response):
            // ⚠️ WRITTEN AS STATEMENTS RATHER THAN A TERNARY. A `nil` branch inside
            // a switch EXPRESSION leans on the contextual `String?` reaching two
            // levels down, and that inference fails only in the full SwiftUI build.
            // Two statements ask the type checker nothing.
            if response.ok {
                return nil
            }
            return response.error ?? SchedulingCopy.enableFailedFallback
        case let .failure(error):
            return enableFailureNotice(for: error)
        }
    }

    /// ⛔ 403 AND 429 ARE THE TWO REFUSALS THAT NEVER REACHED THE PROVISIONER, and
    /// each needs its own sentence. A 403 is the allowlist, not the role, so
    /// ``FailureText``'s generic permission wording would send an owner looking
    /// for a colleague to ask; a 429 is five presses in an hour for this
    /// workspace, shared across everybody in it, and is the one failure here that
    /// genuinely resolves by waiting.
    private static func enableFailureNotice(for error: ApiError) -> String {
        switch error {
        case .http(status: 403, message: _): SchedulingCopy.notEligible
        case .http(status: 429, message: _): SchedulingCopy.tooManyAttempts
        default: FailureText.from(error).message
        }
    }

    /// ⚠️ 409 IS NOT A FAULT. The route answers it when the tenancy is not
    /// `ready`, which is the honest state of a workspace mid-provision, and it
    /// says so rather than reporting a failure the user would try to fix.
    /// Everything else, 500 and 503 included, falls to the shared mapping.
    private static func handOffNotice(for error: ApiError) -> String {
        switch error {
        case .http(status: 409, message: _): SchedulingCopy.notReadyYet
        default: FailureText.from(error).message
        }
    }
}
