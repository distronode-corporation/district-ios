import DistrictData
import DistrictModel
import Foundation
import Observation

/// The SDR campaign card's own state.
///
/// ⛔ EVERY TYPE IN THIS FILE IS DECLARED AT FILE SCOPE RATHER THAN NESTED, for the
/// reason `AnalyticsModel.swift` records: a nested type whose NAME matches an
/// associated-type requirement of a protocol the enclosing type conforms to becomes the
/// WITNESS for it, and the error surfaces somewhere else entirely.
enum CampaignCardState {
    case loading
    /// ⚠️ ALL-EMPTY IS A REAL STATE, NOT A FAILURE. A workspace that never opened the
    /// campaigns tab reads as `{false, null, null}`, and the route normalises "absent"
    /// and "off" into that one shape on purpose.
    case ready(CampaignStatus)
    case failed(FailureText)
}

/// The workflow list's own state.
enum WorkflowListState {
    case loading
    /// ⚠️ EMPTY IS A LEGITIMATE ANSWER (most workspaces have never created a workflow)
    /// and it renders as an explanatory empty state, never as a failure. The
    /// repository's envelope guard is what separates this from "we could not look",
    /// which on an automation monitor reads as "your automation was deleted".
    case ready([WorkflowListItem])
    case failed(FailureText)
}

/// One workflow's run history, as far as it has been read.
///
/// ⛔ `hasMore` IS THE SERVER'S FLAG AND MUST NOT BE RE-DERIVED FROM `runs.count`. It is
/// computed from a real `total`, so it stays correct when a page comes back short,
/// which happens whenever a run is written between two requests. A client-side
/// `count < limit` would end the list early and hide history that exists.
struct WorkflowRunHistory {
    var runs: [WorkflowRun] = []
    var total = 0
    var hasMore = false
    /// ⚠️ SET BY THE FIRST FETCH TOO, not only by a "load more": the screen draws a
    /// skeleton for the first and a disabled button for the second.
    var loading = false
    /// ⛔ TRUE ONLY ONCE A READ HAS ACTUALLY ANSWERED, WHICH IS NOT THE SAME QUESTION AS
    /// "IS THERE AN ENTRY IN THE MAP". ``WorkflowsModel/fetchRuns(_:offset:)`` writes the
    /// entry BEFORE its await so the panel can draw a skeleton, so a first page that
    /// failed leaves a complete-looking history behind: `hasMore` false, `runs` empty,
    /// entry present. An "already fetched" guard keyed on the entry's existence would
    /// treat an ATTEMPTED fetch as a COMPLETED one, and the panel gates its only button
    /// on `hasMore` — so a first-page failure would leave no control at all, and
    /// collapsing and re-expanding would do nothing. This flag is what separates the two.
    var loaded = false
    /// ⚠️ CARRIED BESIDE THE ROWS ALREADY FETCHED rather than replacing them. A page
    /// three that failed must not discard pages one and two.
    var failure: FailureText?

    /// ⚠️ WHETHER AN EXPAND STILL OWES A REQUEST. Not loaded and not already asking:
    /// the first excludes a history that answered, the second stops a collapse and
    /// re-expand firing a second identical read over the top of one in flight.
    var needsFirstPage: Bool {
        !loaded && !loading
    }
}

/// A pause or resume the operator has asked for and not yet confirmed.
///
/// ⚠️ CARRIES THE VALUE THAT WOULD BE WRITTEN, NOT "the button was tapped". That is what
/// makes the confirmation copy and the request agree, and it survives the card being
/// replaced underneath the dialog by a reload.
struct CampaignConfirm {
    let enable: Bool
}

/// The automation monitor's state machine: two independent reads, two writes that need
/// opposite designs, and one lazily fetched run history per workflow.
///
/// ⛔ FOUR INDEPENDENT FAILURES, NEVER ONE. The campaign card, the workflow list, each
/// workflow's run history and the toggle all fail separately, and it matters more here
/// than anywhere because the screen answers "is my automation working". A campaign read
/// that 500'd must not blank a workflow list that answered.
///
/// ⛔ THE TOGGLE IS OPTIMISTIC WITH A REVERT AND THE CAMPAIGN PAUSE IS NOT, AND THE
/// DIFFERENCE IS FORCED BY WHAT EACH REPLY CARRIES RATHER THAN BY TASTE.
/// `PATCH /api/district/workflows` answers a bare `{success:true}` and echoes nothing
/// about the row it wrote, so flip-and-revert is the only honest design available;
/// `PATCH workspace/campaign-status` answers the READ's whole shape, derived from the
/// object it merged, so the truth arrives with the reply and is adopted. Guessing would
/// also be worse there: a resume that appeared to work and had not would tell an
/// operator their outbound engine is running when it is not.
///
/// ⛔ NEITHER WRITE IS RETRIED HERE. The toggle's reply carries no state, so a retry
/// could not tell "the first one landed" from "neither did" and an automatic loop would
/// hide a persistent failure behind a screen that looks settled. The pause IS idempotent
/// and the repository says a caller may repeat it: that is permission for the operator
/// to press the control again, which is what a failure leaves possible, and it is not
/// permission to poll.
///
/// ⛔ THE RUN HISTORY IS CACHED PER WORKFLOW AND THE LIST IS NOT. Expanding a workflow
/// costs a request; collapsing and re-expanding the same one must not, because the
/// natural way to compare two workflows is to open one, close it, open the other, and go
/// back. ⚠️ ONLY A HISTORY THAT ANSWERED IS CACHED, and that distinction is
/// ``WorkflowRunHistory/loaded``: an entry left behind by a fetch that FAILED is not a
/// cache hit, or a first-page failure would be permanent for the life of the screen.
///
/// ⚠️ ``reset()`` IS THE ONLY THING THAT CLEARS THE CACHE AND NOTHING CALLS IT. Both
/// halves are true and the second is not a defect to fix by inventing a caller: this
/// screen has no pull-to-refresh and no workspace switch reaching it, so the model is
/// built fresh with the view. It is here for the day one of those arrives, and the
/// per-page retry it does NOT do is ``retryRuns(_:)``.
@MainActor
@Observable
final class WorkflowsModel {
    /// ⚠️ THE SERVER'S OWN DEFAULT (10) RATHER THAN ITS CEILING (50), deliberately. A run
    /// row is tall and this is a phone; asking for the maximum would make the first
    /// expand slow and the "load more" control decorative. The server clamps to 1...50
    /// and ECHOES what it applied, so this number being wrong is visible rather than
    /// silent.
    static let runsPageSize = 10

    private(set) var campaign: CampaignCardState = .loading

    private(set) var list: WorkflowListState = .loading

    /// ⚠️ ONE HISTORY OPEN AT A TIME, deliberately. Run rows are tall (a status, two
    /// timestamps, a line per action and possibly an error paragraph), and several open
    /// at once turns the list into a wall in which the workflow NAMES (the thing being
    /// scanned for) are the smallest text on screen.
    private(set) var expanded: String?

    private(set) var runs: [String: WorkflowRunHistory] = [:]

    /// The optimistic switch position for one workflow, keyed by id.
    ///
    /// ⛔ AN OVERLAY RATHER THAN A REBUILT ROW, AND IT IS FORCED BY THE MODULE BOUNDARY.
    /// ``WorkflowListItem`` declares no public initialiser, so its memberwise one is
    /// internal to `DistrictModel` and this target cannot build a copy carrying a
    /// different `active`, the same wall ``CallLogModel`` hit with `OffsetSlice`.
    ///
    /// ⚠️ AND IT IS THE BETTER SHAPE ANYWAY. A successful write KEEPS its entry, because
    /// the list underneath is now stale; a failed one REMOVES it, which puts the switch
    /// back to the value this client last read from the server rather than to
    /// `!attempted`. Those two are the same for a single tap and they are not for a
    /// refused tap on a row somebody else changed, where the negation would invent a
    /// third value nobody wrote. A fresh list read clears the whole map, because then the
    /// list is the truth.
    private(set) var activeOverrides: [String: Bool] = [:]

    /// ⚠️ A SET, NOT A FLAG. Two switches touch two different rows and nothing re-reads
    /// afterwards, so two operators' worth of impatience on two different switches is not
    /// a race. What must be prevented is a second tap on the SAME switch while the first
    /// is in flight.
    private(set) var pendingToggles: Set<String> = []

    /// ⚠️ SHOWN ALONGSIDE THE LIST, NEVER INSTEAD OF IT. The row it was refused on has
    /// already gone back, so the list on screen is the truth and this explains why it did
    /// not move.
    private(set) var toggleFailure: FailureText?

    private(set) var campaignConfirm: CampaignConfirm?

    /// ⚠️ A SINGLE FLAG, unlike ``pendingToggles``. There is exactly one campaign per
    /// workspace, so "which one is in flight" is not a question, and a second submit
    /// while the first is running could land in either order and leave the card showing
    /// the loser.
    private(set) var campaignPending = false

    /// ⚠️ SHOWN ON THE CARD, BESIDE A STATUS THAT IS STILL THE LAST ONE THE SERVER SENT.
    private(set) var campaignFailure: FailureText?

    /// Mirrors the two PATCH routes' `["agency","client"]` guard.
    ///
    /// ⚠️ AN AFFORDANCE, NOT A SECURITY CONTROL, and it errs low: a nil role means "the
    /// role could not be established", never "assume client".
    let canToggle: Bool

    private let repository: WorkflowsRepository
    private let workspaceId: String

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        canToggle = WorkspaceRole.allowsMutation(role)
        repository = container.workflows
        self.workspaceId = workspaceId
    }

    /// The switch position to draw for one row.
    ///
    /// ⚠️ THE OVERRIDE WINS OVER THE ROW. See the ⛔ on ``activeOverrides``.
    func isActive(_ workflow: WorkflowListItem) -> Bool {
        activeOverrides[workflow.id] ?? workflow.active
    }

    func isToggling(_ workflow: WorkflowListItem) -> Bool {
        pendingToggles.contains(workflow.id)
    }

    // MARK: - Reading

    /// Discard everything the two reads own, so both start clean.
    ///
    /// ⛔ CLEARS THE RUN CACHE, THE OPEN ROW AND THE OPTIMISTIC OVERRIDES. Carrying a
    /// cached history across a reload would leave an expanded panel showing the runs of a
    /// workflow that may no longer be in the list, and carrying an override would leave a
    /// switch disagreeing with the list it is drawn from.
    ///
    /// ⛔ THE CONFIRMATION IS DROPPED, NOT CARRIED: a dialog surviving a reload would be
    /// asking about a state that has been replaced underneath it. ⚠️ `campaignPending` is
    /// deliberately NOT cleared: a request already in flight will still answer, and
    /// clearing the flag would re-enable the control underneath it.
    func reset() {
        campaign = .loading
        list = .loading
        expanded = nil
        runs = [:]
        activeOverrides = [:]
        toggleFailure = nil
        campaignConfirm = nil
        campaignFailure = nil
    }

    /// ⚠️ ITS OWN METHOD SO THE SCREEN CAN START IT IN ITS OWN `.task`, alongside
    /// ``loadWorkflows()``. Neither waits for the other and neither can fail the other:
    /// they answer different questions from different databases.
    func loadCampaign() async {
        switch await repository.campaignStatus(workspaceId: workspaceId) {
        case let .success(status):
            campaign = .ready(status)
        case let .failure(error):
            campaign = .failed(FailureText.from(error))
        }
    }

    func loadWorkflows() async {
        switch await repository.workflows(workspaceId: workspaceId) {
        case let .success(items):
            // ⚠️ THE FRESH LIST IS THE TRUTH, so every optimistic override is dropped
            // with it rather than being layered over rows that already agree.
            activeOverrides = [:]
            list = .ready(items)
        case let .failure(error):
            list = .failed(FailureText.from(error))
        }
    }

    // MARK: - Run history

    /// Open or close one workflow's history.
    ///
    /// ⛔ THE FETCH IS LAZY AND HAPPENS ONCE IT HAS SUCCEEDED. Reading every workflow's
    /// runs on entry would be one request per row for history nobody asked to see, and
    /// re-reading on every expand would punish the natural comparison gesture. "Once"
    /// must not mean "once it was ATTEMPTED": ``fetchRuns(_:offset:)`` writes a map entry
    /// before its await, so a guard on the entry alone would make a failed first page
    /// permanent (no rows, no `hasMore`, so no button, and re-expanding does nothing).
    /// See ``WorkflowRunHistory/loaded``.
    func toggleExpanded(_ workflowId: String) async {
        if expanded == workflowId {
            expanded = nil
            return
        }
        expanded = workflowId
        guard runs[workflowId]?.needsFirstPage ?? true else { return }
        await fetchRuns(workflowId, offset: 0)
    }

    /// Read the next page of one workflow's history.
    ///
    /// ⛔ THE OFFSET IS THE NUMBER OF ROWS ALREADY HELD, NOT A PAGE COUNTER, because the
    /// server may have applied a different `limit` than was asked for. Counting pages
    /// would drift the moment those two disagreed, and the symptom is silently skipped or
    /// duplicated runs rather than an error.
    ///
    /// ⚠️ A SECOND TAP WHILE ONE IS IN FLIGHT IS DROPPED, not queued: two requests at the
    /// same offset would append the same rows twice.
    func loadMoreRuns(_ workflowId: String) async {
        guard let history = runs[workflowId] else { return }
        guard !history.loading, history.hasMore else { return }
        await fetchRuns(workflowId, offset: history.runs.count)
    }

    /// Read the page that failed, again.
    ///
    /// ⛔ SEPARATE FROM ``loadMoreRuns(_:)`` BECAUSE THAT ONE IS GATED ON `hasMore`, AND
    /// `hasMore` IS FALSE AFTER A FIRST-PAGE FAILURE — which is precisely the state that
    /// most needs a way out. The panel's "load more" button therefore could not be it.
    ///
    /// ⚠️ THE OFFSET IS THE NUMBER OF ROWS HELD, so this re-reads the page that failed
    /// rather than starting over: for a first-page failure that is 0, and for a later one
    /// it is exactly where the list stops. Same rule as ``loadMoreRuns(_:)``, and the
    /// same reason — the server may apply a different `limit` than was asked for.
    ///
    /// ⚠️ REFUSED UNLESS SOMETHING ACTUALLY FAILED, so a stray tap cannot re-request a
    /// page that arrived.
    func retryRuns(_ workflowId: String) async {
        guard let history = runs[workflowId] else { return }
        guard !history.loading, history.failure != nil else { return }
        await fetchRuns(workflowId, offset: history.runs.count)
    }

    // MARK: - The per-workflow switch

    /// Turn one workflow on or off, optimistically.
    ///
    /// ⛔ ONE TAP, ONE CALL, NO RETRY. On failure the switch goes back to the value this
    /// client last read from the server and the reason is shown beside the list; it never
    /// silently stays where the finger left it. See the ⛔ on the class for why the write
    /// may be optimistic at all: setting one boolean is idempotent server-side and the
    /// PATCH itself sends nothing and bills nothing. What it GATES spends money; the call
    /// does not.
    ///
    /// ⛔ REFUSED OUTRIGHT FOR A ROLE THE SERVER WOULD REFUSE, as well as in the screen. A
    /// model that would issue the request if asked is one refactor away from a control
    /// that 403s, and the optimistic flip would show the workflow as changed for the
    /// second before the refusal landed.
    func setActive(workflowId: String, active: Bool) async {
        guard canToggle else { return }
        guard case .ready = list else { return }
        guard !pendingToggles.contains(workflowId) else { return }

        activeOverrides[workflowId] = active
        pendingToggles.insert(workflowId)
        toggleFailure = nil

        let outcome = await repository.setActive(
            workspaceId: workspaceId,
            workflowId: workflowId,
            active: active
        )
        pendingToggles.remove(workflowId)
        guard case let .failure(error) = outcome else { return }
        // ⛔ REMOVED RATHER THAN NEGATED. Dropping the override puts the switch back on
        // the list's own value, which is what the server last told us.
        activeOverrides.removeValue(forKey: workflowId)
        toggleFailure = FailureText.from(error)
    }

    /// ⚠️ TRANSIENT BY NATURE, so the screen can dismiss it without a re-read.
    func dismissToggleFailure() {
        toggleFailure = nil
    }

    // MARK: - The campaign

    /// Ask to pause or resume. Opens the confirmation and writes nothing.
    ///
    /// ⛔ A CONFIRMATION EXISTS HERE AND NOT ON THE PER-WORKFLOW SWITCH, WHICH IS A
    /// DELIBERATE ASYMMETRY. Flipping one workflow changes what happens the NEXT time its
    /// trigger fires; pausing the campaign stops an engine that is working through a
    /// contact list right now, and resuming one starts spending call and message credit
    /// again. A confirmation on every switch would train the operator to dismiss the one
    /// that matters.
    ///
    /// ⚠️ A REQUEST TO SET THE VALUE ALREADY HELD IS DROPPED. The write is idempotent, so
    /// this is not a safety guard: a control that costs a round trip to change nothing is
    /// worse than one that does not respond.
    func requestCampaignChange(enable: Bool) {
        guard canToggle, !campaignPending else { return }
        guard case let .ready(status) = campaign else { return }
        guard status.infiniteSdrEnabled != enable else { return }
        campaignConfirm = CampaignConfirm(enable: enable)
        campaignFailure = nil
    }

    /// ⚠️ BACKING OUT COSTS NOTHING AND WRITES NOTHING.
    func dismissCampaignConfirm() {
        campaignConfirm = nil
    }

    /// Commit the confirmed pause or resume.
    ///
    /// ⛔ THE TARGET IS READ OUT OF THE CONFIRMATION, NOT OUT OF THE CARD. Between opening
    /// the dialog and confirming it a reload can have replaced the status underneath, and
    /// re-deriving `!current` here would write whichever value that left behind rather
    /// than the one the sentence on screen described.
    ///
    /// ⛔ AND THE REPLY IS ADOPTED RATHER THAN GUESSED. The route answers the READ's shape
    /// from the object it merged, so there is no window in which the client and the server
    /// disagree and no second request needed to close one.
    func confirmCampaignChange() async {
        guard canToggle, !campaignPending else { return }
        guard let confirm = campaignConfirm else { return }

        campaignConfirm = nil
        campaignPending = true
        campaignFailure = nil

        let outcome = await repository.setCampaignEnabled(
            workspaceId: workspaceId,
            enabled: confirm.enable
        )
        campaignPending = false
        switch outcome {
        case let .success(status):
            campaign = .ready(status)
        case let .failure(error):
            // ⛔ THE CARD KEEPS THE LAST STATE THE SERVER SENT. Blanking it, or showing
            // the value that was refused, would answer "is my campaign running" with
            // something nobody wrote. The control stays pressable: the route is
            // idempotent and a second attempt is the operator's to make.
            campaignFailure = FailureText.from(error)
        }
    }

    // MARK: - Internals

    private func fetchRuns(_ workflowId: String, offset: Int) async {
        var opening = runs[workflowId] ?? WorkflowRunHistory()
        opening.loading = true
        opening.failure = nil
        runs[workflowId] = opening

        let outcome = await repository.runs(
            workspaceId: workspaceId,
            workflowId: workflowId,
            limit: Self.runsPageSize,
            offset: offset
        )
        var held = runs[workflowId] ?? WorkflowRunHistory()
        held.loading = false
        switch outcome {
        case let .success(page):
            // ⛔ APPEND, NEVER REPLACE, and `offset == 0` is the only case that starts
            // fresh. A "load more" that assigned would throw away every page before it.
            held.runs = offset == 0 ? page.runs : held.runs + page.runs
            held.total = page.total
            held.hasMore = page.hasMore
            held.failure = nil
            // ⛔ THE ONLY PLACE THIS IS SET, AND IT IS WHY THE ENTRY WRITTEN BEFORE THE
            // AWAIT CANNOT PASS FOR A COMPLETED READ. See ``WorkflowRunHistory/loaded``.
            held.loaded = true
        case let .failure(error):
            // ⛔ THE ROWS ALREADY FETCHED SURVIVE, and `loaded` is left exactly as it
            // was: a page three that failed does not un-load pages one and two, and a
            // page ONE that failed never claimed to be loaded in the first place.
            held.failure = FailureText.from(error)
        }
        runs[workflowId] = held
    }
}
